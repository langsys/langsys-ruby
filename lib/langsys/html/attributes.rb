# frozen_string_literal: true

module Langsys
  module Html
    # The default translatable-attribute list — matches the PHP/Python SDKs exactly.
    DEFAULT_TRANSLATABLE_ATTRIBUTES = %w[
      placeholder
      alt
      title
      label
      aria-label
      aria-placeholder
      aria-description
      aria-valuetext
      aria-roledescription
      data-error
      data-error-message
      data-validation-message
      data-invalid-message
      data-required-message
      data-pattern-message
      data-confirm
      data-tooltip
      data-title
      data-content
      data-original-title
      data-bs-title
      data-bs-content
      data-loading-text
      data-success-message
      data-warning-message
      data-empty-message
      data-placeholder
    ].freeze
  end
end
