# frozen_string_literal: true

require "set"

require_relative "config"
require_relative "errors"
require_relative "http"
require_relative "signal"
require_relative "locale"
require_relative "types"
require_relative "cache"
require_relative "catalog"
require_relative "interpolate"
require_relative "registration"
require_relative "utilities"
require_relative "html/parser"
require_relative "html/page"

module Langsys
  # The entry point — composes the HTTP client, catalog, translator, registration queue, and
  # utilities. Translate with +t+; drive the locale with +set_locale+ (or hand a
  # +locale_source:+ that the client reads and subscribes to, never writes).
  #
  #   client = Langsys::Client.new(api_key: "…", project_id: "…")
  #   client.set_locale("es-ES")
  #   client.t("Hello, {name}!", category: "Greetings", params: { name: "Sarah" })
  class Client
    def initialize(api_key: nil, project_id: nil, api_url: nil, base_locale: nil, locale: nil,
                   locale_source: nil, cache: nil, cache_ttl: nil, timeout: nil,
                   auto_flush: false, logger: nil)
      @config = Config.resolve(
        api_key: api_key, project_id: project_id, api_url: api_url,
        base_locale: base_locale, cache_ttl: cache_ttl, timeout: timeout
      )
      @logger = logger
      @http = Http.new(@config.api_url, @config.api_key, timeout: @config.timeout)
      @cache = cache || Cache::File.new
      @catalog = CatalogStore.new(@http, @config.project_id, @cache, ttl: @config.cache_ttl, logger: @logger)

      seed = Locale.canonicalize_locale(locale || @config.base_locale || "")
      if locale_source
        @locale_source = locale_source
        @owned_locale = nil
      else
        @owned_locale = Signal.new(seed)
        @locale_source = @owned_locale
      end

      @project = nil
      @write_enabled = nil
      @write_enabled_at = nil
      @pending = {}
      @pending_blocks = {}
      @translatable_attributes = Html::DEFAULT_TRANSLATABLE_ATTRIBUTES.dup
      @utils = Utilities.new(@http, @config.project_id)
      @registrar = nil

      at_exit { auto_flush_quietly } if auto_flush
    end

    # -- authorization --------------------------------------------------------

    def authorize(force: false)
      return @project if @project && !force

      cache_key = "auth_#{@config.project_id}"
      unless force
        cached = @cache.get(cache_key)
        if cached.is_a?(Hash)
          # A cached payload carries no decision by construction (GATE-4), so the
          # session's capability stays unresolved until a live response supplies it.
          return @project = Project.from_response(cached)
        end
      end

      response = @http.get("authorize-project/#{Http.encode_segment(@config.project_id)}")
      data = response["data"]
      raise ConfigurationError, "Langsys: unexpected authorize-project response." unless data.is_a?(Hash)

      @project = Project.from_response(data)
      # GATE-1: the decision is read from THIS response...
      @write_enabled = @project.write_enabled
      @write_enabled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # ...and GATE-4: stripped from the artifact before it reaches any cache. The hazard
      # is any store that is process-external or shared by default — this SDK ships a file
      # cache with a 1h TTL, so one allow-listed request would otherwise write-enable every
      # anonymous visitor on the host for an hour, fleet-wide on shared Redis.
      @cache.set(cache_key, data.except("write_enabled"), @config.cache_ttl)
      @project
    end

    def project = authorize
    def key_type = authorize.key_type

    # GATE-1: capability is per SESSION and comes from the server. `key_type` describes
    # the KEY — an ip_write key is read-only from most addresses and write-capable from
    # allow-listed ones, so no client-side value can express it.
    #
    # +refresh:+ forces a fresh authorize, for callers that need the decision re-evaluated
    # against the current response rather than the last one seen.
    def can_write?(refresh: false)
      authorize(force: true) if refresh
      write_enabled?
    end

    # The freshest server signal, or nil when no response has carried one. Never persisted
    # (GATE-3) and never latched (GATE-8 constraint 2).
    #
    # Compared by recency rather than by source. Fixed precedence looks harmless and is
    # not: the catalog slot is only written on a live fetch and the memory tier has no
    # TTL, so a decision recorded once would outrank every authorize that followed it —
    # and in one direction that reports a closed gate as open.
    def write_signal
      catalog_signal = @catalog.write_enabled
      return @write_enabled if catalog_signal.nil?
      return catalog_signal if @write_enabled.nil?

      @catalog.write_enabled_at.to_f >= @write_enabled_at.to_f ? catalog_signal : @write_enabled
    end

    # Drop the session's write decision. Server SDKs outlive the request — under Puma,
    # Falcon or any threaded server the client object survives it — so a long-lived host
    # calls this at request boundaries rather than relying on process death. The
    # process-level posture is declared in CONFORMANCE.md per GATE-3's carve-out.
    def reset_write_decision!
      @write_enabled = nil
      @write_enabled_at = nil
      @catalog.reset_write_decision!
      self
    end

    # -- locale ---------------------------------------------------------------

    # The current user locale (canonical), or "" if none is set yet.
    def locale
      Locale.canonicalize_locale(@locale_source.get)
    end

    # Change the user locale. Only valid when the client owns the locale source (i.e. no
    # external +locale_source:+ was supplied).
    def set_locale(new_locale)
      unless @owned_locale
        raise ConfigurationError, "Langsys: locale is driven by the supplied locale_source; set it there."
      end

      @owned_locale.set(Locale.canonicalize_locale(new_locale))
    end

    # -- translation ----------------------------------------------------------

    def get_translations(locale: nil, use_cache: true)
      @catalog.get(effective_locale(locale), use_cache: use_cache)
    end

    # Translate +phrase+ (falling back to the phrase itself if untranslated), then
    # interpolate +params+ with locale-aware CLDR formatting.
    def translate(phrase, category: nil, params: nil, locale: nil, content_block_id: nil)
      loc = effective_locale(locale)
      catalog = @catalog.get(loc)

      # WIRE-4: no catalog means we cannot distinguish a miss from a hit, so we degrade to
      # the source phrase and record NOTHING — queueing here would turn every outage into
      # a write storm on exactly the paths that were already failing.
      return interpolate(phrase, params, loc) if catalog.nil?

      result = Catalog.resolve(catalog, phrase, category, content_block_id)
      queue_missing(phrase, category) if result.missing && content_block_id.nil?
      interpolate(result.text, params, loc)
    end
    alias t translate

    # -- discovery queue ------------------------------------------------------

    def has_pending?
      !@pending.empty? || !@pending_blocks.empty?
    end

    def pending_phrases
      @pending.keys.map { |category, phrase| { "phrase" => phrase, "category" => category } }
    end

    def pending_content_blocks
      @pending_blocks.values
    end

    def clear_pending
      @pending.clear
      @pending_blocks.clear
    end

    # Register queued (discovered) phrases and content blocks. No-op with nothing pending;
    # a read key logs a warning and clears the queue without writing.
    def flush_pending
      return { "phrases" => 0, "content_blocks" => 0, "success" => true } unless has_pending?

      unless can_write?
        @logger&.warn("langsys: read key cannot register #{@pending.size} phrase(s) / #{@pending_blocks.size} block(s)")
        clear_pending
        return { "phrases" => 0, "content_blocks" => 0, "success" => true, "skipped" => true }
      end

      items = @pending.keys.map do |category, phrase|
        { "phrase" => phrase, "category" => category == UNCATEGORIZED ? nil : category }
      end
      phrase_count = items.size
      registrar.register_phrases(items) unless items.empty?

      block_count = @pending_blocks.size
      @pending_blocks.each_value do |block|
        category = block["category"] == UNCATEGORIZED ? nil : block["category"]
        registrar.register_content_block(block["content"], block["phrases"],
                                         category: category, custom_id: block["custom_id"])
      end

      clear_pending
      @catalog.clear # new items exist server-side now; refetch next time
      { "phrases" => phrase_count, "content_blocks" => block_count, "success" => true }
    end

    # -- registration (write key) --------------------------------------------

    def register_phrases(phrases)
      require_write!
      registrar.register_phrases(phrases)
    end

    def register_content_block(content, phrases, category: nil, custom_id: nil, label: nil)
      require_write!
      registrar.register_content_block(content, phrases, category: category, custom_id: custom_id, label: label)
    end

    # Register any of +local_phrases+ not already in the catalog, then refetch.
    def sync(local_phrases, locale: nil)
      loc = effective_locale(locale)
      catalog = @catalog.get(loc, use_cache: false)
      existing = existing_keys(catalog)

      new_items = local_phrases.reject do |phrase|
        text = phrase.is_a?(String) ? phrase : (phrase[:phrase] || phrase["phrase"])
        category = phrase.is_a?(String) ? nil : (phrase[:category] || phrase["category"])
        existing.include?("#{category || UNCATEGORIZED}::#{text}")
      end

      synced = false
      if !new_items.empty? && can_write?
        registrar.register_phrases(new_items)
        @catalog.clear(loc)
        @catalog.get(loc, use_cache: false)
        synced = true
      end

      {
        "new_phrases" => new_items.map { |p| p.is_a?(String) ? p : (p[:phrase] || p["phrase"]) },
        "synced" => synced
      }
    end

    # -- reference data (utilities) ------------------------------------------

    def countries(in_locale = nil) = @utils.countries(effective_locale(in_locale))
    def dial_codes(in_locale = nil) = @utils.dial_codes(effective_locale(in_locale))
    def currencies(in_locale = nil) = @utils.currencies(effective_locale(in_locale))
    def country_name(code, in_locale = nil) = @utils.country_name(code, effective_locale(in_locale))
    def currency_name(code, in_locale = nil) = @utils.currency_name(code, effective_locale(in_locale))
    def locales(in_locale = nil) = @utils.locales(effective_locale(in_locale))
    def locales_flat(in_locale = nil) = @utils.locales_flat(effective_locale(in_locale))
    def locales_data(in_locale = nil) = @utils.locales_data(effective_locale(in_locale))

    def locale_name(for_locale, short: false, in_locale: nil)
      @utils.locale_name(for_locale, short: short, locale: effective_locale(in_locale))
    end

    def detect_preferred_locale(accept_language = nil, supported = nil)
      Locale.detect_preferred_locale(accept_language, supported)
    end

    # -- cache / lifecycle ----------------------------------------------------

    # Drop cached catalogs and reference data so the next call refetches.
    def refresh
      @catalog.clear
      @utils.clear
      true
    end

    def clear_cache(locale = nil)
      @catalog.clear(locale)
    end

    def close
      # Net::HTTP opens a connection per request here, so there's nothing to hold open.
      true
    end

    # -- server-side HTML translation (requires Nokogiri) --------------------

    # Translate a block of HTML as one unit. Untranslated/unknown blocks return the original
    # HTML (and are queued for registration).
    def translate_content_block(html, category: nil)
      return html if html.nil? || html.empty?

      cat_name = category || UNCATEGORIZED
      phrases = Html.extract_phrases(html, @translatable_attributes)
      return html if phrases.empty?

      custom_id, block, available = lookup_block(cat_name, phrases)
      return Html.apply_block_translations(html, block, @translatable_attributes) if block
      # WIRE-4 write-storm clause: an unavailable catalog records nothing.
      return html unless available

      queue_content_block(html, cat_name, custom_id, phrases)
      html
    end

    # Translate a whole HTML document (head + body) in place, classifying each block as a
    # simple phrase or a content block.
    def translate_page(html, category: nil, selector_categories: nil)
      Html::Page.translate(self, html, category, selector_categories)
    end

    def translatable_attributes
      @translatable_attributes.dup
    end
    alias get_translatable_attributes translatable_attributes

    def set_translatable_attributes(attributes)
      @translatable_attributes = attributes.to_a.dup
      self
    end

    def add_translatable_attributes(attributes)
      attributes.each { |attr| @translatable_attributes << attr unless @translatable_attributes.include?(attr) }
      self
    end

    def reset_translatable_attributes
      @translatable_attributes = Html::DEFAULT_TRANSLATABLE_ATTRIBUTES.dup
      self
    end

    # Resolve the effective locale (explicit arg wins, then the locale source, then base).
    # Public so the HTML page translator can share the client's locale.
    def effective_locale(explicit = nil)
      # NB: an empty string is truthy in Ruby, so pick the first *present* source — a
      # locale_source that returns "" (e.g. an unset request locale) must fall through to
      # base_locale rather than short-circuiting to authorize().
      loc = [explicit, @locale_source.get, @config.base_locale].find { |value| value && !value.empty? }
      # WIRE-4: this sits on the t() path, so a failing authorize must not surface here.
      loc = authorize_quietly&.base_locale if loc.nil? || loc.empty?
      Locale.canonicalize_locale(loc || "")
    end

    # Internal (used by the HTML page translator): look up a stored content block by its id.
    # Returns +[custom_id, block, catalog_available]+. The third element is what lets
    # callers honour WIRE-4's write-storm clause: a nil block during an outage is not
    # evidence the block is unregistered.
    def lookup_block(item_cat, phrases)
      custom_id = Langsys.generate_custom_id(item_cat, phrases)
      catalog = @catalog.get(effective_locale)
      return [custom_id, nil, false] if catalog.nil?

      cat = catalog[item_cat]
      block = cat.is_a?(Hash) ? cat[custom_id] : nil
      block = lookup_legacy_block(cat, item_cat, phrases) if block.nil?
      [custom_id, block.is_a?(Hash) ? block : nil, true]
    end

    # Internal (used by the HTML page translator): queue a discovered content block.
    def queue_content_block(html, category, custom_id, phrases)
      @pending_blocks[custom_id] ||= {
        "content" => html, "category" => category, "custom_id" => custom_id, "phrases" => phrases
      }
    end

    private

    # Interpolation shares the client's logger so ICU-4 recovery notices surface.
    def interpolate(text, params, loc)
      return text unless params && !params.empty?

      Interpolate.call(text, params, loc, logger: @logger)
    end

    def authorize_quietly(force: false)
      authorize(force: force)
    rescue Langsys::Error => e
      @logger&.warn("langsys: authorize unavailable (#{e.class}: #{e.message}); degrading")
      nil
    end

    # CID-3 tolerance: resolve a block stored under a historical id shape, but only after
    # CID-4's content check. The category already matches by construction here — we are
    # looking inside that category's bucket — so the guard compares phrases.
    #
    # Compared as a SET, which CID-4 explicitly permits where the representation has lost
    # order: the catalog returns a block as a map keyed by source phrase, so order is gone
    # before the guard can run. A set still defeats every collision mode in the rule, since
    # all of them are collisions over differing content.
    def lookup_legacy_block(cat, item_cat, phrases)
      return nil unless cat.is_a?(Hash)

      wanted = Array(phrases).map(&:to_s).sort
      Langsys.legacy_custom_ids(item_cat, phrases).each do |legacy_id|
        candidate = cat[legacy_id]
        next unless candidate.is_a?(Hash)
        next unless candidate.keys.map(&:to_s).sort == wanted

        return candidate
      end
      nil
    end

    def queue_missing(phrase, category)
      @pending[[category || UNCATEGORIZED, phrase]] = true
    end

    # GATE-1 with GATE-8's bounded fallback.
    def write_enabled?
      # Resolve the project first: the decision rides on the same response that carries
      # key_type, so reading the signal before this would consult an empty slot and then
      # fall through to the GATE-8 arm with a live answer sitting unread.
      kind = key_type
      signal = write_signal
      return signal unless signal.nil?

      # No live signal yet. A read-typed key cannot be write-enabled while this SDK sends
      # no write grant — the server's gate is `type-allows-write OR valid-grant` — so we
      # can answer without a round trip. That precondition is pinned by the GRANT
      # non-participation spec; if it ever fails, this short-circuit must go and `read`
      # must resolve per response like `ip_write`.
      return false if kind == "read"

      # `ip_write` is address-dependent, so it is never inferred (GATE-8 constraint 1):
      # ask the server rather than guess.
      if kind == "ip_write"
        authorize_quietly(force: true)
        signal = write_signal
        return signal unless signal.nil?

        # Still absent: a pre-capability server has no way to express an address-dependent
        # decision, and the absence of a positive signal IS the answer.
        return false
      end

      # GATE-8: field absent on a plain `write` key — a server predating the capability.
      kind == "write"
    end

    def require_write!
      return if can_write?

      raise AuthorizationError.new("Langsys: the server has not write-enabled this session.",
                                   status_code: 403)
    end

    def registrar
      @registrar ||= Registrar.new(@http, @config.project_id, batch_limit: authorize.batch_limit)
    end

    def existing_keys(catalog)
      keys = Set.new
      catalog.each do |category, entries|
        next unless entries.is_a?(Hash)

        entries.each do |phrase, value|
          next if phrase.start_with?("__") && phrase.end_with?("__")

          if value.is_a?(Hash)
            value.each_key { |child| keys << "#{category}::#{child}" }
          else
            keys << "#{category}::#{phrase}"
          end
        end
      end
      keys
    end

    def auto_flush_quietly
      flush_pending if has_pending?
    rescue StandardError => e
      @logger&.warn("langsys auto-flush failed: #{e.message}")
    end
  end
end
