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
require_relative "discovery"
require_relative "ellipsis"
require_relative "registration_lane"
require_relative "utilities"
require_relative "html/parser"
require_relative "html/page"
require_relative "html/client_surface"

module Langsys
  # The entry point — composes the HTTP client, catalog, translator, registration queue, and
  # utilities. Translate with +t+; drive the locale with +set_locale+ (or hand a
  # +locale_source:+ that the client reads and subscribes to, never writes).
  #
  #   client = Langsys::Client.new(api_key: "…", project_id: "…")
  #   client.set_locale("es-ES")
  #   client.t("Hello, {name}!", category: "Greetings", params: { name: "Sarah" })
  class Client
    include Html::ClientSurface
    include RegistrationLane

    def initialize(api_key: nil, project_id: nil, api_url: nil, base_locale: nil, locale: nil,
                   locale_source: nil, cache: nil, cache_ttl: nil, timeout: nil,
                   auto_flush: false, logger: nil, clock: nil)
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
      @discovery = Discovery.new(@config.project_id, clock: clock)
      @warned_unusable = false
      @translatable_attributes = Html::DEFAULT_TRANSLATABLE_ATTRIBUTES.dup
      @utils = Utilities.new(@http, @config.project_id)
      @registrar = nil

      # REG-3: best-effort only, and documented as such — a shutdown hook does not run on
      # an OOM kill or a hard timeout. The public manual flush is the reliable path.
      at_exit { flush_on_shutdown } if auto_flush
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
      queue_missing(phrase, category, catalog) if result.missing && content_block_id.nil?
      interpolate(result.text, params, loc)
    end
    alias t translate

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
  end
end
