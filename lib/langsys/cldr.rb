# frozen_string_literal: true

require "date"

module Langsys
  # Locale-aware value formatting, backed by twitter_cldr and defensive throughout: a
  # formatting failure must degrade to something printable rather than blank a page.
  #
  # Split out of Interpolate because it answers a different question. Interpolate decides
  # which branch of a message renders and which arguments are missing; this decides how a
  # number, a date or a plural category looks once that is settled.
  module Cldr
    DATE_STYLES = %w[short medium long full].freeze

    module_function

    def format_value(value, locale)
      case value
      when true then "true"
      when false then "false"
      when Date, Time, DateTime then format_date(value, locale)
      when Integer, Float then format_number(value, locale)
      else value.to_s
      end
    end

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
  end
end
