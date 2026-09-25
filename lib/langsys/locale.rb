# frozen_string_literal: true

module Langsys
  # BCP-47 locale helpers — canonicalization and +Accept-Language+ matching.
  #
  # +canonicalize_locale+ is the Ruby analog of the other SDKs' +canonicalizeLocale+:
  # language lowercase, script Titlecase, region UPPERCASE (+en-us+ -> +en-US+,
  # +zh-hant-tw+ -> +zh-Hant-TW+), underscores normalized to hyphens. It degrades to a
  # best-effort casing rather than raising on odd input.
  module Locale
    module_function

    # Canonical BCP-47 casing. Empty/nil -> "".
    def canonicalize_locale(locale)
      return "" if locale.nil?

      cleaned = locale.to_s.strip.tr("_", "-")
      return "" if cleaned.empty?

      parts = cleaned.split("-")
      out = [parts[0].downcase]
      parts[1..].each do |part|
        out << if part.length == 4 && part.match?(/\A[A-Za-z]+\z/)
                 part.capitalize          # script: Titlecase
               elsif part.length == 2 || (part.length == 3 && part.match?(/\A\d+\z/))
                 part.upcase              # region
               else
                 part.downcase
               end
      end
      out.join("-")
    end

    # Lowercase, hyphenated form (+en_US+ -> +en-us+). Some backend routes key on this.
    def normalize_locale(locale)
      return "" if locale.nil?

      locale.to_s.strip.tr("_", "-").downcase
    end

    # Parse an +Accept-Language+ header into locales, most-preferred first. Honors +;q=+
    # weights (default 1), drops +*+ and out-of-range/invalid weights, and returns a stable
    # order sorted by descending quality.
    def parse_accept_language(header)
      return [] if header.nil? || header.empty?

      entries = []
      header.split(",").each_with_index do |raw, index|
        token = raw.strip
        next if token.empty? || token.start_with?("*")

        locale, _sep, params = token.partition(";")
        locale = locale.strip
        next if locale.empty?

        quality = 1.0
        unless params.empty?
          key, _eq, value = params.strip.partition("=")
          if key.strip.downcase == "q"
            begin
              quality = Float(value.strip)
            rescue ArgumentError, TypeError
              next
            end
          end
        end
        next unless quality > 0.0 && quality <= 1.0

        # -index keeps the original order stable among equal q-values.
        entries << [quality, -index, locale]
      end
      entries.sort_by { |q, order, _| [-q, -order] }.map { |_, _, locale| locale }
    end

    # Best supported locale for a user's preference list, or +nil+. Two tiers: (1) exact
    # canonical match, (2) primary-language match (so +en+ matches +en-US+).
    def find_best_locale_match(user_locales, supported)
      canonical = supported.map { |s| canonicalize_locale(s) }
      by_lower = canonical.to_h { |c| [c.downcase, c] }

      user_locales.each do |user|
        cu = canonicalize_locale(user).downcase
        return by_lower[cu] if by_lower.key?(cu)
      end

      supported_langs = canonical.map { |c| [c.split("-").first.downcase, c] }
      user_locales.each do |user|
        ulang = canonicalize_locale(user).split("-").first.downcase
        next if ulang.empty?

        supported_langs.each { |lang, code| return code if lang == ulang }
      end
      nil
    end

    # Best locale for an +Accept-Language+ header.
    #
    # * With +supported+: the best match (exact or language), or +nil+ if nothing matches,
    #   so the caller can fall back to a default.
    # * Without +supported+: the top preference in canonical form, or +nil+ when the header
    #   yields nothing.
    def detect_preferred_locale(accept_language = nil, supported = nil)
      preferences = parse_accept_language(accept_language)
      return nil if preferences.empty?
      return find_best_locale_match(preferences, supported) if supported && !supported.empty?

      canonicalize_locale(preferences.first)
    end

    # SRV-6: the request locale is the first usable candidate from the URL, then a cookie or
    # session value, then Accept-Language negotiated against the project's locales, and
    # otherwise the base locale. A candidate is used only when it names a locale the project
    # serves, so nothing a visitor typed is ever echoed or worth persisting. +vary+
    # names every header the choice read: the URL is the cache key already, so it adds none.
    #
    # Returns {locale:, source: :url | :cookie | :accept_language | nil, vary: [...]}.
    def resolve_request_locale(supported:, base:, url: nil, cookie: nil, accept_language: nil)
      served = Array(supported).map { |s| normalize_locale(s) }.reject(&:empty?)
      vary = []
      { url: url, cookie: cookie }.each do |source, candidate|
        next if blank?(candidate)

        vary << "Cookie" if source == :cookie
        match = validated(candidate, served)
        return { locale: match, source: source, vary: vary } if match
      end
      unless blank?(accept_language)
        vary << "Accept-Language"
        match = find_best_locale_match(parse_accept_language(accept_language), served)
        return { locale: normalize_locale(match), source: :accept_language, vary: vary } if match
      end
      { locale: normalize_locale(base), source: nil, vary: vary }
    end

    def validated(candidate, served)
      normalized = normalize_locale(candidate)
      served.include?(normalized) ? normalized : nil
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
