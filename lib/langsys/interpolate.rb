# frozen_string_literal: true

require "date"
require "set"

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
    # Argument kinds that carry branches, and so can recover to `other` (ICU-1).
    SELECTORS = %w[select plural selectordinal].freeze

    # ICU-4 dedup, process-lifetime. A Set behind a mutex: `t` is called from request
    # threads, and a duplicated notice is the failure mode the rule exists to avoid.
    RECOVERY_NOTICES = Mutex.new
    RECOVERY_NOTICES_SEEN = Set.new

    # Render context threaded through the ICU walk. +defaulted+ collects the argument
    # names recovered on this render, for the ICU-4 notice.
    Ctx = Struct.new(:params, :locale, :defaulted, keyword_init: true)

    module_function

    # True when +template+ uses ICU MessageFormat syntax.
    def icu?(template)
      ICU_PATTERN.match?(template)
    end

    # Render +template+ against +params+ in +locale+.
    #
    # +logger+ enables the ICU-4 recovery notice; without one, recovery is silent (a
    # notice that ignores the log level warns in production on every render).
    def call(template, params, locale = "en", logger: nil)
      params ||= {}
      if icu?(template)
        begin
          nodes, = Parser.new(template).parse(0)
          ctx = Ctx.new(params: params, locale: locale, defaulted: [])
          out = render(nodes, ctx, nil, 0, nil)
          note_recovery(template, locale, ctx.defaulted, logger)
          return out
        rescue StandardError
          # Malformed ICU (or an unexpected node) must never blow up a page.
          return simple(template, params, locale)
        end
      end
      simple(template, params, locale)
    end

    # ICU-4: name every argument that was defaulted, and the locale. Deduplicated per
    # (template, locale) for the process lifetime — the same phrase renders thousands of
    # times and the developer needs to learn about it once.
    def note_recovery(template, locale, defaulted, logger)
      return if logger.nil? || defaulted.empty?

      names = defaulted.uniq
      fresh = RECOVERY_NOTICES.synchronize { RECOVERY_NOTICES_SEEN.add?([template, locale, names]) }
      return if fresh.nil?

      logger.debug(
        "langsys: ICU argument(s) #{names.map { |n| "{#{n}}" }.join(', ')} not supplied for locale " \
        "#{locale}; rendered the `other` branch. A source phrase that does not ask for these is " \
        "normal — pass them in params to select a different branch."
      )
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

    def render(nodes, ctx, plural_value, offset, hash_literal)
      nodes.map do |node|
        if node.is_a?(String)
          apply_hash(node, plural_value, offset, ctx.locale, hash_literal)
        else
          render_arg(node, ctx)
        end
      end.join
    end

    # +hash_literal+ is set only inside a *recovered* plural, where there is no count to
    # render (ICU-3): emit the visible +{argName}+ rather than a plausible-but-false number.
    def apply_hash(text, plural_value, offset, locale, hash_literal)
      return text unless text.include?("#")
      return text.gsub("#", hash_literal) if plural_value.nil? && hash_literal
      return text if plural_value.nil?

      text.gsub("#", format_number(plural_value - offset, locale))
    end

    def render_arg(arg, ctx)
      found, value = fetch_param(ctx.params, arg.name)
      return recover(arg, ctx) if !found || value.nil?

      case arg.kind
      when nil then format_value(value, ctx.locale)
      when "number" then format_number(value, ctx.locale)
      when "date", "time" then format_date(value, ctx.locale, arg.style || "medium")
      when "select" then render_select(arg, value, ctx)
      else render_plural(arg, value, ctx)
      end
    end

    # ICU-1/2/3: a select/plural whose argument was not supplied (or was supplied as nil)
    # renders its +other+ branch instead of collapsing to the raw source. Only this node is
    # rewritten — everything else still reaches the ordinary CLDR path, which is what keeps
    # a supplied plural selecting `few` in Polish while its neighbour recovers (ICU-5).
    def recover(arg, ctx)
      return "{#{arg.name}}" unless SELECTORS.include?(arg.kind)

      branch = arg.options && arg.options["other"]
      # No `other` to fall back to: malformed, so leave it to the plain-argument path
      # rather than inventing a branch.
      return "{#{arg.name}}" if branch.nil?

      ctx.defaulted << arg.name
      # `#` has no count inside a recovered plural; a recovered select's `#` stays literal.
      literal = arg.kind == "select" ? nil : "{#{arg.name}}"
      render(branch, ctx, nil, 0, literal)
    end

    def render_select(arg, value, ctx)
      branch = arg.options[value.to_s] || arg.options["other"] || []
      render(branch, ctx, nil, 0, nil)
    end

    def render_plural(arg, value, ctx)
      # Keep integers as integers — a Float 1.0 has a visible fraction digit and would
      # select CLDR "other" instead of "one".
      number = to_number(value)
      exact = arg.options["=#{int_key(number)}"]
      return render(exact, ctx, number, arg.offset, nil) unless exact.nil?

      category = plural_category(number - arg.offset, ctx.locale, ordinal: arg.kind == "selectordinal")
      branch = arg.options[category] || arg.options["other"] || []
      render(branch, ctx, number, arg.offset, nil)
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
