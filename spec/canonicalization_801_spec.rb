# frozen_string_literal: true

require "spec_helper"

# Spec 8.0.1 canonicalization: TOK-1, TOK-2 and TOK-5, on every path the SDK exposes.
#
# Every non-ASCII and control character in this file is BUILT from an integer code point.
# A literal U+00A0 or U+FEFF renders identically to the text beside it, so a reviewer
# cannot see what a test pins and a whitespace tidy silently turns it into an assertion
# about ordinary spaces.
module Canon801
  module_function

  def u(code_point) = [code_point].pack("U")

  # TOK-2's enumerated collapse set. U+000B and U+000C are members too, but how Ruby's
  # class treats them is held pending the operator's ruling on stripping C0 controls,
  # so they are deliberately not asserted here.
  MEMBERS = [0x09, 0x0A, 0x0D, 0x20, 0xA0, 0x1680, *(0x2000..0x200A).to_a,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF].freeze

  # Named by TOK-2 as NOT members: left exactly as authored.
  NON_MEMBERS = [0x0085, 0x180E, 0x200B, 0x2060].freeze
end

RSpec.describe "spec 8.0.1 canonicalization" do
  def page_render(html, data = {})
    stub_authorize(key_type: "write", write_enabled: true)
    stub_translations("es-es", data)
    client = build_client
    client.set_locale("es-ES")
    [client, client.translate_page("<html><body>#{html}</body></html>")]
  end

  def queued_tokens(client)
    client.pending_phrases.map { |p| p["phrase"] } + client.pending_content_blocks.flat_map { |b| b["phrases"] }
  end

  describe "TOK-2 — collapse membership, asserted on the collapse function directly" do
    # Directly, not only through Nokogiri: where the parser has already removed a
    # character, a DOM-level test that it is not collapsed passes for the wrong reason.
    Canon801::MEMBERS.each do |cp|
      it format("collapses U+%04X like a space", cp) do
        expect(Langsys::Html.normalize_whitespace("A#{Canon801.u(cp)}long")).to eq("A long")
      end
    end

    Canon801::NON_MEMBERS.each do |cp|
      it format("leaves U+%04X in place", cp) do
        input = "A#{Canon801.u(cp)}long"
        expect(Langsys::Html.normalize_whitespace(input)).to eq(input)
      end
    end

    it "trims by the set rather than by String#strip, which also removes U+0000" do
      nul = Canon801.u(0x00)
      expect(Langsys::Html.normalize_whitespace("#{nul}a#{nul}")).to eq("#{nul}a#{nul}")
    end

    it "trims a leading and trailing U+FEFF, which String#strip does not" do
      feff = Canon801.u(0xFEFF)
      expect(Langsys::Html.normalize_whitespace("#{feff}a#{feff}")).to eq("a")
    end

    it "gives the lead/trail re-emit detector the same set" do
      feff = Canon801.u(0xFEFF)
      out = Langsys::Html.apply_block_translations("<p>#{feff}Buy now#{feff}</p>", { "Buy now" => "Comprar" })
      expect(out).to eq("<p> Comprar </p>")
    end
  end

  describe "TOK-1 — math excluded, svg text translated, on every path" do
    it "produces exactly one phrase from script, style, noscript and math plus ordinary markup" do
      html = "<script>Same sentence</script><style>Same sentence</style>" \
             "<noscript>Same sentence</noscript><math><mi>Same sentence</mi></math><p>Same sentence</p>"
      expect(Langsys::Html.extract_phrases(html)).to eq(["Same sentence"])
    end

    it "excludes math on the block path" do
      html = "<p>Area <math><mi>x</mi><mo>+</mo><mn>2</mn></math> units</p>"
      expect(Langsys::Html.extract_phrases(html)).to eq(%w[Area units])
    end

    it "excludes inline math on the page path" do
      client, = page_render("<p>Area <math><mi>x</mi><mo>+</mo><mn>2</mn></math> units</p>")
      expect(queued_tokens(client)).to eq(%w[Area units])
    end

    it "tokenizes a standalone svg directly under <body> on the page path" do
      client, = page_render('<svg><text>SvgLabel</text><path d="M0 0L1 1"/></svg>')
      expect(queued_tokens(client)).to eq(["SvgLabel"])
    end

    it "never lets an inline svg cost its block the block's own text, on the page path" do
      client, = page_render('<p>Click <svg><text>go</text><path d="M0 0L1 1"/></svg> to continue</p>')
      expect(queued_tokens(client)).to eq(["Click", "go", "to continue"])
    end

    it "translates a standalone svg's text in place and keeps its <path>" do
      # Both a phrase key and a block key are supplied, so this pins the rendered
      # behaviour the spec states and not which registration shape reaches it.
      block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, ["SvgLabel"])
      data = { Langsys::UNCATEGORIZED => { "SvgLabel" => "EtiquetaSvg", block_id => { "SvgLabel" => "EtiquetaSvg" } } }
      _, out = page_render('<svg><text>SvgLabel</text><path d="M0 0L1 1"/></svg>', data)
      svg = Nokogiri::HTML(out).at_css("svg")
      expect(svg.at_css("text").text).to eq("EtiquetaSvg")
      expect(svg.at_css("path")["d"]).to eq("M0 0L1 1")
    end

    it "translates an inline svg's text in place and keeps its <path>" do
      block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, ["Click", "go", "to continue"])
      data = { Langsys::UNCATEGORIZED => { block_id => { "Click" => "Pulsa", "go" => "ir", "to continue" => "para seguir" } } }
      _, out = page_render('<p>Click <svg><text>go</text><path d="M0 0L1 1"/></svg> to continue</p>', data)
      p_ = Nokogiri::HTML(out).at_css("p")
      expect(p_.at_css("text").text).to eq("ir")
      expect(p_.at_css("path")["d"]).to eq("M0 0L1 1")
      expect(p_.text).to include("Pulsa").and include("para seguir")
    end
  end

  describe "TOK-5 — %name% in captured markup normalises to {name} before the id" do
    it "tokenizes captured %name% as {name}" do
      expect(Langsys::Html.extract_phrases("<p>Hello %name%</p>")).to eq(["Hello {name}"])
    end

    it "gives %name% markup the same id as the brace-authored form" do
      percent = Langsys::Html.extract_phrases("<p>Hello %name%</p>")
      brace = Langsys::Html.extract_phrases("<p>Hello {name}</p>")
      expect(Langsys.generate_custom_id("UI", percent)).to eq(Langsys.generate_custom_id("UI", brace))
    end

    it "normalises inside an attribute token too" do
      expect(Langsys::Html.extract_phrases('<img alt="Hi %name%">')).to eq(["Hi {name}"])
    end

    it "normalises on the page path" do
      client, = page_render("<p>Hello %name%</p>")
      expect(queued_tokens(client)).to eq(["Hello {name}"])
    end

    it "finds a {name} translation for %name% markup on the page path (register/lookup pair)" do
      _, out = page_render("<p>Hello %name%</p>", { Langsys::UNCATEGORIZED => { "Hello {name}" => "Hola {name}" } })
      expect(out).to include("Hola")
    end

    it "finds it on the block path too" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("es-es", { "UI" => { "Hello {name}" => "Hola {name}" } })
      client = build_client
      client.set_locale("es-ES")
      expect(client.translate_content_block("<p>Hello %name%</p>", category: "UI")).to include("Hola")
    end

    it "leaves percent signs in prose alone when nothing between them is an identifier" do
      expect(Langsys::Html.extract_phrases("<p>50% off, 20% more</p>")).to eq(["50% off, 20% more"])
    end

    it "matches the TS capture pattern exactly: an identifier between two signs normalises" do
      # The JS core's normalizeMarkupPlaceholders is /%([A-Za-z_][A-Za-z0-9_]*)%/g and is
      # unconditional at capture, so this span becomes a placeholder there too.
      expect(Langsys::Html.extract_phrases("<p>50%off20% today</p>")).to eq(["50{off20} today"])
    end

    it "does not substitute a dotted key at render time (identifier pattern only)" do
      expect(Langsys::Interpolate.call("Hi %a.b%", { "a.b" => "X" }, "en-US")).to eq("Hi %a.b%")
    end
  end
end
