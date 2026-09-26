# frozen_string_literal: true

module Langsys
  # The client half of the server-message contract (MSG-5/6/8/11).
  module ClientMessages
    attr_reader :messages_category

    # MSG-5's helper, for a binding to render an entry: t(template, params) when the catalog
    # holds a translation for the template, and the server's own message otherwise. message is
    # never a lookup key.
    def render_message(entry, locale: nil)
      entry = entry.transform_keys(&:to_s)
      loc = effective_locale(locale)
      catalog = @catalog.get(loc)
      entries = catalog && catalog[@messages_category]
      value = entries.is_a?(Hash) ? entries[entry["template"]] : nil
      return entry["message"] unless value.is_a?(String) && !value.empty?

      interpolate(value, (entry["params"] || {}).transform_keys(&:to_sym), loc)
    end

    # MSG-8: build the entry a server sends and, when the catalog has not listed its template,
    # record it for registration on the ordinary flush path, after the response when a request
    # scope is open, and only on a key that may write. Never blocks the request.
    def emit_message(template:, params: nil, field: nil, code: nil)
      entry = Messages.entry(template: template, params: params, field: field, code: code)
      catalog = @catalog.get(effective_locale)
      return entry if catalog.nil? # WIRE-4: no catalog, record nothing

      warn_translatable_markers(template, entry["params"], catalog)
      entries = catalog[@messages_category]
      unless entries.is_a?(Hash) && entries.key?(entry["template"])
        queue_missing(entry["template"], @messages_category,
                      catalog)
      end
      entry
    end

    # Whether the catalog already lists +template+ under the messages category (MSG-7 idempotence).
    def message_template_known?(template)
      entries = @catalog.get(effective_locale, use_cache: false)&.dig(@messages_category)
      entries.is_a?(Hash) && entries.key?(template)
    end

    private

    # MSG-11, the fill-time check: a marker filled with a string that is itself a source phrase
    # in the catalog is a translatable value put where it can never be translated. Once per
    # (template, marker).
    def warn_translatable_markers(template, params, catalog)
      (params || {}).each do |name, value|
        next unless value.is_a?(String) && catalogued?(catalog, value)
        next unless @message_warnings.add?([template, name])

        @logger&.warn("langsys: marker {#{name}} in #{template.inspect} was filled with #{value.inspect}, a " \
                      "catalogued phrase. A translatable value in a marker is never translated; write it into " \
                      "the sentence as its own template instead.")
      end
    end

    def catalogued?(catalog, value)
      catalog.any? { |_, entries| entries.is_a?(Hash) && entries.key?(value) }
    end
  end
end
