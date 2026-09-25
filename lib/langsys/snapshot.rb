# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "errors"
require_relative "locale"

module Langsys
  # A catalog snapshot (spec SNAP family) in the one format every SDK writes and reads,
  # `langsys-catalog-snapshot` v1: each chosen locale's flat catalog from GET /translations,
  # filtered client-side by category, for setups that should not call the API on the render path.
  #
  # A snapshot is a cache, never the source of truth. Its checksum is computed over a canonical
  # serialisation every core produces byte for byte, and a loader refuses a snapshot whose checksum
  # no longer matches: the refresh path is to export again, never to edit.
  class Snapshot
    FORMAT = "langsys-catalog-snapshot"
    VERSION = 1
    HASHED = %w[project_id generated_at base_locale locales categories catalog].freeze
    ESCAPES = { "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f",
                "\r" => "\\r" }.freeze

    attr_reader :project_id, :generated_at, :base_locale, :locales, :categories

    # SNAP-1: one GET /translations per locale, keeping the chosen categories a locale holds.
    def self.export(client, locales:, categories:, generated_at: Time.now.utc)
      wanted = Array(categories).map(&:to_s)
      locs = Array(locales).map { |l| Locale.normalize_locale(l) }
      catalog = locs.to_h do |loc|
        data = client.catalog_data(loc)
        data = {} unless data.is_a?(Hash)
        [loc, data.slice(*wanted).transform_values { |entries| entries.is_a?(Hash) ? entries : {} }]
      end
      new(project_id: client.project_id, generated_at: generated_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          base_locale: Locale.normalize_locale(client.project_base_locale.to_s), locales: locs,
          categories: wanted, catalog: catalog)
    end

    def self.load(path) = parse(File.read(path), source: path)

    # Refuses, each by name, a different format, an unsupported version, a missing member, and a
    # checksum that does not match the canonical serialisation (SNAP-3: an edited snapshot).
    def self.parse(json, source: "snapshot")
      doc = JSON.parse(json)
      refuse(source, "is not a JSON object") unless doc.is_a?(Hash)
      refuse(source, "has format #{doc['format'].inspect}, not #{FORMAT.inspect}") unless doc["format"] == FORMAT
      refuse(source, "has unsupported version #{doc['version'].inspect}") unless doc["version"] == VERSION
      missing = (HASHED + ["checksum"]).reject { |member| doc.key?(member) }
      refuse(source, "is missing #{missing.join(', ')}") unless missing.empty?

      snapshot = new(**HASHED.to_h { |m| [m.to_sym, doc[m]] })
      unless snapshot.checksum == doc["checksum"]
        refuse(source, "does not match its checksum, so it was edited. A snapshot is a cache of the catalog: " \
                       "export it again instead of editing it.")
      end
      snapshot
    end

    def self.refuse(source, reason)
      raise ConfigurationError, "langsys: #{source} #{reason}"
    end

    # The canonical serialisation: members in code point order, no whitespace, a map always an
    # object, and strings escaped as CID-1 serialises them (quote, backslash and C0 only).
    def self.canonical(value)
      case value
      when Hash
        members = value.keys.map(&:to_s).sort_by(&:codepoints).map do |k|
          "#{string(k)}:#{canonical(value.fetch(k) do
            value[k.to_sym]
          end)}"
        end
        "{#{members.join(',')}}"
      when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
      when String then string(value)
      when nil then "null"
      else JSON.generate(value)
      end
    end

    def self.string(text)
      escaped = text.gsub(/["\\\u0000-\u001f]/) { |c| ESCAPES.fetch(c) { format("\\u%04x", c.ord) } }
      "\"#{escaped}\""
    end

    def initialize(project_id:, generated_at:, base_locale:, locales:, categories:, catalog:)
      @project_id = project_id
      @generated_at = generated_at
      @base_locale = base_locale
      @locales = Array(locales).sort_by(&:codepoints)
      @categories = Array(categories).sort_by(&:codepoints)
      @catalog = catalog
    end

    def catalog(locale = nil) = locale.nil? ? @catalog : @catalog[Locale.normalize_locale(locale)]

    def checksum
      "sha256:#{Digest::SHA256.hexdigest(self.class.canonical(hashed))}"
    end

    def to_h
      { "format" => FORMAT, "version" => VERSION }.merge(hashed).merge("checksum" => checksum)
    end

    def write(path)
      File.write(path, "#{JSON.pretty_generate(to_h)}\n")
      path
    end

    private

    def hashed
      { "project_id" => @project_id, "generated_at" => @generated_at, "base_locale" => @base_locale,
        "locales" => @locales, "categories" => @categories, "catalog" => @catalog }
    end
  end
end
