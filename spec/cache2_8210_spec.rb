# frozen_string_literal: true

require "spec_helper"
require_relative "support/contract_fixture"

# CACHE-2: a failed catalog fetch is remembered, per project and locale, for a window that
# starts at 3s, doubles on each consecutive failure to 300s, and resets on success.
RSpec.describe "spec 8.2.x CACHE-2 failed-fetch window" do
  let(:now) { [1000.0] }
  let(:clock) { -> { now[0] } }

  describe "against the contract fixture", contract: true do
    def seed(faults: [])
      contract.seed(
        "projects" => [{ "id" => "proj-c", "base_locale" => "en-us", "target_locales" => ["es-es"],
                         "phrases" => [{ "category" => "UI", "phrase" => "Save",
                                         "translations" => { "es-es" => "Guardar" } }] }],
        "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" }],
        "faults" => faults
      )
    end

    def client = contract_client(key: "w", base_locale: "es-ES", clock: clock)

    let(:one_failure) { [{ "method" => "GET", "path" => "/translations", "times" => 1, "status" => 500 }] }

    it "renders the translation at once when the first fetch succeeds (control)" do
      seed
      expect(client.t("Save", category: "UI")).to eq("Guardar")
    end

    it "degrades to source, stays on source inside the window, and translates after it" do
      seed(faults: one_failure)
      sdk = client
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      now[0] += 2.9
      # A fetch here would have answered the catalog; source proves none was made.
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      now[0] += 0.2
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
    end

    it "doubles the window on a consecutive failure" do
      seed(faults: [{ "method" => "GET", "path" => "/translations", "times" => 2, "status" => 503 }])
      sdk = client
      sdk.t("Save", category: "UI")
      now[0] += 3.1
      expect(sdk.t("Save", category: "UI")).to eq("Save") # second failure: window now 6s
      now[0] += 5.9
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      now[0] += 0.2
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
    end

    it "resets to the base window after a success" do
      seed(faults: [{ "method" => "GET", "path" => "/translations", "times" => 1, "status" => 500 }])
      sdk = client
      sdk.t("Save", category: "UI")
      now[0] += 3.1
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
      seed(faults: one_failure)
      sdk.clear_cache
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      now[0] += 3.1
      expect(sdk.t("Save", category: "UI")).to eq("Guardar")
    end

    it "queues nothing and raises nothing inside the window (WIRE-4)" do
      seed(faults: one_failure)
      sdk = client
      expect { 3.times { sdk.t("Never seen", category: "UI") } }.not_to raise_error
      expect(sdk.has_pending?).to be(false)
    end

    it "keeps each locale's window its own" do
      seed(faults: one_failure)
      sdk = client
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      expect(sdk.t("Save", category: "UI", locale: "en-US")).to eq("Save")
      expect(sdk.t("Save", category: "UI", locale: "es-ES")).to eq("Save")
    end
  end

  describe "at the transport seam" do
    it "treats a 200 answering status:false as a failure, and does not fetch again inside the window" do
      stub_authorize
      body = JSON.generate(catalog_body({ "UI" => { "Save" => "Guardar" } }).merge("status" => false))
      get = stub_request(:get, %r{/api/translations})
            .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
      sdk = build_client(base_locale: "es-ES", clock: clock)
      expect(Array.new(2) { sdk.t("Save", category: "UI") }).to eq(%w[Save Save])
      expect(get).to have_been_requested.once
    end

    it "shares one request between concurrent lookups for the same locale" do
      stub_authorize
      get = stub_request(:get, %r{/api/translations}).to_return do
        sleep 0.2
        { status: 200, body: JSON.generate(catalog_body({ "UI" => { "Save" => "Guardar" } })),
          headers: { "Content-Type" => "application/json" } }
      end
      sdk = build_client(base_locale: "es-ES", clock: clock)
      results = Array.new(4) { Thread.new { sdk.t("Save", category: "UI") } }.map(&:value)
      expect(results).to all(eq("Guardar"))
      expect(get).to have_been_requested.once
    end

    it "never writes the failure to the shared cache backend" do
      stub_authorize
      stub_request(:get, %r{/api/translations}).to_return(status: 500, body: "")
      shared = Langsys::Cache::Memory.new
      build_client(base_locale: "es-ES", cache: shared, clock: clock).t("Save", category: "UI")
      expect(shared.instance_variable_get(:@store).keys.grep(/translations/)).to be_empty
    end
  end
end
