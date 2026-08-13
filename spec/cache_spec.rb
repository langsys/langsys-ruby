# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.shared_examples "a cache backend" do
  it "stores and retrieves a value" do
    subject.set("k", { "a" => 1 })
    expect(subject.get("k")).to eq({ "a" => 1 })
  end

  it "misses on an unknown key" do
    expect(subject.get("nope")).to be_nil
  end

  it "deletes a key" do
    subject.set("k", 1)
    subject.delete("k")
    expect(subject.get("k")).to be_nil
  end

  it "expires after its ttl elapses" do
    subject.set("k", 1, 60)
    allow(Time).to receive(:now).and_return(Time.now + 120)
    expect(subject.get("k")).to be_nil
  end

  it "treats ttl 0 as no expiry" do
    subject.set("k", 1, 0)
    allow(Time).to receive(:now).and_return(Time.now + 10_000)
    expect(subject.get("k")).to eq(1)
  end
end

RSpec.describe Langsys::Cache::Memory do
  subject { described_class.new }

  it_behaves_like "a cache backend"
end

RSpec.describe Langsys::Cache::File do
  subject { described_class.new(Dir.mktmpdir) }

  it_behaves_like "a cache backend"

  it "sanitizes keys into safe filenames" do
    subject.set("translations/proj:es-ES", 42)
    expect(subject.get("translations/proj:es-ES")).to eq(42)
  end
end

RSpec.describe Langsys::Cache::Null do
  subject { described_class.new }

  it "never stores anything" do
    subject.set("k", 1)
    expect(subject.get("k")).to be_nil
  end
end
