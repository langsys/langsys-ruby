# frozen_string_literal: true

require "spec_helper"

# TOK-2 (8.2.10): the 28 C0 controls are removed before anything collapses, on every string
# that becomes an id input or a catalog key. Asserted on the canonicalization function
# directly: Nokogiri's packaged libxml2 (2.13.x) drops these from DOM text itself, so a
# DOM-level text-node test would pass without the SDK doing anything.
module Strip8210
  STRIPPED = [*(0x01..0x08), 0x0B, 0x0C, *(0x0E..0x1F)].freeze
  KEPT = [0x00, 0x7F, 0x85].freeze

  module_function

  def ch(codepoint) = [codepoint].pack("U")
end

RSpec.describe "spec 8.2.10 TOK-2 C0 strip" do
  it "strips exactly the 28" do
    expect(Strip8210::STRIPPED.size).to eq(28)
  end

  Strip8210::STRIPPED.each do |cp|
    it format("removes U+%04X rather than collapsing it", cp) do
      expect(Langsys::Html.canonical_token("A#{Strip8210.ch(cp)}long")).to eq("Along")
    end
  end

  Strip8210::KEPT.each do |cp|
    it format("keeps U+%04X", cp) do
      expect(Langsys::Html.canonical_token("A#{Strip8210.ch(cp)}long")).to eq("A#{Strip8210.ch(cp)}long")
    end
  end

  it "still collapses TAB, LF and CR to one space" do
    [0x09, 0x0A, 0x0D].each do |cp|
      expect(Langsys::Html.canonical_token("A#{Strip8210.ch(cp)}long")).to eq("A long")
    end
  end

  it "strips before it collapses, so a VT between spaces leaves one space" do
    expect(Langsys::Html.canonical_token("a #{Strip8210.ch(0x0B)} b")).to eq("a b")
  end

  it "strips a control that is the whole leading edge, then trims" do
    expect(Langsys::Html.canonical_token("#{Strip8210.ch(0x1C)} Hello")).to eq("Hello")
  end

  describe "the code-registered path (t)" do
    before do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("es-es", { "UI" => { "Save changes" => "Guardar cambios" } })
    end

    it "looks up a t() key with the control removed" do
      client = build_client(base_locale: "es-ES")
      expect(client.t("Save#{Strip8210.ch(0x1C)} changes", category: "UI")).to eq("Guardar cambios")
    end

    it "registers a t() miss with the control removed" do
      client = build_client(base_locale: "es-ES")
      client.t("New#{Strip8210.ch(0x0B)}phrase", category: "UI")
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Newphrase"])
    end

    it "registers a code-registered phrase list with the control removed" do
      stub = stub_request(:post, "https://api.test/api/translatable-items")
             .to_return(status: 200, body: '{"status":true}', headers: { "Content-Type" => "application/json" })
      client = build_client(base_locale: "es-ES")
      client.register_phrases([{ phrase: "Hi#{Strip8210.ch(0x1F)}there", category: "UI" }])
      expect(stub.with { |r| JSON.parse(r.body)["translatable_items"].first["phrase"] == "Hithere" })
        .to have_been_requested
    end
  end

  it "strips the interpolation template before rendering" do
    expect(Langsys::Interpolate.call("Hi#{Strip8210.ch(0x01)} {name}", { name: "Ana" }, "en")).to eq("Hi Ana")
  end
end
