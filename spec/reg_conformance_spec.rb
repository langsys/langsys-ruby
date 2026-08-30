# frozen_string_literal: true

require "spec_helper"

# Conformance specs for the registration lane (REG-*) plus the bookkeeping rules it
# carries (GATE-2, GATE-5) on the server profile.
RSpec.describe "REG conformance" do
  def post_stub(status: 200, body: { "status" => true })
    stub_request(:post, "https://api.test/api/translatable-items")
      .to_return(status: status, body: JSON.generate(body),
                 headers: { "Content-Type" => "application/json" })
  end

  def writing_client(**overrides)
    build_client(**overrides).tap do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
    end
  end

  describe "REG-2 — debounce; a fixed interval is never the only path to sending" do
    it "coalesces a burst from one render into a single request" do
      client = writing_client
      post = post_stub
      %w[Save Cancel Delete Edit Close].each { |p| client.t(p, category: "UI") }
      client.flush_pending
      expect(post).to have_been_requested.once
    end

    it "reports the burst as due only once activity has settled" do
      now = 0.0
      client = writing_client(clock: -> { now })
      client.t("Save", category: "UI")
      expect(client.flush_due?).to be(false)
      now += 0.2
      client.t("Cancel", category: "UI")   # burst continues — still not due
      expect(client.flush_due?).to be(false)
      now += 0.5                           # activity settled past the debounce
      expect(client.flush_due?).to be(true)
    end

    it "does not report due when nothing is queued" do
      now = 100.0
      client = writing_client(clock: -> { now })
      expect(client.flush_due?).to be(false)
    end

    it "sends on the debounce rather than only on a fixed tick" do
      now = 0.0
      client = writing_client(clock: -> { now })
      post = post_stub
      client.t("Save", category: "UI")
      expect(client.flush_if_due["phrases"]).to eq(0)
      now += 1.0
      expect(client.flush_if_due["phrases"]).to eq(1)
      expect(post).to have_been_requested.once
    end
  end

  describe "REG-3 — flush before the execution context ends" do
    it "exposes a public manual flush" do
      # On the server the automatic path is best-effort only: shutdown hooks do not run
      # on OOM kill or hard timeout, and there is no later page to recover on.
      expect(build_client).to respond_to(:flush_pending)
    end

    it "flushes what is queued when the context ends" do
      client = writing_client
      post = post_stub
      client.t("Save", category: "UI")
      client.flush_on_shutdown
      expect(post).to have_been_requested.once
    end

    it "never raises out of the shutdown path" do
      client = writing_client
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      expect { client.flush_on_shutdown }.not_to raise_error
    end
  end

  describe "REG-3 — a backed-off queue is never dropped silently at shutdown" do
    it "makes one final attempt even while backing off" do
      now = 0.0
      client = writing_client(clock: -> { now })
      failing = stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending # fails, arms the backoff
      expect(failing).to have_been_requested.once

      post_stub                                  # the endpoint recovers
      client.flush_on_shutdown                   # must not be blocked by the backoff
      expect(client.pending_phrases).to be_empty
    end

    it "logs the abandonment with a count when that final attempt also fails" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      allow(logger).to receive(:debug)
      client = writing_client(logger: logger)
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending
      logged.clear
      client.flush_on_shutdown
      # There is no later page in this session to recover on, so silence here is
      # permanent loss that nothing records.
      expect(logged.grep(/abandon/i).join).to include("1")
    end
  end

  describe "REG-2 — a continuous trickle still sends" do
    it "flushes once the max wait has elapsed even if activity never settles" do
      # Debounce alone starves a stream that never goes quiet: each new miss pushes the
      # window out and nothing is ever due.
      now = 0.0
      client = writing_client(clock: -> { now })
      20.times do |i|
        client.t("Trickle #{i}", category: "UI")
        now += 0.3 # always shorter than the debounce
      end
      expect(client.flush_due?).to be(true)
    end

    it "still waits for the burst to settle when the max wait has not elapsed" do
      now = 0.0
      client = writing_client(clock: -> { now })
      client.t("Save", category: "UI")
      now += 0.3
      client.t("Cancel", category: "UI")
      expect(client.flush_due?).to be(false)
    end
  end

  describe "REG-10 — an unresolvable write decision is reported, not raised" do
    it "reports decision_unavailable and retains the queue when authorize fails" do
      now = 0.0
      client = build_client(clock: -> { now }, cache: Langsys::Cache::Memory.new)
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")

      # Authorize itself now fails — the capability check is a network call too.
      stub_request(:any, /api\.test/).to_raise(Errno::ECONNREFUSED)
      result = client.flush_pending(refresh: true)
      expect(result["success"]).to be(false)
      expect(result["reason"]).to eq("decision_unavailable")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Save"])
    end

    it "backs off after an unresolvable decision rather than retrying immediately" do
      now = 0.0
      client = build_client(clock: -> { now }, cache: Langsys::Cache::Memory.new)
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      stub_request(:any, /api\.test/).to_raise(Errno::ECONNREFUSED)
      client.flush_pending(refresh: true)
      expect(client.retry_delay).to eq(3.0)
    end
  end

  describe "REG-6 — snapshot the batch; never clear the live queue after an await" do
    it "keeps an item queued when it arrives mid-request" do
      # The window is every in-flight request. Clearing the live queue afterwards marks
      # the late arrival registered, discards it unsent, and never retries it.
      client = writing_client
      late = nil
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return do
          late ||= client.t("Arrived mid-flight", category: "UI")
          { status: 200, body: JSON.generate({ "status" => true }),
            headers: { "Content-Type" => "application/json" } }
        end
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.pending_phrases.map { |p| p["phrase"] }).to include("Arrived mid-flight")
    end

    it "clears exactly what was sent (positive control)" do
      client = writing_client
      post_stub
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.pending_phrases).to be_empty
    end
  end

  describe "GATE-5 — the marker's namespace comes from the snapshot, not the live queue" do
    it "records a content block under its own category even if the queue is cleared mid-flight" do
      # #confirm used to re-read @blocks for the category. If the live queue is cleared
      # while the request is open the block is gone by then, the category reads as nil,
      # and the marker lands under __uncategorized__ — a bookkeeping entry answering for
      # the wrong category, which GATE-5 then makes permanent. The server de-duplicates
      # the registration itself, so nothing downstream would ever reveal it.
      client = writing_client
      stub_translations("en-us", { "Home" => {} })
      cleared = false
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return do
          unless cleared
            cleared = true
            client.clear_pending
          end
          { status: 200, body: JSON.generate({ "status" => true }),
            headers: { "Content-Type" => "application/json" } }
        end

      client.translate_content_block("<p>Welcome</p>", category: "Home")
      custom_id = Langsys.generate_custom_id("Home", ["Welcome"])
      client.flush_pending

      expect(client.registered?("Home", custom_id)).to be(true)
      expect(client.registered?(Langsys::UNCATEGORIZED, custom_id)).to be(false)
    end
  end

  describe "REG-7 — one send in flight at a time" do
    it "does not start a second send while one is in flight" do
      client = writing_client
      inner = nil
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return do
          inner ||= client.flush_pending
          { status: 200, body: JSON.generate({ "status" => true }),
            headers: { "Content-Type" => "application/json" } }
        end
      client.t("Save", category: "UI")
      client.flush_pending
      expect(inner["success"]).to be(false)
      expect(inner["reason"]).to eq("in_flight")
    end

    it "sends the first phrase exactly once across a re-entrant flush" do
      client = writing_client
      post = post_stub
      reentered = false
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return do
          unless reentered
            reentered = true
            client.flush_pending
          end
          { status: 200, body: JSON.generate({ "status" => true }),
            headers: { "Content-Type" => "application/json" } }
        end
      client.t("Save", category: "UI")
      client.flush_pending
      expect(post).to have_been_requested.once
    end
  end

  describe "REG-8 — failed sends stay queued and back off exponentially" do
    it "retains the queue when the send fails" do
      client = writing_client
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Save"])
    end

    it "reports failure rather than a success-shaped result" do
      client = writing_client
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      expect(client.flush_pending["success"]).to be(false)
    end

    it "refuses to send again until the backoff has elapsed" do
      now = 0.0
      client = writing_client(clock: -> { now })
      failing = stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending
      client.flush_pending
      client.flush_pending
      expect(failing).to have_been_requested.once
    end

    it "doubles the delay on each failure, to a ceiling" do
      now = 0.0
      client = writing_client(clock: -> { now })
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      seen = []
      12.times do
        client.flush_pending
        seen << client.retry_delay
        now += client.retry_delay + 0.01
      end
      expect(seen.first).to eq(3.0)
      expect(seen[1]).to eq(6.0)
      expect(seen[2]).to eq(12.0)
      expect(seen.last).to eq(300.0)
      expect(seen.max).to eq(300.0)
    end

    it "resets the backoff on the first success" do
      now = 0.0
      client = writing_client(clock: -> { now })
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.retry_delay).to eq(3.0)

      now += 10.0
      post_stub
      client.flush_pending
      expect(client.retry_delay).to be_nil
    end

    it "does not fight WIRE-4's no-storm guard: a failed FETCH adds nothing, backoff drops nothing" do
      # The two rules touch different queues and must not be conflated. WIRE-4 suppresses
      # queueing only when the catalog could not be fetched — a cached catalog can still
      # tell a miss from a hit, so it keeps queueing, and that is not a storm. REG-8
      # separately guarantees the send queue survives the outage.
      now = 0.0
      client = build_client(clock: -> { now }, cache: Langsys::Cache::Memory.new)
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")

      stub_request(:any, /api\.test/).to_raise(Errno::ECONNREFUSED)
      client.flush_pending
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Save"])

      # The warm client KEEPS queueing new misses, because a cached catalog can still
      # tell a miss from a hit. Asserted rather than described: this is the half that
      # distinguishes "outage" from "failed fetch", and a comment proves nothing.
      client.t("Rendered against the warm catalog", category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] })
        .to contain_exactly("Save", "Rendered against the warm catalog")

      # A client with no catalog of its own records nothing during the same outage.
      fresh = build_client(clock: -> { now }, cache: Langsys::Cache::Memory.new)
      5.times { fresh.t("Rendered during the outage", category: "UI") }
      expect(fresh.pending_phrases).to be_empty

      # ...and the first client's queue is still intact, not drained by the failures.
      expect(client.pending_phrases.map { |p| p["phrase"] }).to include("Save")
    end
  end

  describe "GATE-2 — a phrase seen is never lost because the write decision was unavailable" do
    it "keeps the queue when the session is not write-enabled" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Save"])
    end

    it "registers what was held once capability resolves true" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      client.flush_pending

      stub_authorize(key_type: "read", write_enabled: true)
      post = post_stub
      client.flush_pending(refresh: true)
      expect(post).to have_been_requested.once
    end
  end

  describe "GATE-5 / REG-10 — bookkeeping records confirmed acceptance, never attempts" do
    it "does not mark an item registered when the send failed" do
      client = writing_client
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.registered?("UI", "Save")).to be(false)
    end

    it "marks an item registered once the server accepted it (positive control)" do
      client = writing_client
      post_stub
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.registered?("UI", "Save")).to be(true)
    end

    it "does not mark an item registered on a skipped write" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      client.flush_pending
      expect(client.registered?("UI", "Save")).to be(false)
    end

    it "never returns a success-shaped result for a skipped write" do
      client = build_client
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      result = client.flush_pending
      expect(result["success"]).to be(false)
      expect(result["reason"]).to eq("not_write_enabled")
    end

    it "never throws into a user-facing render path" do
      client = writing_client(auto_flush: true)
      stub_request(:post, "https://api.test/api/translatable-items").to_raise(Errno::ECONNREFUSED)
      expect { client.t("Save", category: "UI") }.not_to raise_error
    end
  end

  describe "REG-11 — warn on ellipsis-terminated text; suppress only on a second signal" do
    it "warns but still registers a phrase ending in an ellipsis" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      allow(logger).to receive(:debug) { |m| logged << m }
      client = writing_client(logger: logger)
      post_stub
      client.t("Loading…", category: "UI")
      client.flush_pending
      expect(logged.join).to include("Loading…")
      expect(client.registered?("UI", "Loading…")).to be(true)
    end

    it "warns on the three-dot spelling too" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      allow(logger).to receive(:debug)
      client = writing_client(logger: logger)
      post_stub
      client.t("Please wait...", category: "UI")
      expect(logged.join).to match(/ellips/i)
    end

    it "suppresses registration only when a longer catalog entry shares the prefix" do
      # The prefix signal is the actual harm condition: the truncated form has already
      # polluted the catalog beside the full paragraph.
      client = build_client
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", { "UI" => { "The quick brown fox jumps over the lazy dog" => "…" } })
      client.t("The quick brown fox…", category: "UI")
      expect(client.pending_phrases).to be_empty
    end

    it "still queues an ellipsis phrase with no longer sibling (positive control)" do
      client = writing_client
      client.t("Loading…", category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Loading…"])
    end
  end

  describe "REG-12 / CAT-3 — content blocks are distinguished structurally" do
    it "treats a nested map as a content block, never a missing phrase" do
      client = writing_client
      stub_translations("en-us", { "UI" => { "abc123" => { "Welcome" => "Bienvenido" } } })
      client.t("abc123", category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] }).not_to include("abc123")
    end

    it "registers a phrase that merely looks like a block id" do
      # A 32-hex shape test would reject this legitimate phrase.
      client = writing_client
      hexish = "d41d8cd98f00b204e9800998ecf8427e"
      stub_translations("en-us", { "UI" => {} })
      client.t(hexish, category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to include(hexish)
    end
  end

  describe "REG-9 — batch to the server-provided limit, on every path" do
    it "chunks to the server's limit rather than a hardcoded one" do
      client = build_client
      stub_request(:get, "https://api.test/api/authorize-project/proj-1")
        .to_return(status: 200,
                   body: JSON.generate(authorize_body(key_type: "write", write_enabled: true)
                     .tap { |b| b["data"]["langsys_settings"]["translatable_items"]["batch_limit"] = 2 }),
                   headers: { "Content-Type" => "application/json" })
      stub_translations("en-us", { "UI" => {} })
      post = post_stub
      5.times { |i| client.t("Phrase #{i}", category: "UI") }
      client.flush_pending
      expect(post).to have_been_requested.times(3)
    end
  end

  describe "WIRE-2 — handle empty success responses" do
    it "treats a 204 with no body as success" do
      client = writing_client
      stub_request(:post, "https://api.test/api/translatable-items").to_return(status: 204, body: "")
      client.t("Save", category: "UI")
      expect(client.flush_pending["success"]).to be(true)
      expect(client.registered?("UI", "Save")).to be(true)
    end
  end

  describe "OBS-1 — surface an unusable capability at least once" do
    it "warns once when the session cannot register what it has discovered" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      allow(logger).to receive(:debug)
      client = build_client(logger: logger)
      stub_authorize(key_type: "read", write_enabled: false)
      stub_translations("en-us", { "UI" => {} })
      client.t("Save", category: "UI")
      3.times { client.flush_pending }
      expect(logged.grep(/not write-enabled|cannot register/i).size).to eq(1)
    end
  end
end
