# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

module InterpolationFixture
  BLOB = "017bffdd1d83a1b0a00a91f0d157a7fff726ee90"
  PATH = File.expand_path("fixtures/interpolation-reference.json", __dir__)
  ROWS = JSON.parse(File.read(PATH))
  ICU6 = "You have {count, plural, one {{count} car} other {{count} cars}}"
end

RSpec.describe "spec 8.2.x interpolation and ICU-6" do
  describe "the shared interpolation fixture (langsys-php-sdk, 25 rows)" do
    it "is the exact blob it was vendored at" do
      expect(`git hash-object #{Shellwords.escape(InterpolationFixture::PATH)}`.strip).to eq(InterpolationFixture::BLOB)
    end

    InterpolationFixture::ROWS.each do |row|
      it "renders #{row['description'][0, 70]}" do
        expect(Langsys::Interpolate.call(row["template"], row["params"], row["locale"])).to eq(row["expected"])
      end

      it "renders it through t() as a catalog translation: #{row['description'][0, 50]}" do
        locale = Langsys::Locale.normalize_locale(row["locale"])
        stub_authorize
        stub_translations(locale, { "UI" => { "Source" => row["template"] } })
        client = build_client(base_locale: row["locale"])
        params = row["params"]&.transform_keys(&:to_sym)
        expect(client.t("Source", category: "UI", params: params)).to eq(row["expected"])
      end
    end
  end

  describe "ICU-6 — a formatter failure renders through the SDK's own branch selection, and warns" do
    let(:log) { StringIO.new }
    let(:logger) { Logger.new(log).tap { |l| l.level = Logger::WARN } }

    before do
      Langsys::Interpolate::FAILURE_NOTICES_SEEN.clear
      allow_any_instance_of(Langsys::Interpolate::Parser).to receive(:parse).and_raise(ArgumentError,
                                                                                       "formatter exploded")
    end

    it "renders the vector's other branch with the value filled" do
      expect(Langsys::Interpolate.call(InterpolationFixture::ICU6, { count: 3 }, "en", logger: logger))
        .to eq("You have 3 cars")
    end

    it "renders the one branch for count 1" do
      expect(Langsys::Interpolate.call(InterpolationFixture::ICU6, { count: 1 }, "en")).to eq("You have 1 car")
    end

    it "prefers an exact =N branch, then the CLDR category, in the render locale" do
      tpl = "{n, plural, =0 {none} one {# plik} few {# pliki} many {# plikow} other {# pliku}}"
      expect(Langsys::Interpolate.call(tpl, { n: 0 }, "pl")).to eq("none")
      expect(Langsys::Interpolate.call(tpl, { n: 3 }, "pl")).to eq("3 pliki")
      expect(Langsys::Interpolate.call(tpl, { n: 5 }, "pl")).to eq("5 plikow")
    end

    it "selects a select branch and recurses into it" do
      tpl = "{g, select, female {{n, plural, one {# amiga} other {# amigas}}} other {x}}"
      expect(Langsys::Interpolate.call(tpl, { g: "female", n: 2 }, "es")).to eq("2 amigas")
    end

    it "keeps an unsupplied argument as its visible name, never blank and never the raw construct" do
      out = Langsys::Interpolate.call(InterpolationFixture::ICU6, {}, "en")
      expect(out).to eq("You have {count} cars")
    end

    it "warns with debug logging off, naming the phrase, the locale and the error, once per (template, locale)" do
      3.times { Langsys::Interpolate.call(InterpolationFixture::ICU6, { count: 3 }, "en", logger: logger) }
      Langsys::Interpolate.call(InterpolationFixture::ICU6, { count: 3 }, "fr", logger: logger)
      lines = log.string.lines.grep(/formatter/)
      expect(lines.size).to eq(2)
      expect(lines.first).to include(InterpolationFixture::ICU6).and include("en").and include("formatter exploded")
    end
  end

  it "ICU-6: this SDK's formatter renders the shared vector natively (no failure)" do
    [[3, "You have 3 cars"], [1, "You have 1 car"]].each do |count, want|
      expect(Langsys::Interpolate.call(InterpolationFixture::ICU6, { count: count }, "en")).to eq(want)
    end
  end
end
