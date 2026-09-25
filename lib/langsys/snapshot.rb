# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "errors"
require_relative "locale"

module Langsys
  # A catalog snapshot (spec SNAP family): what Langsys serves, filtered client-side by category
  # from GET /translations/data, for setups that should not call the API on the render path.
  #
  # A snapshot is a cache, never the source of truth. It carries a checksum of its contents, and
  # loading refuses one that no longer matches: a hand-edited snapshot is caught rather than
  # served, and the refresh path is to export again.
  class Snapshot
    FORMAT = "langsys-snapshot"
    VERSION = 1

    attr_reader :project_id, :generated_at, :locales

    # SNAP-1: one GET /translations/data per locale, keeping only +categories+.
    def self.export(client, locales:, categories:)
      wanted = Array(categories).map(&:to_s)
      catalogs = Array(locales).to_h do |locale|
        loc = Locale.normalize_locale(locale)
        data = client.catalog_data(loc)
        [loc, data.is_a?(Hash) ? data.slice(*wanted) : {}]
      end
      build(client.project_id, catalogs)
    end

    def self.build(project_id, locales, generated_at: Time.now.utc.iso8601)
      new(project_id: project_id, locales: locales, generated_at: generated_at)
    end

    def self.load(path)
      doc = JSON.parse(File.read(path))
      unless doc.is_a?(Hash) && doc["format"] == FORMAT
        raise ConfigurationError, "langsys: #{path} is not a Langsys snapshot; produce one with langsys-snapshot"
      end
      unless doc["version"] == VERSION
        raise ConfigurationError,
              "langsys: #{path} has snapshot version #{doc['version'].inspect}"
      end

      snapshot = new(project_id: doc["project_id"], locales: doc["locales"], generated_at: doc["generated_at"])
      unless snapshot.checksum == doc["checksum"]
        raise ConfigurationError, "langsys: #{path} does not match its checksum, so it was edited by hand. " \
                                  "A snapshot is a cache of the catalog: export it again instead of editing it."
      end
      snapshot
    end

    def initialize(project_id:, locales:, generated_at:)
      @project_id = project_id
      @locales = locales
      @generated_at = generated_at
    end

    def catalog(locale) = @locales[Locale.normalize_locale(locale)]

    def checksum
      Digest::SHA256.hexdigest(JSON.generate([@project_id, @locales]))
    end

    def to_h
      { "format" => FORMAT, "version" => VERSION, "project_id" => @project_id, "generated_at" => @generated_at,
        "locales" => @locales, "checksum" => checksum }
    end

    def write(path)
      File.write(path, "#{JSON.pretty_generate(to_h)}\n")
      path
    end
  end
end
