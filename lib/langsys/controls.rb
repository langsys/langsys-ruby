# frozen_string_literal: true

module Langsys
  # TOK-2: the 28 C0 controls (U+0001-U+0008, U+000B, U+000C, U+000E-U+001F) are removed from
  # every string that becomes an id input or a catalog key, before anything collapses. Removal
  # is the one treatment every parser agrees with: a libxml2 older than 2.14 deletes them from
  # DOM text before this code runs, and newer parsers keep them. TAB, LF and CR are not in the
  # set; they reach the collapse. NUL, U+007F and the C1 range are kept.
  module Controls
    CODE_POINTS = [*(0x01..0x08), 0x0B, 0x0C, *(0x0E..0x1F)].freeze
    PATTERN = Regexp.new("[#{CODE_POINTS.map { |cp| format('\\u%04X', cp) }.join}]")

    module_function

    def strip(text)
      return text unless text.is_a?(String) && text.match?(PATTERN)

      text.gsub(PATTERN, "")
    end
  end
end
