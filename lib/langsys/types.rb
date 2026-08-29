# frozen_string_literal: true

module Langsys
  # The default category bucket, matching the backend's sentinel.
  UNCATEGORIZED = "__uncategorized__"

  # A country, localized into the requested display locale (+countries/{loc}+).
  Country = Struct.new(:code, :label, keyword_init: true)

  # An international dialing code (+countries/dial-codes/{loc}+).
  DialCode = Struct.new(:country_code, :dial_code, :name, keyword_init: true)

  # A currency, localized into the requested display locale (+currencies/{loc}+).
  Currency = Struct.new(:code, :name, :symbol, :symbol_native, :decimal_digits, :rounding,
                        keyword_init: true)

  # A locale with display + language names (+locales/data+).
  LocaleInfo = Struct.new(:code, :locale_name, :lang_name, keyword_init: true)

  # A locale code with its display name (+locales/flat+).
  LocaleFlat = Struct.new(:code, :name, keyword_init: true)

  # Project metadata returned by +authorize-project+ (the parts SDKs use).
  Project = Struct.new(:id, :title, :base_locale, :target_locales, :default_locales,
                       :key_type, :batch_limit, :write_enabled, :raw, keyword_init: true) do
    # NB: this describes the KEY, not the session's capability. Capability is
    # +Client#can_write?+, which branches on the server's +write_enabled+ (GATE-1).
    def write_key_type?
      key_type == "write"
    end

    def self.from_response(data)
      settings = data["langsys_settings"] || {}
      items = settings["translatable_items"] || {}
      new(
        id: (data["id"] || "").to_s,
        title: (data["title"] || "").to_s,
        base_locale: (data["base_locale"] || "").to_s,
        target_locales: Array(data["target_locales"]),
        default_locales: data["default_locales"] || {},
        # Verbatim. Collapsing an unrecognised type to "read" is what made `ip_write`
        # unable to register at all, and GATE-8 needs to tell `write` from `ip_write`
        # to know which arm it may infer.
        key_type: (data["key_type"] || "read").to_s,
        batch_limit: (items["batch_limit"] || 200).to_i,
        # nil when the field is absent — a pre-capability server (GATE-8).
        write_enabled: data.key?("write_enabled") ? data["write_enabled"] == true : nil,
        raw: data
      )
    end
  end
end
