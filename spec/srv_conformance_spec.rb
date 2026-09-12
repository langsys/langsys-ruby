# frozen_string_literal: true

require "spec_helper"

# Conformance specs for the server-render rules (SRV-1..SRV-3). SRV-4/5 are the JS
# hydration half and are rowed n/a in CONFORMANCE.md with the reason.
RSpec.describe "SRV conformance" do
  describe "SRV-1 — serve the request locale's current translations" do
    it "emits the request locale's translation into the served bytes" do
      # Asserted on the served string, not on a post-hydration DOM: the served bytes are
      # the page for every reader not running our JavaScript, crawlers first.
      client = build_client
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi" } })
      client.set_locale("it-IT")
      out = client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')
      expect(out).to include("Prezzi")
      expect(out).not_to include(">Pricing<")
    end

    it "emits the base language for a genuine miss and reports it (control)" do
      # Without this control, "translated correctly" is indistinguishable from "rendered
      # a catalog that happened to be complete".
      client = build_client
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi" } })
      client.set_locale("it-IT")
      out = client.translate_page(
        '<html><body><p data-langsys-category="UI">Pricing</p>' \
        '<p data-langsys-category="UI">Checkout</p></body></html>'
      )
      expect(out).to include("Prezzi")
      expect(out).to include("Checkout")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to include("Checkout")
    end
  end

  describe "SRV-2 — the catalog is request-scoped" do
    it "keeps two concurrent renders in different locales from seeing each other's catalog" do
      # Running these sequentially proves nothing; the failure mode is the interleave.
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi" } })
      stub_translations("de-de", { "UI" => { "Pricing" => "Preise" } })

      results = {}
      threads = { "it-IT" => "Prezzi", "de-DE" => "Preise" }.map do |locale, _|
        Thread.new do
          client = build_client(cache: Langsys::Cache::Memory.new)
          client.set_locale(locale)
          30.times do
            results[locale] = client.translate_page(
              '<html><body><p data-langsys-category="UI">Pricing</p></body></html>'
            )
            Thread.pass
          end
        end
      end
      threads.each(&:join)

      expect(results["it-IT"]).to include("Prezzi")
      expect(results["it-IT"]).not_to include("Preise")
      expect(results["de-DE"]).to include("Preise")
      expect(results["de-DE"]).not_to include("Prezzi")
    end

    it "holds no process-global translation state" do
      # A second client must not inherit the first's catalog through anything shared.
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi" } })
      first = build_client(cache: Langsys::Cache::Memory.new)
      first.set_locale("it-IT")
      first.t("Pricing", category: "UI")

      stub_translations("de-de", { "UI" => { "Pricing" => "Preise" } })
      second = build_client(cache: Langsys::Cache::Memory.new)
      second.set_locale("de-DE")
      expect(second.t("Pricing", category: "UI")).to eq("Preise")
    end
  end

  describe "SRV-3 — collect misses after the response, never from a read-only key" do
    it "issues no registration request during the render itself" do
      # The ORDER is the assertion. A test that only checks a miss was eventually
      # collected passes against an implementation that collects it inline and hands the
      # visitor the latency.
      client = build_client
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("it-it", { "UI" => {} })
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true }),
                        headers: { "Content-Type" => "application/json" })
      client.set_locale("it-IT")
      client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')

      expect(post).not_to have_been_requested       # nothing on the request path
      expect(client.has_pending?).to be(true)       # but the miss WAS recorded
      client.flush_pending                          # ...and leaves after the response
      expect(post).to have_been_requested
    end

    it "pushes nothing from a read-only key" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("it-it", { "UI" => {} })
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true }),
                        headers: { "Content-Type" => "application/json" })
      client.set_locale("it-IT")
      client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')
      client.flush_pending
      expect(post).not_to have_been_requested
    end

    it "pushes from a write key on the same render (positive control)" do
      # The read-only half alone passes against an implementation that never pushes at
      # all, which is a coverage failure wearing a permission's clothing.
      client = build_client
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("it-it", { "UI" => {} })
      post = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: JSON.generate({ "status" => true }),
                        headers: { "Content-Type" => "application/json" })
      client.set_locale("it-IT")
      client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')
      client.flush_pending
      expect(post).to have_been_requested
    end
  end
end
