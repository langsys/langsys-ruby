# frozen_string_literal: true

require "spec_helper"

# Conformance specs for the wire-boundary rules (WIRE-1..WIRE-5) and the write-storm
# clause WIRE-4 pairs with.
RSpec.describe "WIRE conformance" do
  # A transport that always fails, standing in for a DNS blip or a dead upstream.
  def dead_client(**overrides)
    build_client(**overrides).tap do
      stub_request(:any, /api\.test/).to_raise(Errno::ECONNREFUSED)
    end
  end

  describe "WIRE-4 — the translation call must never throw" do
    it "degrades t() to the source phrase instead of raising" do
      client = dead_client
      expect { client.t("Save", category: "UI") }.not_to raise_error
      expect(client.t("Save", category: "UI")).to eq("Save")
    end

    it "still interpolates params while degraded" do
      client = dead_client
      expect(client.t("Hello, {name}!", category: "UI", params: { name: "Sarah" }))
        .to eq("Hello, Sarah!")
    end

    it "degrades translate_content_block to the source HTML instead of raising" do
      client = dead_client
      html = "<p>Save</p>"
      expect { client.translate_content_block(html, category: "UI") }.not_to raise_error
      expect(client.translate_content_block(html, category: "UI")).to eq(html)
    end

    it "degrades translate_page to the source document instead of raising" do
      client = dead_client
      html = "<html><body><p>Save</p></body></html>"
      expect { client.translate_page(html, category: "UI") }.not_to raise_error
      expect(client.translate_page(html, category: "UI")).to include("Save")
    end

    it "logs the degradation loudly rather than failing silently" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      allow(logger).to receive(:debug)
      client = dead_client(logger: logger)
      client.t("Save", category: "UI")
      expect(logged.join).to match(/catalog|unavailable|degrad/i)
    end

    it "does not throw when the locale can only come from a failing authorize" do
      # effective_locale falls through to authorize() when nothing else is set; that
      # call is on the t() path and must not surface either.
      client = build_client(base_locale: nil)
      stub_request(:any, /api\.test/).to_raise(Errno::ECONNREFUSED)
      expect { client.t("Save", category: "UI") }.not_to raise_error
    end
  end

  describe "WIRE-4 — a failed catalog fetch must not queue registrations" do
    it "records nothing when the catalog could not be fetched" do
      # Without a catalog you cannot tell a miss from a hit, so queueing turns every
      # outage into a write storm on exactly the paths already failing.
      client = dead_client
      client.t("Save", category: "UI")
      client.t("Cancel", category: "UI")
      expect(client.has_pending?).to be(false)
      expect(client.pending_phrases).to be_empty
    end

    it "queues normally once the catalog is actually available" do
      # Positive control: the guard above must be the failure path, not a queue that
      # never fills.
      client = build_client
      stub_authorize
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      expect(client.has_pending?).to be(true)
    end

    it "does not queue a content block when the catalog could not be fetched" do
      client = dead_client
      client.translate_content_block("<p>Save</p>", category: "UI")
      expect(client.pending_content_blocks).to be_empty
    end
  end

  describe "WIRE-3 — normalise identifiers at the wire boundary" do
    it "sends a lowercase locale on the wire even when set with region casing" do
      client = build_client
      stub_authorize
      req = stub_translations("es-es", { "UI" => { "Save" => "Guardar" } })
      client.set_locale("es-ES")
      client.t("Save", category: "UI")
      expect(req).to have_been_requested
    end

    it "resolves en-US and en-us to the same cache entry rather than fetching twice" do
      client = build_client
      stub_authorize
      req = stub_translations("en-us", { "UI" => { "Save" => "Saved" } })
      client.set_locale("en-US")
      client.t("Save", category: "UI")
      client.set_locale("en-us")
      client.t("Save", category: "UI")
      expect(req).to have_been_requested.once
    end

    it "keeps display casing intact in translated HTML output" do
      client = build_client
      stub_authorize
      stub_translations("es-es", {})
      client.set_locale("es-ES")
      out = client.translate_page("<html><body><p>Save</p></body></html>")
      expect(out).to include('lang="es-ES"')
    end
  end

  describe "WIRE-1 — authenticate with the X-Authorization header" do
    it "sends the raw key with no Bearer prefix" do
      client = build_client
      req = stub_request(:get, /api\.test.*authorize-project/)
            .with(headers: { "X-Authorization" => "test-key" })
            .to_return(status: 200, body: JSON.generate(authorize_body),
                       headers: { "Content-Type" => "application/json" })
      client.project
      expect(req).to have_been_requested
    end
  end

  describe "GRANT — affirmative non-participation (server profile)" do
    # GRANT is browser-profile per the spec's families table, so this SDK must send no
    # grant. Asserted over the assembled header set rather than a config flag, and
    # case-insensitively: HTTP header names are case-insensitive, and a guard that
    # catches one casing is a guard someone walks past by accident.
    #
    # This is not decorative. The server gate is `type-allows-write OR valid-grant`, so
    # a grant can make a read key write-enabled — which means any read-key short-circuit
    # in the write decision is sound ONLY while no grant is sent. If this test ever
    # fails, grant support has landed: stop short-circuiting read keys in
    # Client#write_enabled? and resolve per response like ip_write.
    it "never sends an X-Write-Grant header on any request" do
      sent = []
      client = build_client
      stub_authorize
      stub_translations("en-us", {})
      allow_any_instance_of(Net::HTTP).to receive(:request).and_wrap_original do |orig, req, *args|
        req.each_header { |k, _| sent << k }
        orig.call(req, *args)
      end
      client.t("Save", category: "UI")
      expect(sent.select { |h| h.downcase.include?("write-grant") }).to be_empty
    end

    it "would catch a grant header if one were ever sent (matcher control)" do
      expect(%w[X-Write-Grant x-WRITE-grant].select { |h| h.downcase.include?("write-grant") }.size).to eq(2)
    end
  end
end
