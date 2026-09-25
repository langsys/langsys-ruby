# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "tmpdir"

# The shared legacy-key migration vectors (langsys-js-typescript, blob 20f2bdd6), rowed over
# Ruby's format set from core_formats. A row in another core's format is n/a (format); a file row
# in one is refused at load. A `calls` row whose entry point is outside core_entry_points (Ruby's
# are t and I18n.t) is n/a (entry point).
module MigVectors
  BLOB = "20f2bdd678cb33981e3064e42d43ca62783920ad"
  PATH = File.expand_path("fixtures/mig-vectors.json", __dir__)
  DATA = JSON.parse(File.read(PATH))
  MINE = DATA["core_formats"]["ruby"]
  ENTRY_POINTS = { "t" => :langsys, "I18n.t" => :rails }.freeze
  MY_ENTRY_POINTS = DATA["core_entry_points"]["ruby"]
end

RSpec.describe "spec MIG shared vectors (mig-vectors.json)" do
  it "is the exact blob it was vendored at, and names Ruby's set as rails-i18n, gettext and plain" do
    expect(`git hash-object #{Shellwords.escape(MigVectors::PATH)}`.strip).to eq(MigVectors::BLOB)
    expect(MigVectors::MINE).to eq(%w[rails-i18n gettext plain])
    expect(MigVectors::MY_ENTRY_POINTS).to eq(MigVectors::ENTRY_POINTS.keys)
  end

  MigVectors::DATA["value_conversion"].select { |r| MigVectors::MINE.include?(r["format"]) }.each do |row|
    it "value_conversion: #{row['id']}" do
      got = Langsys::Migration.convert(row["value"], format: row["format"])
      expect([got.phrase, got.warning.nil?]).to eq([row["expected"], row["recognised"]])
    end
  end

  MigVectors::DATA["plural_forms"].select { |r| MigVectors::MINE.include?(r["format"]) }.each do |row|
    it "plural_forms: #{row['id']}" do
      forms = row["forms"]
      got = if row["format"] == "gettext"
              Langsys::Migration.gettext_plural(forms["msgid"], forms["msgid_plural"])
            else
              Langsys::Migration.rails_plural(forms)
            end
      expect(got).to eq(row["expected"])
    end
  end

  calls = MigVectors::DATA["calls"].to_h { |r| [r["id"], r] }
  calls.each_value.select { |r| MigVectors::MY_ENTRY_POINTS.include?(r["entry_point"]) }.each do |row|
    it "calls: #{row['id']}" do
      convert = lambda do |r|
        Langsys::Migration.convert_literal(r["text"], entry_point: MigVectors::ENTRY_POINTS.fetch(r["entry_point"]),
                                                      params: r["params"])
      end
      expect(convert.call(row)).to eq(row["expected"])
      expect(convert.call(row)).to eq(convert.call(calls.fetch(row["same_phrase_as"]))) if row["same_phrase_as"]
    end
  end

  MigVectors::DATA["resolution"].each do |row|
    it "resolution: #{row['id']}" do
      Dir.mktmpdir do |dir|
        specs = row["files"].map do |f|
          path = File.join(dir, f["name"])
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.generate(f["data"]))
          { path: path, format: f["format"], namespace: f["namespace"] }.compact
        end
        if row["files"].any? { |f| f["format"] && !MigVectors::MINE.include?(f["format"]) }
          expect do
            Langsys::Migration.new(specs)
          end.to raise_error(Langsys::ConfigurationError, /#{row['files'][0]['format']}/)
          next
        end
        log = StringIO.new
        hit = Langsys::Migration.new(specs, logger: Logger.new(log)).lookup(row["key"])
        want = row["expected"]
        if want.nil?
          expect(hit).to be_nil
        else
          expect([hit.phrase, row["category_arg"] || hit.category, hit.file.delete_prefix("#{dir}/")])
            .to eq([want["phrase"], want["category"], want["file"]])
          expect(log.string.match?(/WARN/)).to eq(!want["recognised"])
        end
      end
    end
  end

  MigVectors::DATA["refusals"].each do |row|
    it "refusals: #{row['id']}" do
      file = row["file"]
      spec = file["format"] ? { path: file["name"], format: file["format"] } : file["name"]
      if row["supported_by"].include?("ruby")
        expect { Langsys::Migration.new([spec]) }.not_to raise_error
      else
        expect { Langsys::Migration.new([spec]) }
          .to raise_error(Langsys::ConfigurationError, /#{Regexp.escape(File.basename(row['hint'] || file['name']))}/)
      end
    end
  end
end
