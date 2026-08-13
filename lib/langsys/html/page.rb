# frozen_string_literal: true

require "set"

require_relative "parser"

module Langsys
  module Html
    # Full-page HTML translation — a faithful port of the PHP/Python SDKs' PageTranslator.
    #
    # Walks a document's +<head>+ (title, description/keywords/author metas, OpenGraph and
    # Twitter cards, +<html lang>+, +og:locale+) and +<body>+, classifying each leaf block
    # element as either a **simple phrase** (its whole text is one phrase) or a **content
    # block** (markup-bearing / multi-phrase). Honors +data-langsys-category+,
    # +data-langsys-contentblock+, +translate="no"+/+data-notrans+, and an optional
    # +selector_categories+ map. Missing items are queued for registration.
    class Page
      BLOCK_ELEMENTS = %w[
        div section article header footer nav aside main
        p h1 h2 h3 h4 h5 h6 blockquote pre address
        ul ol li dl dt dd
        table tr th td thead tbody tfoot caption
        form fieldset legend figure figcaption
        details summary dialog
      ].to_set.freeze

      SKIP_ELEMENTS = %w[script style noscript template svg math].to_set.freeze
      META_NAMES = %w[description keywords author].freeze
      OG_PROPERTIES = %w[og:title og:description og:site_name].freeze
      TWITTER_PROPERTIES = %w[twitter:title twitter:description].freeze

      def self.translate(client, html, default_category = nil, selector_categories = nil)
        return html if html.nil? || html.empty?

        Html.ensure_nokogiri!
        new(client, default_category).translate(html, selector_categories || {})
      end

      def initialize(client, default_category)
        @client = client
        @default_category = default_category
        @locale = client.effective_locale
        @attrs = client.translatable_attributes
      end

      def translate(html, selector_categories)
        doc = Nokogiri::HTML(html)
        @selmap = build_selector_map(doc, selector_categories)
        process_head(doc)
        root = doc.at_xpath("//body") || doc
        walk(root, nil)
        doc.to_html
      end

      private

      # -- head ---------------------------------------------------------------

      def process_head(doc)
        doc.root["lang"] = @locale if doc.root
        head = doc.at_xpath("//head")
        return if head.nil?

        title = head.at_xpath("./title")
        if title && title.text.strip != ""
          title.content = @client.translate(title.text.strip, category: @default_category, locale: @locale)
        end

        head.xpath("./meta").each { |meta| translate_meta(meta) }
      end

      def translate_meta(meta)
        content = meta["content"]
        return if content.nil? || content.empty?

        name = meta["name"] || ""
        prop = meta["property"] || ""
        if META_NAMES.include?(name) || TWITTER_PROPERTIES.include?(name)
          meta["content"] = @client.translate(content, category: @default_category, locale: @locale)
        elsif !prop.empty?
          translate_meta_property(meta, prop, content)
        end
      end

      def translate_meta_property(meta, prop, content)
        if prop == "og:locale"
          meta["content"] = og_locale(@locale)
        elsif OG_PROPERTIES.include?(prop) || TWITTER_PROPERTIES.include?(prop)
          meta["content"] = @client.translate(content, category: @default_category, locale: @locale)
        end
      end

      def og_locale(locale)
        parts = locale.tr("-", "_").split("_")
        return "#{parts[0].downcase}_#{parts[1].upcase}" if parts.length >= 2

        "#{parts[0].downcase}_#{parts[0].upcase}"
      end

      # -- body ---------------------------------------------------------------

      def walk(node, inherited)
        node.element_children.each do |child|
          tag = child.name.downcase
          next if SKIP_ELEMENTS.include?(tag)
          next if child["translate"] == "no" || Html.to_s_or_nil(child["data-notrans"])

          effective = effective_category(child, inherited)

          if content_block_attr?(child)
            handle_block(child, item_category(effective))
          elsif BLOCK_ELEMENTS.include?(tag)
            walk_block(child, effective)
          else
            walk(child, effective)
          end
        end
      end

      def walk_block(child, effective)
        return walk(child, effective) if contains_nested_blocks?(child)

        inner = Html.inner_html(child)
        phrases = Html.extract_phrases(inner, @attrs)
        return if phrases.empty?

        item_cat = item_category(effective)
        text = Html.text_content(child)
        if phrases.length == 1 && phrases[0] == text
          category = item_cat == UNCATEGORIZED ? nil : item_cat
          Html.apply_element(child, { text => @client.translate(text, category: category, locale: @locale) }, @attrs)
        else
          apply_or_queue_block(child, item_cat, phrases, inner)
        end
      end

      def handle_block(element, item_cat)
        inner = Html.inner_html(element)
        phrases = Html.extract_phrases(inner, @attrs)
        return if phrases.empty?

        apply_or_queue_block(element, item_cat, phrases, inner)
      end

      def apply_or_queue_block(element, item_cat, phrases, inner)
        custom_id, block = @client.lookup_block(item_cat, phrases)
        if block
          Html.apply_element(element, block, @attrs)
        else
          @client.queue_content_block(inner, item_cat, custom_id, phrases)
        end
      end

      # -- category resolution ------------------------------------------------

      def item_category(effective)
        return effective unless effective.nil?
        return @default_category unless @default_category.nil?

        UNCATEGORIZED
      end

      def effective_category(element, inherited)
        match = @selmap[element.path]
        return match[0] if match && match[1] # selector override

        attr = element["data-langsys-category"]
        return attr if attr && !attr.empty?
        return inherited unless inherited.nil?
        return match[0] if match && !match[1] # selector, non-override

        nil
      end

      def content_block_attr?(element)
        value = element["data-langsys-contentblock"]
        return false if value.nil?

        value != "" && value != "0" && value.downcase != "false"
      end

      def contains_nested_blocks?(element)
        element.xpath(".//*").any? { |descendant| BLOCK_ELEMENTS.include?(descendant.name.downcase) }
      end

      def build_selector_map(doc, selector_categories)
        result = {}
        selector_categories.each do |selector, spec|
          category, override = parse_spec(spec)
          begin
            matched = doc.css(selector)
          rescue StandardError
            next
          end
          matched.each { |element| result[element.path] = [category, override] }
        end
        result
      end

      def parse_spec(spec)
        return [spec, false] if spec.is_a?(String)

        category = spec[:category] || spec["category"]
        override = spec[:overrideParentElementCategory] || spec["overrideParentElementCategory"] ||
                   spec[:override] || spec["override"]
        [category, !!override]
      end
    end
  end
end
