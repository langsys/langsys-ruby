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
    it "keeps two renders interleaved MID-RENDER from seeing each other's catalog" do
      # The previous version spawned two threads and called Thread.pass between whole
      # renders. Instrumented, zero of fifty-nine switches landed inside a render — so it
      # proved cross-client isolation of state held BETWEEN renders and said nothing about
      # the interleave, which is the failure this rule names. A class-variable @@locale
      # read mid-render survived it.
      #
      # The hand-off here is forced, not hoped for: a two-party barrier inside walk_block
      # holds each thread until the other has also entered a render, so both are provably
      # suspended mid-walk at the same instant. Each thread waits exactly once, so the
      # barrier cannot deadlock on an uneven number of blocks per page.
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi", "Checkout" => "Cassa" } })
      stub_translations("de-de", { "UI" => { "Pricing" => "Preise", "Checkout" => "Kasse" } })

      barrier = Mutex.new
      ready = ConditionVariable.new
      waiting = 0
      waited = {}.compare_by_identity
      met = false

      # A prepended module cannot be un-prepended, so it is armed by a flag that only
      # this example sets. Leaving a live hook on the class would let this spec change
      # another one's behaviour depending on the random order they run in — the same
      # cross-file contamination this repo already recorded once with constants.
      armed = true
      unless Langsys::Html::Page.const_defined?(:INTERLEAVE_HOOK_INSTALLED, false)
        hook = Module.new do
          define_method(:walk_block) do |child, effective|
            gate = Thread.current[:langsys_interleave_gate]
            gate&.call
            super(child, effective)
          end
        end
        Langsys::Html::Page.prepend(hook)
        Langsys::Html::Page.const_set(:INTERLEAVE_HOOK_INSTALLED, true)
      end

      wait_at_barrier = lambda do
        next unless armed
        next if waited[Thread.current]

        waited[Thread.current] = true
        barrier.synchronize do
          waiting += 1
          if waiting >= 2
            met = true
            ready.broadcast
          else
            ready.wait(barrier, 5)
          end
        end
      end

      body = '<p data-langsys-category="UI">Pricing</p><p data-langsys-category="UI">Checkout</p>'
      results = {}
      mutex = Mutex.new
      threads = %w[it-IT de-DE].map do |locale|
        Thread.new do
          Thread.current[:langsys_interleave_gate] = wait_at_barrier
          client = build_client(cache: Langsys::Cache::Memory.new)
          client.set_locale(locale)
          out = client.translate_page("<html><body>#{body}</body></html>")
          mutex.synchronize { results[locale] = out }
        ensure
          Thread.current[:langsys_interleave_gate] = nil
        end
      end
      threads.each { |t| t.join(15) }
      armed = false

      # The interleave is asserted, not assumed: if the barrier never met, this test is
      # measuring sequential renders again and must say so rather than pass quietly.
      expect(met).to be(true), "both renders were never in flight at once — interleave not exercised"
      expect(results.keys).to contain_exactly("it-IT", "de-DE")
      expect(results["it-IT"]).to include("Prezzi").and include("Cassa")
      expect(results["it-IT"]).not_to include("Preise")
      expect(results["it-IT"]).not_to include("Kasse")
      expect(results["de-DE"]).to include("Preise").and include("Kasse")
      expect(results["de-DE"]).not_to include("Prezzi")
      expect(results["de-DE"]).not_to include("Cassa")
    end

    it "keeps EVERY render of a repeated loop to its own locale, not just the last" do
      # The previous version assigned results[locale] each iteration and asserted only
      # the survivor, so twenty-nine of thirty renders were unexamined.
      stub_authorize
      stub_translations("it-it", { "UI" => { "Pricing" => "Prezzi" } })
      stub_translations("de-de", { "UI" => { "Pricing" => "Preise" } })

      collected = Hash.new { |h, k| h[k] = [] }
      mutex = Mutex.new
      threads = { "it-IT" => "Prezzi", "de-DE" => "Preise" }.map do |locale, _|
        Thread.new do
          client = build_client(cache: Langsys::Cache::Memory.new)
          client.set_locale(locale)
          30.times do
            out = client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')
            mutex.synchronize { collected[locale] << out }
            Thread.pass
          end
        end
      end
      threads.each { |t| t.join(20) }

      expect(collected["it-IT"].size).to eq(30)
      expect(collected["de-DE"].size).to eq(30)
      expect(collected["it-IT"]).to all(include("Prezzi"))
      expect(collected["it-IT"]).to all(satisfy { |o| !o.include?("Preise") })
      expect(collected["de-DE"]).to all(include("Preise"))
      expect(collected["de-DE"]).to all(satisfy { |o| !o.include?("Prezzi") })
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
    it "registers nothing during the render, only after the response" do
      # The ORDER is the assertion. A test that only checks a miss was eventually
      # collected passes against an implementation that collects it inline and hands the
      # visitor the latency.
      client = build_client
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("it-it", { "UI" => {} })
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return(status: 200, body: JSON.generate({ "status" => true }),
                   headers: { "Content-Type" => "application/json" })
      client.set_locale("it-IT")
      client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')

      # Nothing is accepted on the request path: the miss is recorded, not registered...
      expect(client.registered?("UI", "Pricing")).to be(false)
      expect(client.has_pending?).to be(true)
      client.flush_pending
      # ...and it is accepted only after the response.
      expect(client.registered?("UI", "Pricing")).to be(true)
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
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return(status: 200, body: JSON.generate({ "status" => true }),
                   headers: { "Content-Type" => "application/json" })
      client.set_locale("it-IT")
      client.translate_page('<html><body><p data-langsys-category="UI">Pricing</p></body></html>')
      client.flush_pending
      expect(client.registered?("UI", "Pricing")).to be(true)
    end
  end

  describe "SRV-5 — one registration per miss, counted from what was posted" do
    it "posts a repeated token from a depth-3 nested block exactly once" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("es-es", {})
      posted = []
      stub_request(:post, "https://api.test/api/translatable-items").to_return do |request|
        posted.concat(JSON.parse(request.body)["translatable_items"])
        { status: 200, body: JSON.generate({ "status" => true }), headers: { "Content-Type" => "application/json" } }
      end
      client = build_client
      client.set_locale("es-ES")
      client.translate_page("<html><body><div><section><article><p>Repeat</p><p>Miss <b>bold</b> Miss</p>" \
                            "<p>Repeat</p></article></section></div></body></html>")
      expect(client.flush_pending["success"]).to be(true)

      blocks, phrases = posted.partition { |item| item["type"] == "content_block" }
      # Counted, not compared as sets: the duplicates a re-entrant capture produces are identical.
      expect(phrases.map { |item| item["phrase"] }.tally).to eq({ "Repeat" => 1 })
      expect(blocks.map { |item| item["phrases"].map { |p| p["phrase"] } }).to eq([%w[Miss bold Miss]])
    end
  end
end
