# frozen_string_literal: true

require "spec_helper"
require_relative "support/contract_fixture"

# SRV-3: a miss recorded inside a request scope is sent by no flush (timer, explicit, or another
# request's) until a scope that recorded it has ended. Outside a scope nothing changes, and the
# shutdown flush releases everything. An unended scope holds its misses until shutdown.
RSpec.describe "spec 8.2.x SRV-3 request scope", contract: true do
  before do
    contract.seed("projects" => [{ "id" => "proj-c" }],
                  "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                             { "key" => "r", "project" => "proj-c", "type" => "read" }])
  end

  def held = contract.phrases("proj-c").keys.map(&:last)

  it "sends nothing recorded in an open scope, and sends it once that scope has ended" do
    client = contract_client(key: "w")
    scope = client.begin_request_scope
    client.t("In request", category: "UI")
    expect(client.flush_pending["success"]).to be(false)
    expect(held).to be_empty
    client.end_request_scope(scope)
    expect(client.flush_pending["success"]).to be(true)
    expect(held).to eq(["In request"])
  end

  it "does not let one request's flush send a miss another in-flight request recorded" do
    client = contract_client(key: "w")
    request_a = client.begin_request_scope
    client.t("From A", category: "UI")
    Thread.new do
      request_b = Langsys.begin_request_scope
      client.t("From B", category: "UI")
      Langsys.end_request_scope(request_b)
      client.flush_pending
    end.join
    expect(held).to eq(["From B"])
    client.end_request_scope(request_a)
    client.flush_pending
    expect(held).to contain_exactly("From A", "From B")
  end

  it "releases a miss two overlapping requests recorded when either ends" do
    client = contract_client(key: "w")
    request_a = Langsys.begin_request_scope
    client.t("Shared", category: "UI")
    request_b = Thread.new do
      scope = Langsys.begin_request_scope
      client.t("Shared", category: "UI")
      scope
    end.value
    Langsys.end_request_scope(request_b)
    client.flush_pending
    expect(held).to eq(["Shared"])
    Langsys.end_request_scope(request_a)
  end

  it "leaves a miss recorded outside any scope unchanged (control)" do
    client = contract_client(key: "w")
    client.t("Loose", category: "UI")
    expect(client.flush_pending["success"]).to be(true)
    expect(held).to eq(["Loose"])
  end

  it "holds an unended scope's misses until the shutdown flush, which releases them" do
    client = contract_client(key: "w")
    Langsys.begin_request_scope
    client.t("Never ended", category: "UI")
    client.flush_pending
    expect(held).to be_empty
    client.flush_on_shutdown
    expect(held).to eq(["Never ended"])
  end

  it "joins a scope opened before the client existed (a lazily built client)" do
    scope = Langsys.begin_request_scope
    client = contract_client(key: "w")
    client.t("Lazy", category: "UI")
    client.flush_pending
    expect(held).to be_empty
    Langsys.end_request_scope(scope)
    client.flush_pending
    expect(held).to eq(["Lazy"])
  end

  it "ends the block form's scope even when the block raises" do
    client = contract_client(key: "w")
    expect { client.request_scope { client.t("Raised", category: "UI") && raise("boom") } }.to raise_error("boom")
    client.flush_pending
    expect(held).to eq(["Raised"])
  end

  it "keeps two request fibers on one thread in their own scopes" do
    client = contract_client(key: "w")
    scopes = {}
    fibers = %w[F1 F2].to_h do |name|
      [name, Fiber.new do
        scopes[name] = Langsys.begin_request_scope
        Fiber.yield
        client.t("From #{name}", category: "UI")
      end]
    end
    fibers.each_value(&:resume)
    fibers.each_value(&:resume)
    Langsys.end_request_scope(scopes["F1"])
    client.flush_pending
    expect(held).to eq(["From F1"])
    Langsys.end_request_scope(scopes["F2"])
  end

  it "keeps fibers apart on the Thread#[] fallback too (Ruby before 3.2)" do
    allow(Langsys::RequestScope).to receive(:fiber_storage?).and_return(false)
    client = contract_client(key: "w")
    scope = nil
    Fiber.new { scope = Langsys.begin_request_scope }.resume
    client.t("Outside that fiber", category: "UI")
    client.flush_pending
    expect(held).to eq(["Outside that fiber"])
    Langsys.end_request_scope(scope)
  end

  it "pushes nothing from a read-only key after the scope ends" do
    client = contract_client(key: "r")
    client.request_scope { client.t("Read only", category: "UI") }
    client.flush_pending
    expect(held).to be_empty
  end
end
