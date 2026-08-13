# frozen_string_literal: true

require_relative "attributes"

module Langsys
  # Server-side HTML translation. A faithful port of the PHP/Python SDKs' HTML parser +
  # page translator, built on Nokogiri.
  #
  # Nokogiri (a native-extension gem) is **not** a hard dependency — add `gem "nokogiri"`
  # to use +translate_content_block+ / +translate_page+. Everything else in the SDK works
  # without it.
  module Html
    WHITESPACE = /\s+/

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

    def normalize_whitespace(text)
      return "" if text.nil?

      text.gsub(WHITESPACE, " ").strip
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

          collect_element(child, attrs, out)
          walk_extract(child, attrs, out)
        elsif child.text?
          text = normalize_whitespace(child.content)
          out << text unless text.empty?
        end
      end
    end

    def collect_element(element, attrs, out)
      attrs.each do |attr|
        value = element[attr]
        next unless value && !value.empty?

        normalized = normalize_whitespace(value)
        out << normalized unless normalized.empty?
      end
      button = button_value(element)
      out << button if button
    end

    def button_value(element)
      translatable_button?(element) ? normalize_whitespace(element["value"]) : nil
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
      attrs.each do |attr|
        value = element[attr]
        element[attr] = translations[value] if value && present_translation(translations[value])
      end
      raw = button_value_raw(element)
      element["value"] = translations[raw] if raw && present_translation(translations[raw])
    end

    def button_value_raw(element)
      translatable_button?(element) ? element["value"] : nil
    end

    def translate_text(text, translations)
      return text if text.nil? || text.empty?

      normalized = normalize_whitespace(text)
      return text if normalized.empty? || !translations.key?(normalized)

      translated = translations[normalized]
      return text if !present_translation(translated) || translated == normalized

      lead = text.match?(/\A\s/) ? " " : ""
      trail = text.match?(/\s\z/) ? " " : ""
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
      normalize_whitespace(element.text)
    end

    # Parse an HTML fragment; its children are the top-level nodes.
    def parse_fragment(html)
      Nokogiri::HTML.fragment(html)
    end
  end
end
