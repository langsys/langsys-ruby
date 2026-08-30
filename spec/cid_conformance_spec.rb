# frozen_string_literal: true

require "spec_helper"
require "digest"

# Conformance specs for content-block identity (CID-1..CID-4), anchored on the shared
# fixture rather than on values re-typed into this file.
# Vendored from langsys-php at blob 60dc9b33ecfd (commit 8862841, "Pin the canonical
# serialization at three flags; lock U+2028 with a fixture row"). Vendored rather than
# fetched so the suite stays hermetic and a fixture change arrives as a reviewable diff.
#
# Namespaced rather than left as bare top-level constants: a same-named constant in any
# other spec file rebinds these silently, which is not hypothetical — it happened, and it
# broke the three integrity assertions below without touching the fixture.
module CidFixture
  BLOB = "60dc9b33ecfd5fa3256fca7d36063ceb8ef1a00a"
  PATH = File.expand_path("fixtures/custom-id-reference.json", __dir__)
  ROWS = begin
    parsed = JSON.parse(File.read(PATH))
    parsed.is_a?(Hash) ? parsed["rows"] : parsed
  end
end

RSpec.describe "CID conformance" do
  def codepoints_of(row)
    cps = row["codepoints"]
    (cps.is_a?(Hash) ? cps.values.flatten : Array(cps)).flatten
  end

  # Rebuild the row's input from its declared codepoints — never from the glyphs.
  def rebuild(row)
    codepoints_of(row).filter_map do |c|
      c.to_s =~ /\AU\+([0-9A-Fa-f]+)\z/ ? [Regexp.last_match(1).to_i(16)].pack("U") : nil
    end.join
  end

  describe "fixture integrity (asserted before any hash comparison)" do
    # Ordering is load-bearing, not tidiness: a vendoring pipeline that normalised
    # U+2028 away would leave every hash assertion below testing the pipeline instead
    # of the SDK, and passing.
    it "is the exact blob it was pinned at" do
      blob = `git hash-object #{Shellwords.escape(CidFixture::PATH)}`.strip
      expect(blob).to eq(CidFixture::BLOB)
    end

    it "reconstructs every row's input from its declared codepoints" do
      mismatched = CidFixture::ROWS.each_with_index.reject do |row, _|
        rebuild(row) == ([row["category"].to_s] + Array(row["tokens"])).join
      end
      expect(mismatched.map(&:last)).to be_empty
    end

    it "carries a codepoint above U+00FF and a non-BMP codepoint" do
      all = CidFixture::ROWS.flat_map { |r| codepoints_of(r) }.filter_map { |c| c.to_s[/\AU\+([0-9A-Fa-f]+)\z/, 1]&.to_i(16) }
      expect(all.any? { |c| c > 0x00FF }).to be(true)
      expect(all.any? { |c| c > 0xFFFF }).to be(true)
    end

    it "still contains the U+2028 row the pin exists for (positive control)" do
      expect(CidFixture::ROWS.any? { |r| codepoints_of(r).any? { |c| c.to_s.casecmp("U+2028").zero? } }).to be(true)
    end
  end

  describe "CID-1 — one byte-identical hash" do
    CidFixture::ROWS.each_with_index do |row, i|
      it "row #{i + 1} hashes to the shared id" do
        expect(Langsys.generate_custom_id(row["category"], row["tokens"])).to eq(row["custom_id"])
      end

      it "row #{i + 1} serialises to the shared bytes" do
        # Asserted through the SAME function the id is hashed from — never a second
        # expression written here, which would agree with itself and keep agreeing
        # after the real one moved.
        actual = Langsys.canonical_block_json(row["category"], row["tokens"])
                        .bytes.map { |b| format("%02x", b) }.join
        expect(actual).to eq(row["serialized_hex"].downcase.delete(" "))
      end
    end

    it "does not escape slashes" do
      expect(Langsys.canonical_block_json("UI", ["a/b"])).to include("a/b")
    end

    it "does not escape non-ASCII" do
      expect(Langsys.canonical_block_json("UI", ["café"])).to include("café")
    end

    it "emits U+2028 raw rather than escaped" do
      # script_safe: true would escape this and silently break byte-identity. It is the
      # single option that breaks CID-1 in Ruby, and nothing else in the suite would notice.
      expect(Langsys.canonical_block_json("UI", ["a b"]).bytes.map { |b| format("%02x", b) }.join)
        .to include("e280a8")
    end

    it "hashes UTF-8 bytes, not UTF-16 code units" do
      expect(Langsys.generate_custom_id("UI", ["Ł"])).not_to eq(Langsys.generate_custom_id("UI", ["A"]))
    end

    it "is order-sensitive across the phrase array" do
      expect(Langsys.generate_custom_id("UI", %w[Hello World]))
        .not_to eq(Langsys.generate_custom_id("UI", %w[World Hello]))
    end
  end

  describe "CID-2 — no-category is '' , never null and never a sentinel" do
    it "treats a nil category as the empty string at the function" do
      expect(Langsys.generate_custom_id(nil, ["Save"])).to eq(Langsys.generate_custom_id("", ["Save"]))
    end

    it "never lets the __uncategorized__ sentinel reach the hash input" do
      # The sentinel is a cache-lookup namespace, not a hash input.
      expect(Langsys.generate_custom_id(Langsys::UNCATEGORIZED, ["Save"]))
        .to eq(Langsys.generate_custom_id("", ["Save"]))
    end

    it "does not serialise a null category" do
      expect(Langsys.canonical_block_json(nil, ["Save"])).to start_with('["",')
    end

    # The second clause of CID-2: whether the rule holds is a fact about the CALLERS,
    # not about the function. Measuring the right function is not measuring the right call.
    it "holds at the content-block caller, which passes the sentinel category" do
      client = build_client
      stub_authorize
      stub_translations("en-us", {})
      client.translate_content_block("<p>Save</p>")
      queued = client.pending_content_blocks.first
      expect(queued["custom_id"]).to eq(Langsys.generate_custom_id("", ["Save"]))
    end
  end

  describe "CID-3 — tolerate historical ids on lookup; never emit them" do
    let(:phrases) { ["Welcome"] }
    let(:legacy_id) { Digest::MD5.hexdigest(["Home", *phrases].join("|")) }

    it "resolves a block stored under the legacy pipe-join id" do
      client = build_client
      stub_authorize
      stub_translations("es-es", { "Home" => { legacy_id => { "Welcome" => "Bienvenido" } } })
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Welcome</p>", category: "Home")).to include("Bienvenido")
    end

    it "emits only the canonical id when registering, never the legacy one" do
      client = build_client
      stub_authorize
      stub_translations("es-es", { "Home" => {} })
      client.set_locale("es-ES")
      client.translate_content_block("<p>Welcome</p>", category: "Home")
      queued = client.pending_content_blocks.first
      expect(queued["custom_id"]).to eq(Langsys.generate_custom_id("Home", phrases))
      expect(queued["custom_id"]).not_to eq(legacy_id)
    end

    it "prefers the canonical id when both are present" do
      canonical = Langsys.generate_custom_id("Home", phrases)
      client = build_client
      stub_authorize
      stub_translations("es-es", { "Home" => {
                          canonical => { "Welcome" => "Canonical" },
                          legacy_id => { "Welcome" => "Legacy" }
                        } })
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Welcome</p>", category: "Home")).to include("Canonical")
    end
  end

  describe "CID-3 — both uncategorised legacy spellings resolve" do
    # Two old paths wrote the same uncategorised block under different spellings: one
    # defaulted the category to '' before joining, the other passed the
    # '__uncategorized__' sentinel through. The shipping PHP SDK writes the sentinel
    # form by default, and this SDK's own pre-wave HTML path emitted it too — so an
    # SDK that tolerates only the empty spelling misses real, already-registered
    # content. That miss is silent: the block re-registers under the canonical id,
    # machine translation refills it, the page still looks right, and the human
    # translations sit orphaned on the old id.
    it "resolves a block stored under the empty-category pipe spelling" do
      legacy = Digest::MD5.hexdigest(["", "Welcome"].join("|"))
      client = build_client
      stub_authorize
      stub_translations("es-es", { Langsys::UNCATEGORIZED => { legacy => { "Welcome" => "Bienvenido" } } })
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Welcome</p>")).to include("Bienvenido")
    end

    it "resolves a block stored under the __uncategorized__ sentinel pipe spelling" do
      legacy = Digest::MD5.hexdigest([Langsys::UNCATEGORIZED, "Welcome"].join("|"))
      client = build_client
      stub_authorize
      stub_translations("es-es", { Langsys::UNCATEGORIZED => { legacy => { "Welcome" => "Bienvenido" } } })
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Welcome</p>")).to include("Bienvenido")
    end

    it "offers both uncategorised spellings, most likely first and deduped" do
      ids = Langsys.legacy_custom_ids(nil, ["Welcome"])
      expect(ids).to eq([
                          Digest::MD5.hexdigest(["", "Welcome"].join("|")),
                          Digest::MD5.hexdigest([Langsys::UNCATEGORIZED, "Welcome"].join("|"))
                        ])
      expect(ids.uniq).to eq(ids)
    end

    it "offers only the one spelling for a real category" do
      expect(Langsys.legacy_custom_ids("Home", ["Welcome"]))
        .to eq([Digest::MD5.hexdigest(%w[Home Welcome].join("|"))])
    end

    it "still content-verifies a sentinel-spelling match before attaching" do
      legacy = Digest::MD5.hexdigest([Langsys::UNCATEGORIZED, "Welcome"].join("|"))
      client = build_client
      stub_authorize
      stub_translations("es-es", { Langsys::UNCATEGORIZED => { legacy => { "Different phrase" => "Otra" } } })
      client.set_locale("es-ES")
      out = client.translate_content_block("<p>Welcome</p>")
      expect(out).to include("Welcome")
      expect(out).not_to include("Otra")
    end
  end

  describe "CID-4 — verify a legacy match on content before attaching" do
    # The historical id spaces are not injective, so a legacy hit is not proof of identity.
    it "declines a legacy match whose phrases differ from the current block" do
      colliding = Digest::MD5.hexdigest(%w[Home Welcome].join("|"))
      client = build_client
      stub_authorize
      # Same legacy id, different content — the collision case the guard exists for.
      stub_translations("es-es", { "Home" => { colliding => { "Something else entirely" => "Otra cosa" } } })
      client.set_locale("es-ES")
      out = client.translate_content_block("<p>Welcome</p>", category: "Home")
      expect(out).to include("Welcome")
      expect(out).not_to include("Otra cosa")
    end

    it "attaches when the legacy match's phrases do agree (positive control)" do
      # Without this, the guard above could pass by never attaching to anything.
      legacy = Digest::MD5.hexdigest(%w[Home Welcome].join("|"))
      client = build_client
      stub_authorize
      stub_translations("es-es", { "Home" => { legacy => { "Welcome" => "Bienvenido" } } })
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Welcome</p>", category: "Home")).to include("Bienvenido")
    end
  end
end
