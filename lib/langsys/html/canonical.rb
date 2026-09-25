# frozen_string_literal: true

require_relative "../controls"

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

    # MARK-3: the content-block attribute carries three meanings, decided here and only here,
    # by its value trimmed and compared case-insensitively. Bare, empty, true, 1 or yes declare
    # a block; false or 0 opt out; anything else is a custom_id a renderer stamped. No md5 id
    # can be one of the declaration words, so reading them as a declaration costs no identity.
    CONTENT_BLOCK_MARKERS = %w[data-ls-contentblock data-langsys-contentblock].freeze
    BLOCK_DECLARATION_VALUES = ["", "true", "1", "yes"].freeze
    BLOCK_OPT_OUT_VALUES = %w[false 0].freeze

    # GATE-10: text a server already output in a resolved locale. Writers emit the first.
    RESOLVED_MARKERS = %w[data-ls-resolved data-langsys-resolved].freeze

    # Every boolean marker in the fleet reads presence as intent; only these opt out.
    MARKER_OFF_VALUES = %w[false 0].freeze

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

      # TOK-2 order: strip the C0 controls, collapse, then trim by the SAME set. +String#strip+
      # is the wrong trim twice over: it misses every non-ASCII member, and it removes U+0000,
      # which is not a member at all.
      # After the collapse every run is one U+0020, so trimming the set is trimming a space.
      Controls.strip(text).gsub(WHITESPACE, " ").delete_prefix(" ").delete_suffix(" ")
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

    # MARK-2: a keep-together phrase host, in either spelling. Presence is intent.
    def phrase_marked?(element)
      marker_on?(element, PHRASE_MARKERS)
    end

    # MARK-4: a phrase host, or a content-block host that is not an opt-out. Inside a walked
    # unit it contributes no tokens: it is a unit of its own.
    def marked_host?(element)
      phrase_marked?(element) || %i[declaration identity].include?(classify_block_attribute(element))
    end

    # The first spelling present decides; only false or 0 (trimmed, any case) turn it off.
    def marker_on?(element, attributes)
      value = attributes.map { |attr| element[attr] }.compact.first
      !value.nil? && !MARKER_OFF_VALUES.include?(value.strip.downcase)
    end

    # translate="no", or data-notrans present and not switched off.
    def translation_excluded?(element)
      element["translate"].to_s.strip.casecmp?("no") || marker_on?(element, %w[data-notrans])
    end

    # GATE-10 reading: the nearest element carrying a resolved marker decides, so a node's
    # ancestors are read in turn. Text a server prints inline has no element of its own, so
    # the only place a producer can state the fact is an ancestor, usually the root.
    def resolved_scope?(node)
      while node.respond_to?(:element?) && node.element?
        return marker_on?(node, RESOLVED_MARKERS) if RESOLVED_MARKERS.any? { |attr| node[attr] }

        node = node.parent
      end
      false
    end

    # :absent, :declaration, :opt_out or :identity (MARK-3). The first spelling present wins.
    def classify_block_attribute(element)
      value = CONTENT_BLOCK_MARKERS.map { |attr| element[attr] }.compact.first
      return :absent if value.nil?

      normalized = value.strip.downcase
      return :declaration if BLOCK_DECLARATION_VALUES.include?(normalized)
      return :opt_out if BLOCK_OPT_OUT_VALUES.include?(normalized)

      :identity
    end

    # The stamped id of an identity host, as written.
    def block_identity(element)
      CONTENT_BLOCK_MARKERS.map { |attr| element[attr] }.compact.first.to_s.strip
    end

    # True when +name+ is an element whose subtree contributes no tokens (TOK-1).
    def excluded_from_tokenizing?(name)
      NON_TOKENIZED_ELEMENTS.include?(name.to_s.downcase)
    end
  end
end
