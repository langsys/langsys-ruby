# frozen_string_literal: true

require_relative "attributes"
require_relative "canonical"

module Langsys
  # Server-side HTML translation. A faithful port of the PHP/Python SDKs' HTML parser +
  # page translator, built on Nokogiri.
  #
  # Nokogiri (a native-extension gem) is **not** a hard dependency — add `gem "nokogiri"`
  # to use +translate_content_block+ / +translate_page+. Everything else in the SDK works
  # without it.
  module Html
    module_function

    # Require Nokogiri lazily with a helpful message (it's an optional dependency).
    def ensure_nokogiri!
      @nokogiri_loaded ||= begin
        require "nokogiri"
        true
      end
    rescue LoadError => e
      raise Langsys::ConfigurationError,
            "Langsys: HTML translation requires Nokogiri. Add `gem \"nokogiri\"` to your Gemfile. (#{e.message})"
    end

    def skip?(element)
      element["translate"] == "no" || !to_s_or_nil(element["data-notrans"]).nil?
    end

    def to_s_or_nil(value)
      value.nil? || value.to_s.empty? ? nil : value
    end

    # -- extraction -----------------------------------------------------------

    # Extract ordered translatable phrases (duplicates preserved), like the PHP SDK.
    def extract_phrases(html, attributes = nil)
      return [] if html.nil? || html.empty?

      ensure_nokogiri!
      attrs = attributes || DEFAULT_TRANSLATABLE_ATTRIBUTES
      out = []
      walk_extract(parse_fragment(html), attrs, out)
      out
    end

    def walk_extract(node, attrs, out)
      node.children.each do |child|
        if child.element?
          next if skip?(child)
          # TOK-1: the whole subtree, attributes included — a title on a <script> is no
          # more translatable than its body.
          next if excluded_from_tokenizing?(child.name)
          # MARK-2: excised HERE, in the tokenizer, so every path gets it. It used to be
          # done only by the page walker, so the block path folded another SDK's phrase
          # host into the block id.
          next if phrase_marked?(child)
          # MARK-2, the content-block half: another SDK's resolved id, nested or not, is left
          # whole. A declaration nested inside a fragment still folds into it; only an
          # identity is excised.
          next if classify_block_attribute(child) == :identity

          collect_element(child, attrs, out)
          walk_extract(child, attrs, out)
        elsif child.text?
          text = canonical_token(child.content)
          out << text unless text.empty?
        end
      end
    end

    def collect_element(element, attrs, out)
      attrs.each do |attr|
        value = element[attr]
        next unless value && !value.empty?

        normalized = canonical_token(value)
        out << normalized unless normalized.empty?
      end
      button = button_value(element)
      out << button if button
    end

    def button_value(element)
      translatable_button?(element) ? canonical_token(element["value"]) : nil
    end

    # A <button value>, or an <input type=submit|button value> — its value is translatable.
    def translatable_button?(element)
      return false if to_s_or_nil(element["value"]).nil?

      tag = element.name.downcase
      return true if tag == "button"

      tag == "input" && %w[submit button].include?((element["type"] || "").downcase)
    end

    # -- application ----------------------------------------------------------

    # Return +html+ with translated text/attributes substituted from +translations+.
    def apply_block_translations(html, translations, attributes = nil)
      return html if html.nil? || html.empty?

      ensure_nokogiri!
      attrs = attributes || DEFAULT_TRANSLATABLE_ATTRIBUTES
      root = parse_fragment(html)
      walk_apply(root, translations, attrs)
      inner_html(root)
    end

    def walk_apply(node, translations, attrs)
      node.children.each do |child|
        if child.element?
          next if skip?(child)
          # The apply path skips exactly what the extract path skips (CONF-1: extract vs
          # apply). A subtree the tokenizer refused to tokenize is one we refuse to rewrite,
          # or a sibling token that happens to read the same gets written into it.
          next if excluded_from_tokenizing?(child.name)
          next if phrase_marked?(child)
          next if classify_block_attribute(child) == :identity

          apply_attributes(child, translations, attrs)
          walk_apply(child, translations, attrs)
        elsif child.text?
          original = child.content
          translated = translate_text(original, translations)
          child.content = translated unless translated.equal?(original)
        end
      end
    end

    def apply_attributes(element, translations, attrs)
      # Looked up by the CANONICAL token, the same form collection registered. The raw
      # value used to be the key, so an attribute registered collapsed was never found.
      attrs.each do |attr|
        value = element[attr]
        next if value.nil?

        key = canonical_token(value)
        element[attr] = translations[key] if present_translation(translations[key])
      end
      raw = button_value_raw(element)
      key = raw && canonical_token(raw)
      element["value"] = translations[key] if key && present_translation(translations[key])
    end

    def button_value_raw(element)
      translatable_button?(element) ? element["value"] : nil
    end

    def translate_text(text, translations)
      return text if text.nil? || text.empty?

      normalized = canonical_token(text)
      return text if normalized.empty? || !translations.key?(normalized)

      translated = translations[normalized]
      return text if !present_translation(translated) || translated == normalized

      # The same set as the collapse: a node led by a member has it normalised out of the
      # token, so a narrower test here would drop the leading space and reflow the text.
      lead = whitespace_char?(text[0]) ? " " : ""
      trail = whitespace_char?(text[-1]) ? " " : ""
      "#{lead}#{translated}#{trail}"
    end

    def present_translation(value)
      value.is_a?(String) && !value.empty?
    end

    # -- helpers used by full-page translation --------------------------------

    # Apply a translation map in place to an element and its subtree.
    def apply_element(element, translations, attributes = nil)
      attrs = attributes || DEFAULT_TRANSLATABLE_ATTRIBUTES
      walk_apply(element, translations, attrs)
    end

    # Serialize a node's inner HTML (its children, not the node's own tag).
    def inner_html(node)
      node.children.map(&:to_html).join
    end

    # Normalized text content of an element (all descendant text, whitespace-collapsed).
    def text_content(element)
      canonical_token(element.text)
    end

    # Parse an HTML fragment; its children are the top-level nodes.
    def parse_fragment(html)
      Nokogiri::HTML.fragment(html)
    end
  end
end
