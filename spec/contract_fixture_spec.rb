# frozen_string_literal: true

require "spec_helper"
require "digest"
require_relative "support/contract_fixture"

RSpec.describe "contract fixture harness", contract: true do
  it "is the vendored tree, byte-exact" do
    # The git tree id, computed here rather than by git, so the check runs in any copy.
    dir = File.join(__dir__, "contract-fixture")
    object = ->(type, body) { Digest::SHA1.digest("#{type} #{body.bytesize}\0#{body}") }
    entries = Dir.children(dir).sort.map do |name|
      "100644 #{name}\0".b + object.call("blob", File.binread(File.join(dir, name)))
    end.join
    expect(object.call("tree", entries).unpack1("H*")).to eq(Langsys::ContractFixture::TREE)
  end

  it "reads back what a write key registered, and nothing from a read key" do
    contract.seed("projects" => [{ "id" => "proj-c" }],
                  "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" },
                             { "key" => "r", "project" => "proj-c", "type" => "read" }])
    writer = contract_client(key: "w")
    writer.t("Hello", category: "UI")
    expect(writer.flush_pending["success"]).to be(true)
    reader = contract_client(key: "r")
    reader.t("Other", category: "UI")
    reader.flush_pending
    expect(contract.phrases("proj-c").keys).to eq([%w[UI Hello]])
  end
end
