# frozen_string_literal: true

module Langsys
  # REG-11: telling deliberate ellipses from upstream truncation.
  #
  # "Loading…", "Saving…" and "Please wait…" are legitimate phrases, so an ellipsis alone
  # is a warning and never a reason to skip registration — silently refusing them would
  # create a new silent failure, which is the class this spec exists to remove. The harm
  # condition is a SECOND signal: a longer catalog entry sharing the prefix, which means
  # the truncated form has already been stored beside the full text.
  #
  # Kept apart from the queue because it is a question about text, answerable on its own.
  module Ellipsis
    TRAILING = /(?:\u2026|\.\.\.)\s*\z/

    module_function

    def ellipsis_stem(phrase)
      return nil unless phrase.is_a?(String)

      stripped = phrase.sub(TRAILING, "")
      stripped == phrase ? nil : stripped.strip
    end

    def truncated_twin?(catalog, category, stem, phrase)
      return false if catalog.nil? || stem.empty?

      entries = catalog[category]
      return false unless entries.is_a?(Hash)

      entries.keys.any? do |key|
        key.is_a?(String) && key != phrase && key.start_with?(stem) && key.length > stem.length
      end
    end
  end
end
