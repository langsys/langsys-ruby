# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Signal do
  it "seeds and returns the current value" do
    expect(described_class.new("en-US").get).to eq("en-US")
  end

  it "fires a subscriber immediately and on change" do
    signal = described_class.new("en-US")
    seen = []
    signal.subscribe(->(v) { seen << v })
    signal.set("es-ES")
    expect(seen).to eq(%w[en-US es-ES])
  end

  it "is a no-op when the value is unchanged" do
    signal = described_class.new("en-US")
    seen = []
    signal.subscribe(->(v) { seen << v })
    signal.set("en-US")
    expect(seen).to eq(["en-US"])
  end

  it "stops notifying after unsubscribe" do
    signal = described_class.new(0)
    seen = []
    unsub = signal.subscribe(->(v) { seen << v })
    unsub.call
    signal.set(1)
    expect(seen).to eq([0])
  end
end
