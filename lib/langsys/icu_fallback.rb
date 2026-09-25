# frozen_string_literal: true

module Langsys
  module Interpolate
    # ICU-6: when the formatter fails on a phrase, render it the way ICU-1 renders a missing
    # argument: for each select or plural pick the branch for the supplied value (an exact
    # =N, then the value's CLDR category in the render locale, else other), fill the supplied
    # values (# and {arg} alike) and drop the construct. An unsupplied value stays the visible
    # {argName} of ICU-3. It never renders "" and never the raw construct.
    #
    # Deliberately independent of Parser: it is what runs when Parser has failed, so it reads
    # the template leniently (an unclosed brace runs to the end) rather than rejecting it.
    module Fallback
      SELECTOR = /\A\s*([A-Za-z_][\w.-]*)\s*,\s*(select|plural|selectordinal)\s*,(.*)\z/m
      FORMATTED = /\A\s*([A-Za-z_][\w.-]*)\s*,\s*(number|date|time)\b/m
      PLAIN = /\A\s*([^{},\s][^{},]*?)\s*\z/

      module_function

      def render(text, params, locale, hash = nil)
        out = +""
        i = 0
        while i < text.length
          open = text.index("{", i)
          if open.nil?
            out << fill_hash(text[i..], hash)
            break
          end
          out << fill_hash(text[i...open], hash)
          close = matching(text, open)
          out << argument(text[(open + 1)...close], params, locale, hash)
          i = close + 1
        end
        out
      end

      # Index of the brace closing the one at +open+, or the end of the text when unclosed.
      def matching(text, open)
        depth = 0
        (open...text.length).each do |j|
          depth += 1 if text[j] == "{"
          depth -= 1 if text[j] == "}"
          return j if depth.zero?
        end
        text.length
      end

      def argument(inner, params, locale, hash)
        if (m = SELECTOR.match(inner))
          selector(m[1], m[2], m[3], params, locale)
        elsif (m = FORMATTED.match(inner) || PLAIN.match(inner))
          found, value = Interpolate.fetch_param(params, m[1].strip)
          found && !value.nil? ? Cldr.format_value(value, locale) : "{#{m[1].strip}}"
        else
          render(inner, params, locale, hash)
        end
      end

      def selector(name, kind, body, params, locale)
        options = branches(body)
        found, value = Interpolate.fetch_param(params, name)
        missing = !found || value.nil?
        key = missing ? "other" : pick(kind, value, options, locale)
        branch = options[key] || options["other"]
        return "{#{name}}" if branch.nil?

        hash = if kind == "select" then nil
               elsif missing then "{#{name}}"
               else Cldr.format_number(Interpolate.to_number(value), locale)
               end
        render(branch, params, locale, hash)
      end

      def pick(kind, value, options, locale)
        return value.to_s if kind == "select"

        number = Interpolate.to_number(value)
        exact = "=#{Interpolate.int_key(number)}"
        return exact if options.key?(exact)

        Cldr.plural_category(number, locale, ordinal: kind == "selectordinal")
      end

      # "one {# car} other {# cars}" -> {"one" => "# car", "other" => "# cars"}; lenient.
      def branches(body)
        options = {}
        i = 0
        while (m = /\G\s*(?:offset:\s*\d+\s*)?(=?[\w-]+)\s*\{/.match(body, i))
          open = m.end(0) - 1
          close = matching(body, open)
          options[m[1]] = body[(open + 1)...close].to_s
          i = close + 1
        end
        options
      end

      def fill_hash(text, hash)
        hash.nil? ? text : text.gsub("#", hash)
      end
    end
  end
end
