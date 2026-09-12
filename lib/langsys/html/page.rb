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

      # MARK-2: both spellings are accepted on READ; writers emit the data-ls-* one.
      # The pages that mix them are the ordinary case, not an edge — a PHP-rendered page
      # hosting a JS-rendered component is what a customer's site looks like — and a
      # reader that knows one spelling walks straight into the other's host and splits a
      # block that already has an id.
      MARKER_PREFIXES = %w[data-ls- data-langsys-].freeze

      # Read +suffix+ ("category", "contentblock", "phrase") in either spelling. The
      # current spelling wins where a host carries both.
      def self.marker_attr(element, suffix)
        MARKER_PREFIXES.each do |prefix|
          value = element["#{prefix}#{suffix}"]
          return value unless value.nil?
        end
        nil
      end

      # A copy of +element+ with any already-identified descendant host removed, so its
      # text does not join the surrounding block's phrase array. Order matters to a
      # block's id, so a host that another SDK owns must not silently shift it.
      def self.without_marked_hosts(element)
        copy = element.dup
        copy.xpath(".//*").each do |descendant|
          descendant.remove unless marker_attr(descendant, "phrase").nil?
        end
        copy
      end

      def self.content_block_marked?(element)
        value = marker_attr(element, "contentblock")
        return false if value.nil?

        value != "" && value != "0" && value.to_s.downcase != "false"
      end

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
        # Normalised, not stripped. A raw strip is ASCII-only, so a title padded with
        # U+00A0 produced a phrase no other SDK would ever mint — a token path that trims
        # without collapsing, which fixing the collapse alone does not reach (TOK-2).
        title_text = title && Html.normalize_whitespace(title.text)
        if title_text && !title_text.empty?
          title.content = @client.translate(title_text, category: @default_category, locale: @locale)
        end

        head.xpath("./meta").each { |meta| translate_meta(meta) }
      end

      def translate_meta(meta)
        # TOK-2/TOK-4: meta content is a token path like any other. It was handed to
        # translate raw — neither collapsed nor trimmed — so description/keywords/author
        # and the og:/twitter: properties minted ids no other SDK could reproduce.
        #
        # Worth recording how it hid: a search for the whitespace handling that was WRONG
        # (`\s`, `strip`, `split`) cannot find a path that does none of them. TOK-2 says
        # find every site that turns a text node into a token; this is the case where
        # "every site" means the ones doing nothing at all.
        content = Html.normalize_whitespace(meta["content"])
        return if content.empty?

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
          # MARK-2: already identified by another SDK's renderer — leave it whole.
          next if phrase_marked?(child)

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

        inner = Html.inner_html(Page.without_marked_hosts(child))
        phrases = Html.extract_phrases(inner, @attrs)
        return if phrases.empty?

        item_cat = item_category(effective)
        text = Html.text_content(child)
        if phrases.length == 1 && phrases[0] == text
          category = item_cat == UNCATEGORIZED ? nil : item_cat
          Html.apply_element(child, { text => @client.translate(text, category: category, locale: @locale) }, @attrs)
          # MARK-1's other half: a rendered phrase host carries data-ls-phrase, the same
          # way a rendered block carries data-ls-contentblock. Stamped after the
          # translation so the attribute names the SOURCE phrase, which is the identity,
          # not the rendered text.
          child["data-ls-phrase"] = text
        else
          apply_or_queue_block(child, item_cat, phrases, inner)
        end
      end

      def handle_block(element, item_cat)
        # Same excision as the leaf path (MARK-2): a declared content-block host does not
        # own a child another SDK has already identified. Without this the two paths met
        # the rule differently, and the rule was satisfied on whichever one a test used.
        inner = Html.inner_html(Page.without_marked_hosts(element))
        phrases = Html.extract_phrases(inner, @attrs)
        return if phrases.empty?

        apply_or_queue_block(element, item_cat, phrases, inner)
      end

      def apply_or_queue_block(element, item_cat, phrases, inner)
        custom_id, block, available = @client.lookup_block(item_cat, phrases)
        # MARK-1: the host carries the identity it was rendered from, whether or not the
        # block resolved. An identity you cannot read off the DOM is one nobody can
        # debug, and it is most wanted precisely when the block did NOT resolve.
        element["data-ls-contentblock"] = custom_id
        if block
          Html.apply_element(element, block, @attrs)
        elsif available
          # WIRE-4: only queue when the catalog actually answered — a miss during an
          # outage is not evidence the block is unregistered.
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

        attr = Page.marker_attr(element, "category")
        return attr if attr && !attr.empty?
        return inherited unless inherited.nil?
        return match[0] if match && !match[1] # selector, non-override

        nil
      end

      def content_block_attr?(element)
        Page.content_block_marked?(element)
      end

      # MARK-2: a host already carrying a phrase identity — in either spelling — has been
      # rendered by another SDK and is already registered. Walking into it splits a block
      # that has an id and registers its text a second time.
      def phrase_marked?(element)
        !Page.marker_attr(element, "phrase").nil?
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
