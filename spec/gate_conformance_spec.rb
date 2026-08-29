# frozen_string_literal: true

require "spec_helper"

# Conformance specs for the write-gating family (GATE-1..GATE-8).
RSpec.describe "GATE conformance" do
  describe "GATE-1 — branch on server-computed write_enabled, never on key type" do
    it "registers on an ip_write key the server has write-enabled" do
      # The renderer runs a customer's page through their unmodified SDK on an ip_write
      # key. A key_type test defeats discovery outright, which is the failure this rule
      # exists to prevent.
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: true)
      expect(client.can_write?).to be(true)
    end

    it "refuses on an ip_write key the server has NOT write-enabled" do
      # Same key, different address: the server legitimately answers false.
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: false)
      expect(client.can_write?).to be(false)
    end

    it "refuses a write-typed key the server has disabled — the flag wins over key_type" do
      client = build_client
      stub_authorize(key_type: "write", write_enabled: false)
      expect(client.can_write?).to be(false)
    end

    it "allows a read-typed key the server has write-enabled — the flag wins in both directions" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: true)
      expect(client.can_write?).to be(true)
    end

    it "reports the server's key_type verbatim rather than collapsing it to read" do
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: true)
      expect(client.key_type).to eq("ip_write")
    end

    it "reads the flag from the translations envelope, not only from authorize" do
      client = build_client
      stub_authorize(key_type: "read")
      stub_request(:get, "https://api.test/api/translations")
        .with(query: hash_including({ "project_id" => "proj-1" }))
        .to_return(status: 200,
                   body: JSON.generate(catalog_body({}).merge("write_enabled" => true)),
                   headers: { "Content-Type" => "application/json" })
      client.t("Save", category: "UI")
      expect(client.can_write?).to be(true)
    end
  end

  describe "GATE-3/GATE-4 — never persist the decision; strip it before caching" do
    it "does not write write_enabled into the cache" do
      cache = Langsys::Cache::Memory.new
      client = build_client(cache: cache)
      stub_authorize(key_type: "ip_write", write_enabled: true)
      client.project
      stored = cache.get("auth_proj-1")
      expect(stored).to be_a(Hash)
      expect(stored).not_to have_key("write_enabled")
    end

    it "keeps caching the rest of the authorize payload (positive control)" do
      # Without this, the assertion above could pass by caching nothing at all.
      cache = Langsys::Cache::Memory.new
      client = build_client(cache: cache)
      stub_authorize(key_type: "ip_write", write_enabled: true)
      client.project
      expect(cache.get("auth_proj-1")).to include("id" => "proj-1", "key_type" => "ip_write")
    end

    it "does not let a cached decision answer for a later session" do
      # A cache warmed by an allow-listed request must not write-enable a fresh client
      # that has had no positive signal of its own.
      cache = Langsys::Cache::Memory.new
      first = build_client(cache: cache)
      stub_authorize(key_type: "ip_write", write_enabled: true)
      first.project
      expect(first.can_write?).to be(true)

      # Second client, same shared cache, server now says false for this address.
      stub_authorize(key_type: "ip_write", write_enabled: false)
      expect(build_client(cache: cache).can_write?).to be(false)
    end
  end

  describe "GATE-8 — a missing write_enabled is a version signal, never permission" do
    it "falls back to key_type for a plain write key when the field is absent" do
      client = build_client
      stub_authorize(key_type: "write", write_enabled: :omit)
      expect(client.can_write?).to be(true)
    end

    it "refuses a read key when the field is absent" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: :omit)
      expect(client.can_write?).to be(false)
    end

    it "NEVER infers a write decision for ip_write when the field is absent" do
      # Constraint 1: for an address-dependent key the absence of a positive signal is
      # the answer. Inferring around it converts a closed gate into an open one.
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: :omit)
      expect(client.can_write?).to be(false)
    end

    it "re-evaluates per response rather than latching the decision at init" do
      # A server upgraded mid-deployment must be picked up without an SDK release.
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: false)
      expect(client.can_write?).to be(false)

      stub_authorize(key_type: "ip_write", write_enabled: true)
      expect(client.can_write?(refresh: true)).to be(true)
    end
  end

  describe "GATE-3 — the decision never latches; the freshest response wins" do
    # Both shadow directions. A stale slot outranking a fresh one fails in whichever
    # direction the stale value happened to hold, and one of those directions reports a
    # closed gate as open.
    it "does not let a latched catalog `true` outrank a fresh authorize `false`" do
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: true)
      stub_request(:get, "https://api.test/api/translations")
        .with(query: hash_including({ "project_id" => "proj-1" }))
        .to_return(status: 200,
                   body: JSON.generate(catalog_body({}).merge("write_enabled" => true)),
                   headers: { "Content-Type" => "application/json" })
      client.t("Save", category: "UI")
      expect(client.can_write?).to be(true)

      # Server now refuses this address. The catalog slot still holds the old `true`.
      stub_authorize(key_type: "ip_write", write_enabled: false)
      expect(client.can_write?(refresh: true)).to be(false)
    end

    it "does not let a latched catalog `false` outrank a fresh authorize `true`" do
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: false)
      stub_request(:get, "https://api.test/api/translations")
        .with(query: hash_including({ "project_id" => "proj-1" }))
        .to_return(status: 200,
                   body: JSON.generate(catalog_body({}).merge("write_enabled" => false)),
                   headers: { "Content-Type" => "application/json" })
      client.t("Save", category: "UI")
      expect(client.can_write?).to be(false)

      stub_authorize(key_type: "ip_write", write_enabled: true)
      expect(client.can_write?(refresh: true)).to be(true)
    end

    it "drops the decision at an explicit request boundary" do
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: true)
      client.project
      expect(client.write_signal).to be(true)
      client.reset_write_decision!
      expect(client.write_signal).to be_nil
    end
  end

  describe "GATE-1 — the gate actually governs registration, not just the predicate" do
    it "does not POST when the server says write_enabled is false" do
      client = build_client
      stub_authorize(key_type: "write", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true }),
                        headers: { "Content-Type" => "application/json" })
      client.t("Save", category: "UI")
      client.flush_pending
      expect(post).not_to have_been_requested
    end

    it "does POST when the server says write_enabled is true on an ip_write key" do
      client = build_client
      stub_authorize(key_type: "ip_write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true }),
                        headers: { "Content-Type" => "application/json" })
      client.t("Save", category: "UI")
      client.flush_pending
      expect(post).to have_been_requested
    end
  end
end
