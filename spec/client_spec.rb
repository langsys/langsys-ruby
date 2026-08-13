# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Client do
  def stub_translations(locale, data)
    stub_request(:get, "https://api.test/api/translations")
      .with(query: { "project_id" => "proj-1", "locale" => locale, "format" => "flat" })
      .to_return(status: 200, body: JSON.generate(catalog_body(data)),
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_authorize(key_type: "read")
    stub_request(:get, "https://api.test/api/authorize-project/proj-1")
      .to_return(status: 200, body: JSON.generate(authorize_body(key_type: key_type)),
                 headers: { "Content-Type" => "application/json" })
  end

  describe "#translate" do
    it "returns a translation and interpolates params" do
      stub_translations("es-ES", { "Greetings" => { "Hello, {name}!" => "Hola, {name}!" } })
      client = build_client
      client.set_locale("es-ES")
      expect(client.t("Hello, {name}!", category: "Greetings", params: { name: "Sarah" }))
        .to eq("Hola, {name}!".sub("{name}", "Sarah"))
    end

    it "falls back to the source phrase and queues a missing phrase" do
      stub_translations("en-US", { "UI" => {} })
      client = build_client
      expect(client.t("Save", category: "UI")).to eq("Save")
      expect(client.has_pending?).to be true
      expect(client.pending_phrases).to eq([{ "phrase" => "Save", "category" => "UI" }])
    end

    it "does not re-queue a present-but-null phrase" do
      stub_translations("en-US", { "UI" => { "Save" => nil } })
      client = build_client
      expect(client.t("Save", category: "UI")).to eq("Save")
      expect(client.has_pending?).to be false
    end
  end

  describe "#flush_pending" do
    it "drops the queue on a read key without writing" do
      stub_translations("en-US", { "UI" => {} })
      stub_authorize(key_type: "read")
      client = build_client
      client.t("Save", category: "UI")
      result = client.flush_pending
      expect(result["skipped"]).to be true
      expect(client.has_pending?).to be false
      expect(a_request(:post, "https://api.test/api/translatable-items")).not_to have_been_made
    end

    it "registers queued phrases on a write key" do
      stub_translations("en-US", { "UI" => {} })
      stub_authorize(key_type: "write")
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true, "data" => [] }),
                        headers: { "Content-Type" => "application/json" })
      client = build_client
      client.t("Save", category: "UI")
      result = client.flush_pending
      expect(result["phrases"]).to eq(1)
      expect(post).to have_been_made
    end
  end

  describe "#register_phrases" do
    it "requires a write key" do
      stub_authorize(key_type: "read")
      expect { build_client.register_phrases(["Save"]) }.to raise_error(Langsys::AuthorizationError)
    end

    it "posts items on a write key" do
      stub_authorize(key_type: "write")
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true, "data" => [] }),
                        headers: { "Content-Type" => "application/json" })
      build_client.register_phrases([{ phrase: "Save", category: "UI" }])
      expect(post).to have_been_made
    end
  end

  describe "authorization errors" do
    it "maps a 403 to AuthorizationError" do
      stub_request(:get, "https://api.test/api/authorize-project/proj-1")
        .to_return(status: 403, body: JSON.generate({ "status" => false, "error" => "forbidden" }))
      expect { build_client.authorize }.to raise_error(Langsys::AuthorizationError, /forbidden/)
    end

    it "maps a 429 to RateLimitError" do
      stub_request(:get, "https://api.test/api/authorize-project/proj-1")
        .to_return(status: 429, body: JSON.generate({ "status" => false, "error" => "slow down" }))
      expect { build_client.authorize }.to raise_error(Langsys::RateLimitError)
    end
  end

  describe "external locale source" do
    it "falls back to base_locale when the source is empty, without calling authorize" do
      stub_translations("en-US", { "UI" => { "Save" => "Saved" } })
      client = build_client(locale_source: Langsys::Signal.new(""))
      expect(client.t("Save", category: "UI")).to eq("Saved")
      expect(a_request(:get, "https://api.test/api/authorize-project/proj-1")).not_to have_been_made
    end
  end

  describe "config" do
    it "raises when credentials are missing" do
      expect { Langsys::Client.new(api_key: "", project_id: "") }
        .to raise_error(Langsys::ConfigurationError, /missing/i)
    end
  end
end
