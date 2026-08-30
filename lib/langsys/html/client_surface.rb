# frozen_string_literal: true

module Langsys
  module Html
    # Client's HTML-facing surface: which attributes are translatable, how a stored content
    # block is resolved (including CID-3 tolerance for historical ids), and the two entry
    # points that translate a fragment or a whole document.
    #
    # Lives apart from Client because it is a coherent subject rather than plumbing — and
    # because Client is the composition root, which is exactly the class that should not
    # also be the biggest one.
    module ClientSurface
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

      private

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

      # REG-11: an ellipsis-terminated phrase is warned about but still registered —
      # "Loading…" and "Please wait…" are legitimate, and silently refusing them would
      # create a new silent failure. Suppression needs a SECOND signal: a longer catalog
      # entry sharing the prefix, which means the truncation has already polluted the
      # catalog and this is the truncated twin.
    end
  end
end
