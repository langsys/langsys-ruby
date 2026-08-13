# frozen_string_literal: true

require_relative "http"
require_relative "locale"
require_relative "types"

module Langsys
  # Reference-data helpers: countries, dial codes, currencies, and locale names. Everything
  # is fetched live from nova (nothing bundled) and cached per display locale; names are
  # returned already localized into the requested locale.
  class Utilities
    def initialize(http, project_id)
      @http = http
      @project_id = project_id
      @countries = {}
      @dial_codes = {}
      @currencies = {}
      @locales_flat = {}
      @locales_data = {}
      @locales_grouped = {}
    end

    def countries(locale)
      loc = Locale.normalize_locale(locale)
      @countries[loc] ||= list("countries/#{Http.encode_segment(loc)}").map do |r|
        Country.new(code: (r["code"] || "").to_s, label: (r["label"] || "").to_s)
      end
    end

    def dial_codes(locale)
      loc = Locale.normalize_locale(locale)
      @dial_codes[loc] ||= list("countries/dial-codes/#{Http.encode_segment(loc)}").map do |r|
        DialCode.new(
          country_code: (r["country_code"] || "").to_s,
          dial_code: (r["dial_code"] || "").to_s,
          name: (r["name"] || "").to_s
        )
      end
    end

    def currencies(locale)
      loc = Locale.normalize_locale(locale)
      @currencies[loc] ||= list("currencies/#{Http.encode_segment(loc)}").map do |r|
        Currency.new(
          code: (r["code"] || "").to_s,
          name: (r["name"] || "").to_s,
          symbol: (r["symbol"] || "").to_s,
          symbol_native: (r["symbol_native"] || "").to_s,
          decimal_digits: (r["decimal_digits"] || 2).to_i,
          rounding: (r["rounding"] || 0).to_f
        )
      end
    end

    def country_name(code, locale)
      return "" if code.nil? || code.empty?

      match = countries(locale).find { |c| c.code.downcase == code.downcase }
      match ? match.label : code
    end

    def currency_name(code, locale)
      return "" if code.nil? || code.empty?

      match = currencies(locale).find { |c| c.code.downcase == code.downcase }
      match ? match.name : code
    end

    def locales_flat(locale)
      loc = Locale.normalize_locale(locale)
      @locales_flat[loc] ||= locales_object("locales/flat", loc).map do |r|
        LocaleFlat.new(code: (r["code"] || "").to_s, name: (r["name"] || "").to_s)
      end
    end

    def locales_data(locale)
      loc = Locale.normalize_locale(locale)
      @locales_data[loc] ||= locales_object("locales/data", loc).map do |r|
        LocaleInfo.new(
          code: (r["code"] || "").to_s,
          locale_name: (r["locale_name"] || "").to_s,
          lang_name: (r["lang_name"] || "").to_s
        )
      end
    end

    # Locales grouped by language name (the +/locales+ index format).
    def locales(locale)
      loc = Locale.normalize_locale(locale)
      @locales_grouped[loc] ||= begin
        response = @http.get("locales", locale_params(loc))
        group = pick_locale_bucket(response["data"], loc)
        grouped = {}
        if group.is_a?(Hash)
          group.each do |lang, rows|
            grouped[lang] = Array(rows).map do |r|
              LocaleFlat.new(code: (r["code"] || "").to_s, name: (r["name"] || "").to_s)
            end
          end
        end
        grouped
      end
    end

    def locale_name(for_locale, short: false, locale: "en-US")
      return "" if for_locale.nil? || for_locale.empty?

      target = for_locale.downcase
      info = locales_data(locale).find { |i| i.code.downcase == target }
      return for_locale unless info

      short ? info.lang_name : info.locale_name
    end

    def clear
      [@countries, @dial_codes, @currencies, @locales_flat, @locales_data, @locales_grouped].each(&:clear)
    end

    private

    def list(path)
      data = @http.get(path)["data"]
      data.is_a?(Array) ? data : []
    end

    def locale_params(loc)
      # nova keys the response by each requested locale; ask for the one we want.
      { "locales[]" => loc, "project_id" => @project_id }
    end

    def locales_object(path, loc)
      response = @http.get(path, locale_params(loc))
      bucket = pick_locale_bucket(response["data"], loc)
      bucket.is_a?(Array) ? bucket : []
    end

    # +data+ is an object keyed by the requested locale(s); pick ours (case-insensitively),
    # falling back to the first value.
    def pick_locale_bucket(data, loc)
      return data unless data.is_a?(Hash)

      data.each { |key, value| return value if key.downcase == loc.downcase }
      data.values.first
    end
  end
end
