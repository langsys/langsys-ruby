# frozen_string_literal: true

require_relative "types"
require_relative "http"

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
  end

  # Loads +category -> phrase -> translation+ maps, with a two-tier cache. Tier 1 is an
  # in-process hash (fast, per-client); tier 2 is the pluggable cache backend (survives
  # processes). A miss falls through to nova and populates both tiers.
  class CatalogStore
    def initialize(http, project_id, cache, ttl: 3600)
      @http = http
      @project_id = project_id
      @cache = cache
      @ttl = ttl
      @memory = {}
    end

    def get(locale, use_cache: true)
      if use_cache
        cached = @memory[locale]
        return cached unless cached.nil?

        persisted = @cache.get(key(locale))
        if persisted.is_a?(Hash)
          @memory[locale] = persisted
          return persisted
        end
      end

      catalog = fetch(locale)
      @memory[locale] = catalog
      @cache.set(key(locale), catalog, @ttl)
      catalog
    end

    def clear(locale = nil)
      if locale.nil?
        @memory.clear
        @cache.clear
      else
        @memory.delete(locale)
        @cache.delete(key(locale))
      end
    end

    private

    def key(locale)
      "translations_#{@project_id}_#{locale}"
    end

    def fetch(locale)
      response = @http.get("translations", { "project_id" => @project_id, "locale" => locale, "format" => "flat" })
      data = response["data"]
      data.is_a?(Hash) ? data : {}
    end
  end
end
