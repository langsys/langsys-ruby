# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "digest"
require_relative "support/contract_fixture"

# SNAP-1/SNAP-3 at langsys2 9b23f3d8 (spec 8.2.14): one snapshot format every SDK writes and reads,
# `langsys-catalog-snapshot` v1, with a checksum over a canonical serialisation every core computes
# byte for byte. snapshot-vectors.json is not authored yet; these cases are the ones its rows list.
module SnapshotCases
  module_function

  def ch(codepoint) = [codepoint].pack("U")

  def doc(catalog, locales: ["es-es"], categories: ["UI"])
    Langsys::Snapshot.new(project_id: "proj-1", generated_at: "2026-09-24T12:00:00Z", base_locale: "en-us",
                          locales: locales, categories: categories, catalog: catalog)
  end
end

RSpec.describe "spec 8.2.14 snapshots (SNAP)" do
  describe "the canonical serialisation" do
    def canon(value) = Langsys::Snapshot.canonical(value)

    it "writes an empty map as {} and a list as an array, with no whitespace" do
      expect(canon({ "a" => {}, "b" => [], "c" => nil })).to eq('{"a":{},"b":[],"c":null}')
    end

    it "orders members by code point, an integer-like key included" do
      expect(canon({ "b" => nil, "404" => nil, "a" => nil,
                     "B" => nil })).to eq('{"404":null,"B":null,"a":null,"b":null}')
    end

    it "orders a key above U+FFFF after one in U+E000-U+FFFF, by code point" do
      astral = SnapshotCases.ch(0x1F600)
      private_use = SnapshotCases.ch(0xE000)
      expect(canon({ astral => nil, private_use => nil })).to eq("{\"#{private_use}\":null,\"#{astral}\":null}")
    end

    it "escapes only the quote, the backslash and C0 controls, the way CID-1 does" do
      value = "q\" b\\ #{SnapshotCases.ch(0x08)}#{SnapshotCases.ch(0x09)}#{SnapshotCases.ch(0x0A)}" \
              "#{SnapshotCases.ch(0x0C)}#{SnapshotCases.ch(0x0D)}#{SnapshotCases.ch(0x01)}#{SnapshotCases.ch(0x1F)}"
      expect(canon(value)).to eq('"q\\" b\\\\ \\b\\t\\n\\f\\r\\u0001\\u001f"')
    end

    it "keeps /, non-ASCII and U+2028/U+2029 raw" do
      value = "a/b é #{SnapshotCases.ch(0x2028)}#{SnapshotCases.ch(0x2029)}"
      expect(canon(value)).to eq("\"#{value}\"")
    end
  end

  describe "the document" do
    let(:catalog) do
      { "es-es" => { "UI" => { "Save" => "Guardar", "abc" => { "Hi" => nil } }, "Empty" => {} },
        "fr-fr" => { "UI" => { "Save" => "Enregistrer" } } }
    end
    let(:snapshot) do
      SnapshotCases.doc(catalog, locales: %w[fr-fr es-es], categories: %w[UI Empty])
    end

    it "carries the members, sorted lists, and a sha256: checksum over everything but format, version and checksum" do
      doc = snapshot.to_h
      expect(doc.keys).to contain_exactly("format", "version", "project_id", "generated_at", "base_locale", "locales",
                                          "categories", "catalog", "checksum")
      expect([doc["format"], doc["version"], doc["locales"], doc["categories"]])
        .to eq(["langsys-catalog-snapshot", 1, %w[es-es fr-fr], %w[Empty UI]])
      hashed = doc.except("format", "version", "checksum")
      expect(doc["checksum"]).to eq("sha256:#{Digest::SHA256.hexdigest(Langsys::Snapshot.canonical(hashed))}")
    end

    it "round-trips through any JSON encoding of the file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        File.write(path, JSON.pretty_generate(snapshot.to_h))
        loaded = Langsys::Snapshot.load(path)
        expect(loaded.catalog("es-es")).to eq(catalog["es-es"])
        expect(loaded.catalog("fr-fr")).not_to have_key("Empty")
      end
    end

    def refused(doc)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        File.write(path, JSON.generate(doc))
        expect { Langsys::Snapshot.load(path) }.to raise_error(Langsys::ConfigurationError) { |e| return e.message }
      end
    end

    it "refuses an edited file, by name" do
      doc = snapshot.to_h
      doc["catalog"]["es-es"]["UI"]["Save"] = "Salvar"
      expect(refused(doc)).to match(/checksum/)
    end

    it "refuses a different format, an unsupported version and a missing member, each by name" do
      expect(refused(snapshot.to_h.merge("format" => "langsys-snapshot"))).to match(/format/)
      expect(refused(snapshot.to_h.merge("version" => 2))).to match(/version/)
      expect(refused(snapshot.to_h.tap { |d| d.delete("base_locale") })).to match(/base_locale/)
    end
  end

  describe "SNAP-1 — export filters GET /translations client-side", contract: true do
    before do
      contract.seed(
        "projects" => [{ "id" => "proj-c", "base_locale" => "en-us", "target_locales" => %w[es-es fr-fr],
                         "phrases" => [
                           { "category" => "UI", "phrase" => "Save",
                             "translations" => { "es-es" => "Guardar", "fr-fr" => "Enregistrer" } },
                           { "category" => "Errors", "phrase" => "Required",
                             "translations" => { "es-es" => "Obligatorio" } },
                           { "category" => "Marketing", "phrase" => "Buy now",
                             "translations" => { "es-es" => "Compra" } }
                         ],
                         "blocks" => [{ "category" => "UI", "custom_id" => "abc",
                                        "phrases" => [{ "phrase" => "Hi" }] }] }],
        "keys" => [{ "key" => "r", "project" => "proj-c", "type" => "read" }]
      )
    end

    it "carries exactly what GET /translations serves for the chosen categories and locales" do
      snapshot = Langsys::Snapshot.export(contract_client(key: "r"), locales: %w[fr-FR es-ES],
                                                                     categories: %w[UI Errors])
      http = Langsys::Http.new(contract.base_url, "r")
      %w[es-es fr-fr].each do |locale|
        served = http.get("translations", { "project_id" => "proj-c", "locale" => locale, "format" => "flat" })["data"]
        expect(snapshot.catalog(locale)).to eq(served.slice("UI", "Errors"))
      end
      expect([snapshot.locales, snapshot.categories,
              snapshot.base_locale]).to eq([%w[es-es fr-fr], %w[Errors UI], "en-us"])
      expect(snapshot.catalog("es-es")["UI"]["abc"]).to eq({ "Hi" => nil })
      expect(snapshot.generated_at).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
    end

    it "writes, through langsys-snapshot, a file the loader accepts" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "snap.json")
        env = { "LANGSYS_API_KEY" => "r", "LANGSYS_PROJECT_ID" => "proj-c", "LANGSYS_API_URL" => contract.base_url }
        exe = File.expand_path("../exe/langsys-snapshot", __dir__)
        _, status = Open3.capture2e(env, "ruby", "-I", File.expand_path("../lib", __dir__), exe,
                                    "--locale", "es-es", "--category", "UI", "--out", out)
        expect(status.exitstatus).to eq(0)
        expect(Langsys::Snapshot.load(out).catalog("es-es").keys).to eq(["UI"])
      end
    end
  end

  describe "Client.new(snapshot:) — the preloaded catalog a binding seeds (SNAP-2 via the core loader)" do
    let(:path) do
      dir = Dir.mktmpdir
      snap = SnapshotCases.doc({ "es-es" => { "UI" => { "Save" => "Guardar", "Pending" => nil } } }, locales: ["es-es"])
      snap.write(File.join(dir, "snapshot.json"))
    end

    def seeded_client = build_client(base_locale: "es-ES", snapshot: path)

    it "renders a phrase the snapshot holds with no network call, and queues nothing" do
      sdk = seeded_client
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
      expect(sdk.has_pending?).to be(false)
      expect(a_request(:any, /api\.test/)).not_to have_been_made
    end

    it "falls through to the live catalog for a phrase the snapshot lacks, which then wins" do
      stub_translations("es-es", { "UI" => { "Save" => "Guardar ahora", "Open" => "Abrir" } })
      sdk = seeded_client
      expect(sdk.t("Open", category: "UI")).to eq("Abrir")
      expect(sdk.t("Save", category: "UI")).to eq("Guardar ahora")
    end

    it "shows source for a phrase the snapshot lacks when the live fetch fails, and records nothing" do
      stub_request(:get, %r{/api/translations}).to_return(status: 500, body: "")
      sdk = seeded_client
      expect(sdk.t("Open", category: "UI")).to eq("Open")
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
      expect(sdk.has_pending?).to be(false)
    end

    it "decides a miss only against the live catalog, never against the snapshot" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("es-es", { "UI" => { "Open" => "Abrir" } })
      sdk = seeded_client
      sdk.t("Brand new", category: "UI")
      expect(sdk.pending_phrases.map { |p| p["phrase"] }).to eq(["Brand new"])
      sdk.t("Pending", category: "UI")
      expect(sdk.pending_phrases.map { |p| p["phrase"] }).to eq(["Brand new", "Pending"])
    end

    describe "when authorization is unavailable, the snapshot names the locales it can serve" do
      before { stub_request(:get, %r{/api/authorize-project}).to_return(status: 500, body: "") }

      it "resolves a request locale the snapshot carries (SRV-6)" do
        expect(seeded_client.resolve_request_locale(url: "es-ES")).to eq(locale: "es-es", source: :url, vary: [])
      end

      it "still refuses a locale the snapshot does not carry" do
        expect(seeded_client.resolve_request_locale(url: "fr-FR")).to eq(locale: "en-us", source: nil, vary: [])
      end

      it "gives the resolved-root decision the snapshot's base locale (GATE-10)" do
        expect(seeded_client.resolved_locale("es-ES")).to eq("es-es")
        expect(seeded_client.resolved_locale("en-US")).to be_nil
      end
    end

    it "prefers authorization whenever it answers (control)" do
      stub_request(:get, %r{/api/authorize-project})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(authorize_body.tap do |b|
                     b["data"]["base_locale"] = "en-us"
                     b["data"]["target_locales"] = ["fr-fr"]
                   end))
      sdk = seeded_client
      expect(sdk.resolve_request_locale(url: "fr-FR")[:locale]).to eq("fr-fr")
      expect(sdk.resolve_request_locale(url: "es-ES")[:source]).to be_nil
    end

    it "refuses a bad snapshot when the client is built" do
      File.write(path, File.read(path).sub("Guardar", "Salvar"))
      expect { seeded_client }.to raise_error(Langsys::ConfigurationError, /checksum/)
    end
  end
end
