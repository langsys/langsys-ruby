# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require_relative "support/contract_fixture"

# The API-dependent rows, graded `contract` against the fleet double (langsys-js-typescript tree
# 542f57f5). Assertions read accepted state back, or the SDK's own output; never a request log
# and never error text. An absence is evidence only where the double would have accepted the
# action, so each absence drifts the double's world after the SDK has learned its capability,
# and carries a control: a session that learns it may act, in the drifted world, does.
RSpec.describe "contract rows (spec 8.2.12)", contract: true do
  def world(allow_ip: false, faults: [], legacy: false, batch_limit: 200)
    contract.seed(
      "config" => { "batch_limit" => batch_limit, "legacy_omit_capability" => legacy },
      "projects" => [{ "id" => "proj-c", "target_locales" => ["es-es"] }],
      "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                 { "key" => "r", "project" => "proj-c", "type" => "read" },
                 { "key" => "ipw", "project" => "proj-c", "type" => "ip_write",
                   "ip_allowlist" => allow_ip ? ["127.0.0.1"] : [] }],
      "faults" => faults
    )
  end

  def stored = contract.phrases("proj-c").keys.map(&:last)

  describe "GATE-1 — branch on the server's write_enabled, never on key type" do
    it "registers on a write key (presence)" do
      world
      sdk = contract_client(key: "w")
      sdk.t("Written", category: "UI")
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Written"])
    end

    it "holds back on an ip_write key the server did not enable, even once the server would accept" do
      world(allow_ip: false)
      sdk = contract_client(key: "ipw")
      sdk.t("Held", category: "UI")
      expect(sdk.can_write?).to be(false)
      world(allow_ip: true) # drift: the double would now accept this key's write
      sdk.flush_pending
      expect(stored).to be_empty
      control = contract_client(key: "ipw")
      control.t("Learned", category: "UI")
      expect(control.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Learned"])
    end
  end

  describe "GATE-2 — a phrase seen is never lost because the decision was unavailable" do
    it "retains what a non-writing session saw, and registers it once the decision resolves true" do
      world(allow_ip: false)
      sdk = contract_client(key: "ipw")
      sdk.t("Kept", category: "UI")
      expect(sdk.flush_pending["reason"]).to eq("not_write_enabled")
      world(allow_ip: true)
      sdk.reset_write_decision!
      expect(sdk.flush_pending(refresh: true)["success"]).to be(true)
      expect(stored).to eq(["Kept"])
    end
  end

  describe "GATE-5 — bookkeeping records confirmed acceptance, never attempts" do
    it "marks nothing on a refused send, and marks the item once the server holds it" do
      world(faults: [{ "method" => "POST", "path" => "/translatable-items", "times" => 1, "status" => 500 }])
      now = [0.0]
      sdk = contract_client(key: "w", clock: -> { now[0] })
      sdk.t("Once", category: "UI")
      sdk.flush_pending
      expect([sdk.registered?("UI", "Once"), stored]).to eq([false, []])
      now[0] += 3.1
      sdk.flush_pending
      expect([sdk.registered?("UI", "Once"), stored]).to eq([true, ["Once"]])
      # A second read observes what the write registered.
      expect(contract_client(key: "r").get_translations["UI"]).to have_key("Once")
    end
  end

  describe "GATE-7 — every detection path feeds one lane" do
    it "leaves t(), the block API and both page shapes in the server's state, and no hint" do
      world
      sdk = contract_client(key: "w")
      sdk.t("Direct", category: "UI")
      sdk.translate_content_block("<p>Block <b>two</b></p>", category: "UI")
      sdk.translate_page("<html><body><p>Page phrase</p><p>Page <b>block</b></p></body></html>")
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to contain_exactly("Direct", "Page phrase")
      expect(contract.blocks("proj-c").map { |b| b["phrases"].map { |p| p["phrase"] } })
        .to contain_exactly(%w[Block two], %w[Page block])
      expect(contract.state["hints"]).to be_empty
    end
  end

  describe "GATE-8 — a missing write_enabled is a version signal, never permission" do
    it "infers write for a plain write key on a pre-capability server" do
      world(legacy: true)
      sdk = contract_client(key: "w")
      sdk.t("Legacy write", category: "UI")
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Legacy write"])
    end

    it "never infers write for ip_write, though the pre-capability double would accept it (control: write key)" do
      world(legacy: true, allow_ip: true)
      sdk = contract_client(key: "ipw")
      sdk.t("Not inferred", category: "UI")
      sdk.flush_pending
      expect(stored).to be_empty
      control = contract_client(key: "w")
      control.t("Control", category: "UI")
      control.flush_pending
      expect(stored).to eq(["Control"])
    end
  end

  describe "REG-8 — failed sends stay queued and back off" do
    it "retains the queue across two failures, waits the doubled delay, then registers" do
      world(faults: [{ "method" => "POST", "path" => "/translatable-items", "times" => 2, "status" => 503 }])
      now = [0.0]
      sdk = contract_client(key: "w", clock: -> { now[0] })
      sdk.t("Retry me", category: "UI")
      expect(sdk.flush_pending["reason"]).to eq("send_failed")
      now[0] += 3.1
      expect(sdk.flush_pending["reason"]).to eq("send_failed")
      now[0] += 5.9
      expect(sdk.flush_pending["reason"]).to eq("backing_off")
      now[0] += 0.2
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Retry me"])
    end
  end

  describe "REG-9 — batch to the server-provided limit" do
    it "gets every item accepted by a double that refuses an over-limit batch with 422" do
      world(batch_limit: 2)
      sdk = contract_client(key: "w")
      %w[One Two Three Four Five].each { |p| sdk.t(p, category: "UI") }
      sdk.translate_content_block("<p>Block <b>item</b></p>", category: "UI")
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to contain_exactly("One", "Two", "Three", "Four", "Five")
      expect(contract.blocks("proj-c").size).to eq(1)
    end
  end

  describe "REG-10 — one behaviour when registration fails" do
    it "reports an unresolvable decision without raising, keeps the queue, and registers later" do
      world(allow_ip: true,
            faults: [{ "method" => "GET", "path" => "/authorize-project/proj-c", "times" => 1,
                       "status" => 500 }])
      now = [0.0]
      sdk = contract_client(key: "ipw", clock: -> { now[0] })
      sdk.t("Later", category: "UI")
      result = nil
      expect { result = sdk.flush_pending }.not_to raise_error
      expect([result["success"], result["reason"], stored]).to eq([false, "decision_unavailable", []])
      now[0] += 3.1
      expect(sdk.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Later"])
    end

    it "reports a failed send as a failure, never success-shaped" do
      world(faults: [{ "method" => "POST", "path" => "/translatable-items", "times" => 1, "drop" => true }])
      sdk = contract_client(key: "w")
      sdk.t("Dropped", category: "UI")
      result = sdk.flush_pending
      expect([result["success"], result["reason"], stored]).to eq([false, "send_failed", []])
    end
  end

  describe "WIRE-2 — an empty success response" do
    it "treats a 204 with no body as success" do
      world(faults: [{ "method" => "POST", "path" => "/translatable-items", "times" => 1, "status" => 204 }])
      sdk = contract_client(key: "w")
      sdk.t("Empty ok", category: "UI")
      expect(sdk.flush_pending["success"]).to be(true)
    end
  end

  describe "WIRE-4 — the translation call never throws" do
    it "degrades every entry point when the catalog connection drops, and queues nothing" do
      world(faults: [{ "method" => "GET", "path" => "/translations", "times" => 3, "drop" => true }])
      sdk = contract_client(key: "w", base_locale: "es-ES")
      expect(sdk.t("Save", category: "UI")).to eq("Save")
      expect(sdk.has_pending?).to be(false)
    end
  end

  describe "OBS-1 — an unusable capability is surfaced once" do
    it "warns once across flushes on a session the server did not enable" do
      world
      log = StringIO.new
      sdk = contract_client(key: "r", logger: Logger.new(log))
      sdk.t("Unusable", category: "UI")
      3.times { sdk.flush_pending }
      expect(log.string.lines.grep(/not write-enabled/).size).to eq(1)
    end
  end

  describe "SRV-3 / MSG-8 — a key that may not write pushes nothing (drifted)" do
    it "holds back an ip_write session's misses and emitted template after the world would accept them" do
      world(allow_ip: false)
      sdk = contract_client(key: "ipw")
      sdk.request_scope do
        sdk.t("Page miss", category: "UI")
        sdk.emit_message(code: "invalid", template: "Emitted {n}.", params: { n: 1 })
      end
      expect(sdk.can_write?).to be(false)
      world(allow_ip: true)
      sdk.flush_pending
      expect(stored).to be_empty
      control = contract_client(key: "ipw")
      control.request_scope { control.t("Page miss", category: "UI") }
      expect(control.flush_pending["success"]).to be(true)
      expect(stored).to eq(["Page miss"])
    end
  end
end
