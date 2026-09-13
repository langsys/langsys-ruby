# frozen_string_literal: true

module Langsys
  # Identity canonicalization: which characters, elements and markers reach a token. Shared
  # by the extract path and the apply path, so the two cannot disagree about it.
  #
  # Split out of parser.rb because this is the part every SDK must match byte for byte, and
  # a reader auditing identity should find all of it in one place. The JS core keeps the same
  # rules together in identity.ts; PHP keeps them in Canonical.
  module Html
    # TOK-2 (8.0.1): the collapse set is exactly what JavaScript's +\s+ matches, because the
    # JS core is the identity authority and "whitespace" is not a portable word. Enumerated
    # as integer code points so no invisible character appears in this source.
    #
    # Measured before this change: +[[:space:]]+ differed from this set by exactly two
    # characters. It missed U+FEFF, which the spec names as a member POSIX classes miss,
    # and it included U+0085, which the spec names as a non-member that must survive.
    # U+001C-U+001F are in neither, so the range held for the strip ruling is untouched.
    WHITESPACE_CODE_POINTS = [
      0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, *(0x2000..0x200A),
      0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF
    ].freeze

    WHITESPACE = Regexp.new("[#{WHITESPACE_CODE_POINTS.map { |cp| Regexp.escape([cp].pack('U')) }.join}]+")

    # TOK-5 (8.0.1): the JS core's capture-time escape, byte for byte: identifier keys only,
    # and unconditional at capture, so the stored phrase and its id are the {name} form.
    PLACEHOLDER_ESCAPE = /%([A-Za-z_][A-Za-z0-9_]*)%/

    # MARK-2: both spellings of the phrase identity marker.
    PHRASE_MARKERS = %w[data-ls-phrase data-langsys-phrase].freeze

    # The content-block attribute carries three meanings, decided here and only here.
    CONTENT_BLOCK_MARKERS = %w[data-ls-contentblock data-langsys-contentblock].freeze
    BLOCK_DECLARATION_VALUES = %w[1 true yes on].freeze
    BLOCK_OPT_OUT_VALUES = %w[0 false off no].freeze
    # The bare attribute, <div data-ls-contentblock>, which parses as "". CONTESTED and routed
    # for a fleet ruling: the TS core's marker convention treats presence as intent, while
    # "bare walks as ordinary content" was prescribed to the Python lane. One constant, so
    # the ruling flips one line.
    BARE_BLOCK_ATTRIBUTE = :opt_out

    # TOK-1 (8.0.1): never tokenized. Excluded BY ELEMENT NAME rather than by trusting the
    # parser's node modelling: Nokogiri happens to give +script+ and +style+ children as
    # CDATA, which a +text?+ test rejects, so those two once passed by accident.
    #
    # +template+ is load-bearing under libxml2, which puts template children in the tree.
    # +math+ joined in 8.0.1: MathML is notation, and translating a variable or an operator
    # corrupts it. +svg+ is deliberately ABSENT: its +<text>+ renders words a reader sees.
    NON_TOKENIZED_ELEMENTS = %w[script style template noscript math].freeze

    module_function

    def normalize_whitespace(text)
      return "" if text.nil?

      # Collapse, then trim by the SAME set. +String#strip+ is the wrong trim twice over: it
      # misses every non-ASCII member, and it removes U+0000, which is not a member at all.
      # After the collapse every run is one U+0020, so trimming the set is trimming a space.
      text.gsub(WHITESPACE, " ").delete_prefix(" ").delete_suffix(" ")
    end

    # TOK-2 then TOK-5, in that order, as the JS core does. The one function every token
    # site AND every lookup site calls, so a register/lookup pair cannot drift apart.
    def canonical_token(text)
      normalize_markup_placeholders(normalize_whitespace(text))
    end

    def normalize_markup_placeholders(text)
      return text unless text.include?("%")

      text.gsub(PLACEHOLDER_ESCAPE) { "{#{Regexp.last_match(1)}}" }
    end

    def whitespace_char?(char)
      !char.nil? && WHITESPACE.match?(char)
    end

    # MARK-2: a host already carrying a phrase identity, in either spelling.
    def phrase_marked?(element)
      PHRASE_MARKERS.any? { |attr| !element[attr].nil? }
    end

    # :absent, :declaration, :opt_out or :identity. The first spelling present wins.
    #
    # A declaration is this SDK's authoring affordance. An opt-out, including the bare
    # boolean attribute, walks the subtree as ordinary content. Anything else is another
    # SDK's resolved id: a custom_id is never empty, 0 or false, so reading those as an
    # identity gains nothing and costs the subtree its discovery.
    def classify_block_attribute(element)
      value = CONTENT_BLOCK_MARKERS.map { |attr| element[attr] }.compact.first
      return :absent if value.nil?

      normalized = value.strip.downcase
      return BARE_BLOCK_ATTRIBUTE if normalized.empty?
      return :declaration if BLOCK_DECLARATION_VALUES.include?(normalized)
      return :opt_out if BLOCK_OPT_OUT_VALUES.include?(normalized)

      :identity
    end

    # True when +name+ is an element whose subtree contributes no tokens (TOK-1).
    def excluded_from_tokenizing?(name)
      NON_TOKENIZED_ELEMENTS.include?(name.to_s.downcase)
    end
  end
end
