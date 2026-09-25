# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require_relative "support/contract_fixture"

RSpec.describe "spec 8.2.x snapshots (SNAP)" do
  describe "SNAP-1 — export filters the catalog client-side", contract: true do
    before do
      contract.seed(
        "projects" => [{ "id" => "proj-c", "target_locales" => %w[es-es fr-fr],
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

    let(:client) { contract_client(key: "r") }

    it "carries exactly what the API returns for the chosen categories and locales" do
      snapshot = Langsys::Snapshot.export(client, locales: %w[es-es fr-fr], categories: %w[UI Errors])
      http = Langsys::Http.new(contract.base_url, "r")
      %w[es-es fr-fr].each do |locale|
        served = http.get("translations/data", { "project_id" => "proj-c", "locale" => locale })["data"]
        expect(snapshot.catalog(locale)).to eq(served.slice("UI", "Errors"))
      end
      expect(snapshot.catalog("es-es")["UI"]["abc"]).to eq({ "Hi" => nil })
      expect(snapshot.catalog("es-es")).not_to have_key("Marketing")
    end

    it "writes a file the langsys-snapshot executable produces the same way" do
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

  describe "SNAP-3 — a snapshot is a cache, never the source of truth" do
    let(:snapshot) { Langsys::Snapshot.build("proj-1", { "es-es" => { "UI" => { "Save" => "Guardar" } } }) }

    it "round-trips through its file form" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        snapshot.write(path)
        expect(Langsys::Snapshot.load(path).catalog("es-es")).to eq({ "UI" => { "Save" => "Guardar" } })
      end
    end

    it "refuses a hand-edited snapshot and says to export it again" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        snapshot.write(path)
        File.write(path, File.read(path).sub("Guardar", "Salvar"))
        expect { Langsys::Snapshot.load(path) }.to raise_error(Langsys::ConfigurationError, /export it again/)
      end
    end

    it "refuses a document that is not a snapshot" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        File.write(path, '{"UI":{"Save":"Guardar"}}')
        expect { Langsys::Snapshot.load(path) }.to raise_error(Langsys::ConfigurationError, /not a Langsys snapshot/)
      end
    end
  end
end
