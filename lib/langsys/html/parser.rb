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
    # TOK-2/TOK-4: the whitespace class that decides identity.
    #
    # Ruby's +\s+ is ASCII-only — it matches neither U+00A0 nor U+2028/U+2029 — so the
    # previous class left all three in the token and this SDK minted different ids from
    # the JS family for content identical to every reader. +[[:space:]]+ is Unicode-aware
    # and covers them. Measured, not assumed: see spec/tok_conformance_spec.rb.
    #
    # Known delta, deliberately not papered over: JavaScript's +\s+ also matches U+FEFF,
    # which +[[:space:]]+ does not. No rule names it and no fixture row exercises it, so
    # matching JS there would be this lane inventing a contract detail for four SDKs.
    # Reported to the program instead.
    WHITESPACE = /[[:space:]]+/

    # TOK-1: never tokenized. Excluded BY ELEMENT NAME rather than by trusting the
    # parser's node modelling — Nokogiri happens to give +script+ and +style+ children as
    # CDATA, which the walker's +text?+ test rejects, so those two passed by accident and
    # would start leaking the moment the parser changed underneath.
    #
    # +template+ is a genuine vector here, unlike in the JS family: parse5 hangs template
    # content off a separate fragment so a walker emits nothing from it either way, but
    # libxml2 puts it in the tree, so omitting it from this list would leak.
    #
    # +svg+ and +math+ are deliberately ABSENT. TOK-1 does not name them, and the page
    # translator skips them while this path does not — a real disagreement between the two
    # paths, reported to the program rather than settled here.
    NON_TOKENIZED_ELEMENTS = %w[script style template noscript].freeze

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

      # Collapse first, THEN strip. Order is load-bearing: +String#strip+ is ASCII-only
      # and removes none of U+00A0, U+2028 or U+2029, but the collapse has already turned
      # any leading or trailing run of them into a single U+0020 by the time it runs.
      text.gsub(WHITESPACE, " ").strip
    end

    # True when +name+ is an element whose subtree contributes no tokens (TOK-1).
    def excluded_from_tokenizing?(name)
      NON_TOKENIZED_ELEMENTS.include?(name.to_s.downcase)
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

      # Unicode-aware for the same reason as the collapse: a node whose leading character
      # is U+00A0 has that character normalised out of its token, so ASCII \s here would
      # decide the translation needs no leading space and silently reflow the text.
      lead = text.match?(/\A[[:space:]]/) ? " " : ""
      trail = text.match?(/[[:space:]]\z/) ? " " : ""
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
