# frozen_string_literal: true

require "spec_helper"
require "digest"

# The shared catalog snapshot vectors (langsys-js-typescript a639ae8c, blob 594bd77a): exact
# canonical bytes and digest per row, refusals by reason, and a reordered document that loads.
module SnapshotVectors
  BLOB = "594bd77a0289abfdf608508ac93cc9f4c4f88459"
  PATH = File.expand_path("fixtures/snapshot-vectors.json", __dir__)
  DATA = JSON.parse(File.read(PATH))
  REASONS = { "checksum" => /checksum/, "format" => /format/, "version" => /version/,
              "missing-member" => /missing/ }.freeze
end

RSpec.describe "spec SNAP-1 shared snapshot vectors" do
  it "is the exact blob it was vendored at" do
    expect(`git hash-object #{Shellwords.escape(SnapshotVectors::PATH)}`.strip).to eq(SnapshotVectors::BLOB)
  end

  SnapshotVectors::DATA["rows"].each do |row|
    it "rows: #{row['id']} serialises to the exact canonical bytes and digest, and loads" do
      doc = row["document"]
      canonical = Langsys::Snapshot.canonical(doc.except("format", "version", "checksum"))
      expect(canonical.b).to eq(row["canonical"].b)
      expect("sha256:#{Digest::SHA256.hexdigest(canonical)}").to eq(row["checksum"])
      expect(doc["checksum"]).to eq(row["checksum"])
      expect { Langsys::Snapshot.parse(JSON.generate(doc)) }.not_to raise_error
    end
  end

  SnapshotVectors::DATA["refusals"].each do |row|
    it "refusals: #{row['id']} is refused naming #{row['refuse']}" do
      expect { Langsys::Snapshot.parse(JSON.generate(row["document"])) }
        .to raise_error(Langsys::ConfigurationError, SnapshotVectors::REASONS.fetch(row["refuse"]))
    end
  end

  SnapshotVectors::DATA["loads"].each do |row|
    it "loads: #{row['id']}" do
      snapshot = Langsys::Snapshot.parse(JSON.generate(row["document"]))
      expect(snapshot.catalog(row["locale"])).to eq(row["expect_catalog"])
    end
  end
end
