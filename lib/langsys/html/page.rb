# frozen_string_literal: true

require "set"

require_relative "parser"
require_relative "markup"

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

      SKIP_ELEMENTS = %w[script style noscript template math].to_set.freeze
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

      # True only for an authoring declaration. See Html.classify_block_attribute.
      def self.content_block_marked?(element)
        Html.classify_block_attribute(element) == :declaration
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

      # The explicit block API (translate_content_block): the fragment is one TOK-6 unit, and
      # any marked host inside it is handled on its own terms.
      def translate_fragment(html, category)
        frag = Html.parse_fragment(html)
        @selmap = {}
        tokens, text_nodes = Html.unit_tokens(frag, @attrs)
        changed = translate_fragment_unit(frag, html, category, tokens, text_nodes) unless tokens.empty?
        hosts = frag.css("*").any? { |el| Html.marked_host?(el) }
        nested_hosts(frag, category) if hosts
        changed || hosts ? Html.inner_html(frag) : html
      end

      def translate(html, selector_categories)
        doc = Nokogiri::HTML(html)
        @selmap = build_selector_map(doc, selector_categories)
        process_head(doc)
        root = doc.at_xpath("//body") || doc
        walk(root, nil)
        mark_resolved_root(doc)
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
        title_text = title && Html.canonical_token(title.text)
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
        content = Html.canonical_token(meta["content"])
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

      # TOK-6: a container of blocks is walked; every other element is a unit, block, inline
      # or void alike, so an <img alt> or <a title> directly under <body> is tokenized.
      # A marked host is handled on its own terms (MARK-2, MARK-3) wherever it sits, and is
      # excised from any unit around it (MARK-4).
      def walk(node, inherited)
        node.element_children.each do |child|
          next if SKIP_ELEMENTS.include?(child.name.downcase) || Html.translation_excluded?(child)

          effective = effective_category(child, inherited)
          if Html.marked_host?(child)
            handle_marked_host(child, effective)
          elsif contains_nested_blocks?(child)
            walk(child, effective)
          else
            translate_unit(child, effective)
            nested_hosts(child, effective)
          end
        end
      end

      # The outermost marked hosts below +element+, each registered once, on its own.
      def nested_hosts(element, category)
        element.element_children.each do |child|
          next if SKIP_ELEMENTS.include?(child.name.downcase) || Html.translation_excluded?(child)

          if Html.marked_host?(child)
            handle_marked_host(child, effective_category(child, category))
          else
            nested_hosts(child, category)
          end
        end
      end

      def handle_marked_host(element, effective)
        if Html.phrase_marked?(element)
          translate_marked_phrase(element, effective)
        elsif Html.classify_block_attribute(element) == :identity
          render_identity(element, effective)
        else
          inner = Html.inner_html(element)
          phrases = Html.extract_phrases(inner, @attrs)
          apply_or_queue_block(element, item_category(effective), phrases, inner) unless phrases.empty?
        end
        nested_hosts(element, effective)
      end

      def translate_fragment_unit(frag, html, category, tokens, text_nodes)
        if Html.phrase_unit?(tokens, text_nodes)
          translated = @client.lookup_phrase(tokens[0], category: phrase_category(category), locale: @locale)
          Html.apply_element(frag, { tokens[0] => translated }, @attrs)
          return translated != tokens[0]
        end

        custom_id, block, available = @client.lookup_block(category, tokens)
        return Html.apply_element(frag, block, @attrs) && true if block

        # WIRE-4 write-storm clause: an unavailable catalog records nothing.
        @client.queue_content_block(html, category, custom_id, tokens) if available
        false
      end

      # One unit: a phrase when its one token is its one text node, otherwise a content block.
      def translate_unit(child, effective)
        tokens, text_nodes = Html.unit_tokens(child, @attrs)
        return if tokens.empty?

        item_cat = item_category(effective)
        unless Html.phrase_unit?(tokens, text_nodes)
          # The registered content must re-tokenize to the same tokens, so a unit whose own
          # attributes carry tokens registers with its tag.
          html = Html.own_tokens?(child, @attrs) ? child.to_html : Html.inner_html(child)
          return apply_or_queue_block(child, item_cat, tokens, html, include_self: true)
        end

        text = tokens[0]
        translated = @client.lookup_phrase(text, category: phrase_category(item_cat), locale: @locale,
                                                 record: record?(child))
        Html.apply_element(child, { text => translated }, @attrs)
        # MARK-1: a rendered phrase host names its SOURCE phrase, which is its identity.
        child["data-ls-phrase"] = text
      end

      # MARK-2: a keep-together host registers whole, its inline markup as tokens.
      def translate_marked_phrase(element, effective)
        text, slots = Html::Markup.encode(element)
        category = phrase_category(item_category(effective))
        unless text.empty?
          rendered = @client.lookup_phrase(text, category: category, locale: @locale, record: record?(element),
                                                 params: Html::Markup.token_params(slots.length))
          Html::Markup.render_into(element, rendered, slots)
        end
        marked_host_attributes(element, category)
      end

      # A phrase host's own attributes (and its descendants', short of a nested marked host)
      # sit outside the tokenized text, so each is a phrase of its own.
      def marked_host_attributes(element, category)
        own_elements(element).each do |target|
          @attrs.each do |attr|
            next if target[attr].nil?

            value = Html.canonical_token(target[attr])
            next if value.empty?

            target[attr] = @client.lookup_phrase(value, category: category, locale: @locale, record: record?(target))
          end
        end
      end

      def own_elements(element)
        [element] + element.element_children.reject { |c| Html.marked_host?(c) }.flat_map { |c| own_elements(c) }
      end

      # MARK-3: an identity host renders from the catalog entry under its id, or keeps its
      # source when there is none, and registers nothing.
      def render_identity(element, effective)
        block = @client.catalog_block(item_category(effective), Html.block_identity(element), locale: @locale)
        Html.apply_element(element, block, @attrs) if block
      end

      def apply_or_queue_block(element, item_cat, phrases, inner, include_self: false)
        custom_id, block, available = @client.lookup_block(item_cat, phrases)
        # MARK-1: the host carries the identity it was rendered from, whether or not the
        # block resolved. A declaration's own attribute becomes the id.
        stamp(element, custom_id)
        if block
          Html.apply_element(element, block, @attrs, include_self: include_self)
        elsif available && record?(element)
          # WIRE-4: only queue when the catalog actually answered — a miss during an
          # outage is not evidence the block is unregistered.
          @client.queue_content_block(inner, item_cat, custom_id, phrases)
        end
      end

      # An unmarked host gets the stamp; a declaration becomes the id. An opt-out is the
      # author's and is never overwritten.
      def stamp(element, custom_id)
        case Html.classify_block_attribute(element)
        when :absent then element["data-ls-contentblock"] = custom_id
        when :declaration then element[Html::CONTENT_BLOCK_MARKERS.find { |a| element[a] }] = custom_id
        end
      end

      # GATE-10 reading: a unit inside a resolved subtree is output, never source.
      def record?(element)
        !Html.resolved_scope?(element)
      end

      def phrase_category(item_cat)
        item_cat == UNCATEGORIZED ? nil : item_cat
      end

      # GATE-10 producing: a render in a locale other than the project's base marks its root
      # resolved; a base-locale render is source and stays discoverable. Unknown base: no mark.
      def mark_resolved_root(doc)
        root = doc.root
        return if root.nil? || Html::RESOLVED_MARKERS.any? { |attr| root[attr] }

        base = @client.project_base_locale
        locale = Locale.normalize_locale(@locale)
        return if base.nil? || base.empty? || Locale.normalize_locale(base) == locale

        root[Html::RESOLVED_MARKERS.first] = locale
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
