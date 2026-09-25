# frozen_string_literal: true

require_relative "types"
require_relative "http"
require_relative "errors"
require_relative "locale"

module Langsys
  # Catalog fetching (with a two-tier cache) and pure lookup logic.
  #
  # The contract every Langsys SDK shares: **an untranslated phrase always renders as the
  # source phrase**. A phrase is "missing" (eligible for discovery) only when its key is
  # absent from the category — a present-but-+null+ value means it's registered and simply
  # not translated yet, so it falls back to the base phrase *without* re-queuing.
  module Catalog
    # Result of a catalog lookup: +text+ is the resolved string (a translation, or the base
    # phrase on fallback); +missing+ is true only when the phrase key is absent.
    Resolution = Struct.new(:text, :missing, keyword_init: true) do
      def missing? = missing
    end

    module_function

    def resolve(catalog, phrase, category = nil, content_block_id = nil)
      cat = catalog[category || UNCATEGORIZED]
      return Resolution.new(text: phrase, missing: content_block_id.nil?) unless cat.is_a?(Hash)

      unless content_block_id.nil?
        block = cat[content_block_id]
        if block.is_a?(Hash)
          value = block[phrase]
          text = value.is_a?(String) && !value.empty? ? value : phrase
          return Resolution.new(text: text, missing: false)
        end
        return Resolution.new(text: phrase, missing: false)
      end

      if cat.key?(phrase)
        raw = cat[phrase]
        return Resolution.new(text: raw, missing: false) if raw.is_a?(String) && !raw.empty?

        # present but null/empty/content-block-collision -> base phrase, already registered
        return Resolution.new(text: phrase, missing: false)
      end

      Resolution.new(text: phrase, missing: true)
    end

    # The set of "category::phrase" keys a catalog already contains, used by +sync+ to
    # decide what is genuinely new. A question about a catalog, so it lives with the
    # catalog rather than with the queue that asks it.
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
  end

  # Loads +category -> phrase -> translation+ maps, with a two-tier cache. Tier 1 is an
  # in-process hash (fast, per-client); tier 2 is the pluggable cache backend (survives
  # processes). A miss falls through to nova and populates both tiers.
  class CatalogStore
    # CACHE-2: REG-8's clock on the read side.
    FAILURE_BASE = 3.0
    FAILURE_CEILING = 300.0

    def initialize(http, project_id, cache, ttl: 3600, logger: nil, clock: nil)
      @http = http
      @project_id = project_id
      @cache = cache
      @ttl = ttl
      @logger = logger
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @memory = {}
      @write_enabled = nil
      @write_enabled_at = nil
      # CACHE-2: per locale (this store is per project), held by this long-lived object and
      # never written to the shared cache: {locale => [retry_at, delay]}.
      @failures = {}
      @seeds = {}
      @locks = {}
      @guard = Mutex.new
    end

    # The write decision as of the most recent catalog response (GATE-1). +nil+ means the
    # field was absent — a pre-capability server — which GATE-8 reads as a version signal,
    # never as permission. Never persisted: it lives on this instance only (GATE-3).
    attr_reader :write_enabled, :write_enabled_at

    # Returns the catalog, or +nil+ when it could not be fetched. The nil is load-bearing:
    # without a catalog you cannot tell a miss from a hit, so callers must degrade and
    # record nothing rather than treat everything as unregistered (WIRE-4's write-storm
    # clause). Locale is normalised once here, so the wire form and the cache key agree
    # and +en-US+/+en-us+ resolve to one entry (WIRE-3).
    def get(locale, use_cache: true)
      loc = Locale.normalize_locale(locale)

      if use_cache
        cached = @memory[loc]
        return cached unless cached.nil?

        persisted = @cache.get(key(loc))
        if persisted.is_a?(Hash)
          @memory[loc] = persisted
          return persisted
        end
      end

      # One fetch per locale at a time; a lookup that waited finds the answer the first one
      # stored, or the failure it recorded.
      lock_for(loc).synchronize do
        return @memory[loc] if use_cache && @memory[loc]
        return nil if failing?(loc)

        catalog = fetch(loc)
        return record_failure(loc) if catalog.nil?

        @guard.synchronize { @failures.delete(loc) }
        @memory[loc] = catalog
        @cache.set(key(loc), catalog, @ttl)
        catalog
      end
    end

    # SNAP-2: a preloaded catalog for +locale+, answering lookups until the live one loads.
    def seed_locale(locale, catalog)
      @seeds[Locale.normalize_locale(locale)] = catalog
    end

    def seed(locale) = @seeds[Locale.normalize_locale(locale)]

    # Whether the live catalog for +locale+ is in memory.
    def loaded?(locale) = @memory.key?(Locale.normalize_locale(locale))

    # GATE-3: drop the recorded decision without touching cached catalog data.
    def reset_write_decision!
      @write_enabled = nil
      @write_enabled_at = nil
    end

    def clear(locale = nil)
      if locale.nil?
        @memory.clear
        @cache.clear
      else
        loc = Locale.normalize_locale(locale)
        @memory.delete(loc)
        @cache.delete(key(loc))
      end
    end

    private

    def lock_for(locale)
      @guard.synchronize { @locks[locale] ||= Mutex.new }
    end

    # Inside the window a lookup answers from source text without fetching (CACHE-2).
    def failing?(locale)
      retry_at, = @guard.synchronize { @failures[locale] }
      !retry_at.nil? && @clock.call < retry_at
    end

    def record_failure(locale)
      @guard.synchronize do
        _, delay = @failures[locale]
        delay = delay.nil? ? FAILURE_BASE : [delay * 2, FAILURE_CEILING].min
        @failures[locale] = [@clock.call + delay, delay]
      end
      nil
    end

    def key(locale)
      "translations_#{@project_id}_#{locale}"
    end

    def fetch(locale)
      response = @http.get("translations", { "project_id" => @project_id, "locale" => locale, "format" => "flat" })
      # GATE-1: on this endpoint the flag sits at envelope level, beside `words`.
      # Re-read on every response, never latched (GATE-8 constraint 2).
      if response.key?("write_enabled")
        @write_enabled = response["write_enabled"] == true
        @write_enabled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      else
        @write_enabled = nil
        @write_enabled_at = nil
      end
      if response["status"] == false
        @logger&.warn("langsys: catalog request for #{locale} answered status:false; degrading to source text")
        return nil
      end

      data = response["data"]
      # GATE-4: the cached artifact is `data` only — the envelope carrying the decision
      # is never what we hand to the cache.
      data.is_a?(Hash) ? data : {}
    rescue Langsys::Error => e
      @logger&.warn("langsys: catalog unavailable for #{locale} (#{e.class}: #{e.message}); " \
                    "degrading to source text and recording nothing")
      nil
    end
  end
end
