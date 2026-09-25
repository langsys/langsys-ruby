# frozen_string_literal: true

require "spec_helper"
require_relative "support/contract_fixture"

RSpec.describe "spec 8.2.x read side" do
  describe "REG-13 — decide unregistered only against a catalog that has loaded" do
    it "keeps a catalogued phrase out of the candidate set when the first read settles late" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_request(:get, %r{/api/translations}).to_return do
        sleep 0.5 # past REG-2's 0.4s debounce
        { status: 200, body: JSON.generate(catalog_body({ "UI" => { "Save" => nil } })),
          headers: { "Content-Type" => "application/json" } }
      end
      client = build_client
      client.t("Save", category: "UI")
      expect(client.pending_phrases).to be_empty
    end

    it "queues nothing when the first read fails" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_request(:get, %r{/api/translations}).to_return(status: 500, body: "")
      client = build_client
      client.t("Save", category: "UI")
      expect(client.pending_phrases).to be_empty
    end

    it "queues a phrase the loaded catalog lacks (control)" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
      client = build_client
      client.t("Save", category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Save"])
    end
  end

  describe "against the contract fixture", contract: true do
    before do
      contract.seed("projects" => [{ "id" => "proj-c", "target_locales" => ["es-es"] },
                                   { "id" => "proj-d", "target_locales" => ["es-es"] }],
                    "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                               { "key" => "wd", "project" => "proj-d", "type" => "write" }])
    end

    it "WIRE-3/CAT-3: an uncategorised block reads back under __uncategorized__ and is not registered again" do
      first = contract_client(key: "w")
      first.translate_content_block("<p>Hello <b>world</b></p>")
      expect(first.flush_pending["success"]).to be(true)
      expect(contract.blocks("proj-c").map { |b| b["category"] }).to eq([nil])

      second = contract_client(key: "w")
      second.translate_content_block("<p>Hello <b>world</b></p>")
      expect(second.pending_content_blocks).to be_empty
    end

    it "REG-8: one project's failure clock is its own, and outlives the request on its client" do
      now = [0.0]
      clock = -> { now[0] }
      contract.seed("projects" => [{ "id" => "proj-c" }, { "id" => "proj-d" }],
                    "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                               { "key" => "wd", "project" => "proj-d", "type" => "write" }],
                    "faults" => [{ "method" => "POST", "path" => "/translatable-items", "times" => 1,
                                   "status" => 500 }])
      failing = contract_client(key: "w", clock: clock)
      other = contract_client(key: "wd", project: "proj-d", clock: clock)

      failing.request_scope { failing.t("First", category: "UI") }
      expect(failing.flush_pending["reason"]).to eq("send_failed")
      # A later request on the same long-lived client reads the same clock.
      failing.request_scope { failing.t("Second", category: "UI") }
      expect(failing.flush_pending["reason"]).to eq("backing_off")
      # Another project's sends are not silenced by it.
      other.t("Elsewhere", category: "UI")
      expect(other.flush_pending["success"]).to be(true)
      now[0] += 3.1
      expect(failing.flush_pending["success"]).to be(true)
      expect(contract.phrases("proj-c").keys).to contain_exactly(%w[UI First], %w[UI Second])
    end
  end
end
