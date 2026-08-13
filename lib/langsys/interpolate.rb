# frozen_string_literal: true

require "date"

module Langsys
  # Parameter interpolation with locale-aware CLDR formatting and an ICU subset.
  #
  # Behaviour mirrors the other Langsys SDKs so +{name}+ phrases render identically across
  # languages:
  #
  # * +{name}+ slots are substituted from +params+; an unknown key or +nil+ value is **left
  #   visible** (+{name}+) rather than blanked, so missing data is obvious.
  # * numbers and dates are CLDR-formatted for the target locale (pass a string to opt out
  #   of grouping — for ids and codes); +true+/+false+ render as +"true"+/+"false"+.
  # * ICU MessageFormat (+{n, plural, …}+ / +select+ / +selectordinal+ /
  #   +{n, number|date|time}+) is handled by a small pure-Ruby parser backed by CLDR plural
  #   rules. Anything malformed degrades to simple interpolation instead of raising.
  module Interpolate
    # Detection: an argument whose second token is a known ICU keyword. The trailing
    # +[,}]+ also matches style-less +{n, number}+.
    ICU_PATTERN = /\{[^{}]+,\s*(?:plural|select|selectordinal|number|date|time)\s*[,}]/
    SIMPLE_SLOT = /\{([^{},]+)\}/
    DATE_STYLES = %w[short medium long full].freeze

    module_function

    # True when +template+ uses ICU MessageFormat syntax.
    def icu?(template)
      ICU_PATTERN.match?(template)
    end

    # Render +template+ against +params+ in +locale+.
    def call(template, params, locale = "en")
      params ||= {}
      if icu?(template)
        begin
          nodes, = Parser.new(template).parse(0)
          return render(nodes, params, locale, nil, 0)
        rescue StandardError
          # Malformed ICU (or an unexpected node) must never blow up a page.
          return simple(template, params, locale)
        end
      end
      simple(template, params, locale)
    end

    # -- simple {name} interpolation -----------------------------------------

    def simple(template, params, locale)
      template.gsub(SIMPLE_SLOT) do
        key = Regexp.last_match(1).strip
        found, value = fetch_param(params, key)
        if !found || value.nil?
          "{#{key}}"
        else
          format_value(value, locale)
        end
      end
    end

    # Look up +name+ in +params+ allowing string or symbol keys. Returns [found, value].
    def fetch_param(params, name)
      if params.key?(name)
        [true, params[name]]
      elsif params.key?(name.to_sym)
        [true, params[name.to_sym]]
      else
        [false, nil]
      end
    end

    def format_value(value, locale)
      case value
      when true then "true"
      when false then "false"
      when Date, Time, DateTime then format_date(value, locale)
      when Integer, Float then format_number(value, locale)
      else value.to_s
      end
    end

    # -- CLDR formatting (via twitter_cldr, defensively) ---------------------

    def cldr_locale(locale)
      (locale || "en").to_s.split(/[-_]/).first.downcase.to_sym
    rescue StandardError
      :en
    end

    def format_number(value, locale)
      # A whole-valued Float formats as an integer ("3", not "3.0") — matching the other SDKs.
      value = value.to_i if value.is_a?(Float) && value == value.to_i
      require "twitter_cldr"
      value.localize(cldr_locale(locale)).to_s
    rescue StandardError
      value.to_s
    end

    def format_date(value, locale, style = "medium")
      style = "medium" unless DATE_STYLES.include?(style)
      require "twitter_cldr"
      localized = value.localize(cldr_locale(locale))
      localized.public_send("to_#{style}_s")
    rescue StandardError
      value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
    end

    def plural_category(number, locale, ordinal:)
      require "twitter_cldr"
      type = ordinal ? :ordinal : :cardinal
      TwitterCldr::Formatters::Plurals::Rules.rule_for(number, cldr_locale(locale), type).to_s
    rescue StandardError
      number == 1 ? "one" : "other"
    end

    # -- ICU render -----------------------------------------------------------

    def render(nodes, params, locale, plural_value, offset)
      nodes.map do |node|
        if node.is_a?(String)
          apply_hash(node, plural_value, offset, locale)
        else
          render_arg(node, params, locale)
        end
      end.join
    end

    def apply_hash(text, plural_value, offset, locale)
      return text if plural_value.nil? || !text.include?("#")

      text.gsub("#", format_number(plural_value - offset, locale))
    end

    def render_arg(arg, params, locale)
      found, value = fetch_param(params, arg.name)
      return "{#{arg.name}}" if !found || value.nil?

      case arg.kind
      when nil then format_value(value, locale)
      when "number" then format_number(value, locale)
      when "date", "time" then format_date(value, locale, arg.style || "medium")
      when "select" then render_select(arg, value, params, locale)
      else render_plural(arg, value, params, locale)
      end
    end

    def render_select(arg, value, params, locale)
      branch = arg.options[value.to_s] || arg.options["other"] || []
      render(branch, params, locale, nil, 0)
    end

    def render_plural(arg, value, params, locale)
      # Keep integers as integers — a Float 1.0 has a visible fraction digit and would
      # select CLDR "other" instead of "one".
      number = to_number(value)
      exact = arg.options["=#{int_key(number)}"]
      return render(exact, params, locale, number, arg.offset) unless exact.nil?

      category = plural_category(number - arg.offset, locale, ordinal: arg.kind == "selectordinal")
      branch = arg.options[category] || arg.options["other"] || []
      render(branch, params, locale, number, arg.offset)
    end

    # Coerce a param to a number, preserving integer-ness (Integer stays Integer; "3" -> 3).
    def to_number(value)
      return value if value.is_a?(Numeric)

      float = Float(value, exception: false)
      return value if float.nil?

      float == float.to_i ? float.to_i : float
    end

    def int_key(number)
      number.is_a?(Numeric) && number == number.to_i ? number.to_i.to_s : number.to_s
    end

    # A parsed ICU argument node.
    Arg = Struct.new(:name, :kind, :style, :options, :offset, keyword_init: true)

    # Recursive-descent parser for the ICU MessageFormat subset. Ported from the shared SDK
    # grammar; +#+ inside a plural/selectordinal submessage renders (value - offset).
    class Parser
      def initialize(text)
        @text = text
        @n = text.length
      end

      # Parse a message body starting at +i+; stop at end or an unmatched +}+.
      def parse(index)
        nodes = []
        buf = +""
        i = index
        while i < @n
          ch = @text[i]
          break if ch == "}"

          if ch == "'"
            i = consume_quoted(i, buf)
            next
          end
          if ch == "{"
            unless buf.empty?
              nodes << buf.dup
              buf.clear
            end
            arg, i = parse_argument(i)
            nodes << arg
            next
          end
          buf << ch
          i += 1
        end
        nodes << buf.dup unless buf.empty?
        [nodes, i]
      end

      private

      # ICU apostrophe escaping: '{' , '' -> '
      def consume_quoted(i, buf)
        if i + 1 < @n && @text[i + 1] == "'"
          buf << "'"
          return i + 2
        end
        j = i + 1
        while j < @n && @text[j] != "'"
          buf << @text[j]
          j += 1
        end
        j < @n ? j + 1 : j
      end

      def parse_argument(index)
        i = index + 1 # skip '{'
        name, i = read_until(i, ",}")
        name = name.strip
        raise ArgumentError, "unterminated argument" if i >= @n
        return [Arg.new(name: name, kind: nil, style: nil, options: nil, offset: 0), i + 1] if @text[i] == "}"

        i += 1 # skip ','
        kind, i = read_until(i, ",}")
        kind = kind.strip

        if %w[number date time].include?(kind)
          style = nil
          if i < @n && @text[i] == ","
            style_text, i = read_until(i + 1, "}")
            style = style_text.strip
            style = nil if style.empty?
          end
          expect(i, "}")
          return [Arg.new(name: name, kind: kind, style: style, options: nil, offset: 0), i + 1]
        end

        if %w[plural selectordinal select].include?(kind)
          expect(i, ",")
          options, offset, i = parse_options(i + 1)
          expect(i, "}")
          return [Arg.new(name: name, kind: kind, style: nil, options: options, offset: offset), i + 1]
        end

        raise ArgumentError, "unsupported argument type: #{kind.inspect}"
      end

      def parse_options(index)
        options = {}
        offset = 0
        i = index
        while i < @n
          i = skip_ws(i)
          break if i >= @n || @text[i] == "}"

          start = i
          i += 1 while i < @n && !whitespace?(@text[i]) && @text[i] != "{"
          selector = @text[start...i]
          if selector.start_with?("offset:")
            offset = selector[7..].to_i
            next
          end
          i = skip_ws(i)
          expect(i, "{")
          nodes, i = parse(i + 1)
          expect(i, "}")
          i += 1
          options[selector] = nodes unless selector.empty?
        end
        [options, offset, i]
      end

      def skip_ws(i)
        i += 1 while i < @n && whitespace?(@text[i])
        i
      end

      def whitespace?(ch)
        ch =~ /\s/
      end

      def read_until(i, stops)
        start = i
        i += 1 while i < @n && !stops.include?(@text[i])
        [@text[start...i], i]
      end

      def expect(i, ch)
        raise ArgumentError, "expected #{ch.inspect} at position #{i}" if i >= @n || @text[i] != ch
      end
    end
  end
end
