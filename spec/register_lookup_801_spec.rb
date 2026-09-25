# frozen_string_literal: true

require "spec_helper"
require "nokogiri"

# Register/lookup pairs on attribute paths, apply-path exclusion, and identity hosts nested
# inside a declared block. Every non-ASCII or control character is built from a code point.
module RegisterLookup801
  module_function

  def u(code_point) = [code_point].pack("U")

  # One authored value in three spellings. A register/lookup mismatch returns a plausible
  # miss, not an error, so each spelling is asserted on the lookup side, not only on capture.
  def spellings
    {
      "line break" => "A long#{u(0x0A)}   description",
      "doubled space" => "A long  description",
      "no-break space" => "A#{u(0xA0)}long description"
    }
  end
end

RSpec.describe "spec 8.0.1 register/lookup pairs and identity excision" do
  def page_render(html, data = {})
    stub_authorize(key_type: "write", write_enabled: true)
    stub_translations("es-es", data)
    client = build_client
    client.set_locale("es-ES")
    [client, client.translate_page("<html><body>#{html}</body></html>")]
  end

  describe "MARK-2 — an identity content-block host is excised on every path, nested included" do
    %w[data-ls-contentblock data-langsys-contentblock].each do |attr|
      it "excises a nested #{attr} identity host from the block path's tokens" do
        html = %(<b>Welcome</b> <div #{attr}="deadbeef"><span>Owned</span></div> <em>friend</em>)
        expect(Langsys::Html.extract_phrases(html)).to eq(%w[Welcome friend])
      end

      it "excises a nested #{attr} identity host from a declared block on the page path" do
        inner = %(<b>Welcome</b> <div #{attr}="deadbeef"><span>Owned</span></div> <em>friend</em>)
        client, out = page_render(%(<section data-ls-contentblock="1">#{inner}</section>))
        expect(client.pending_content_blocks.map { |b| b["phrases"] }).to eq([%w[Welcome friend]])
        expect(Nokogiri::HTML(out).at_css("div")[attr]).to eq("deadbeef")
      end

      it "does not rewrite a nested #{attr} identity host whose text matches a sibling token" do
        inner = %(<b>Owned</b> <div #{attr}="deadbeef"><span>Owned</span></div> <em>friend</em>)
        block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[Owned friend])
        data = { Langsys::UNCATEGORIZED => { block_id => { "Owned" => "Propio", "friend" => "amigo" } } }
        _, out = page_render(%(<section data-ls-contentblock="1">#{inner}</section>), data)
        doc = Nokogiri::HTML(out)
        expect(doc.at_css("b").text).to eq("Propio")
        expect(doc.at_css("div span").text).to eq("Owned")
      end
    end

    it "excises a nested DECLARATION too (MARK-4), and folds a nested opt-out (control)" do
      declared = %(<b>Welcome</b> <div data-ls-contentblock="1"><span>Inner</span></div> <em>friend</em>)
      opted_out = %(<b>Welcome</b> <div data-ls-contentblock="0"><span>Folded</span></div> <em>friend</em>)
      expect(Langsys::Html.extract_phrases(declared)).to eq(%w[Welcome friend])
      expect(Langsys::Html.extract_phrases(opted_out)).to eq(%w[Welcome Folded friend])
    end
  end

  describe "TOK-4 — attribute register/lookup pairs survive whitespace variants" do
    it "registers the canonical form for every spelling (the register half)" do
      RegisterLookup801.spellings.each_value do |alt|
        expect(Langsys::Html.extract_phrases(%(<img alt="#{alt}">))).to eq(["A long description"])
      end
    end

    RegisterLookup801.spellings.each do |label, value|
      it "translates an alt spelled with a #{label} inside a block, on the page path" do
        block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, ["Look", "A long description", "here"])
        data = { Langsys::UNCATEGORIZED => { block_id => {
          "Look" => "Mira", "A long description" => "Una descripcion larga", "here" => "aqui"
        } } }
        _, out = page_render(%(<p>Look <img alt="#{value}"> here</p>), data)
        expect(Nokogiri::HTML(out).at_css("img")["alt"]).to eq("Una descripcion larga")
      end

      it "translates a placeholder spelled with a #{label} through translate_content_block" do
        block_id = Langsys.generate_custom_id("Form", ["Name", "A long description"])
        stub_authorize(key_type: "write", write_enabled: true)
        stub_translations("es-es",
                          { "Form" => { block_id => { "Name" => "Nombre",
                                                      "A long description" => "Una descripcion larga" } } })
        client = build_client
        client.set_locale("es-ES")
        out = client.translate_content_block(%(<label>Name</label> <input placeholder="#{value}">), category: "Form")
        expect(Nokogiri::HTML.fragment(out).at_css("input")["placeholder"]).to eq("Una descripcion larga")
      end
    end
  end

  describe "CONF-1 — apply skips an excluded subtree whose text matches a sibling token" do
    it "does not rewrite <math> text that reads like a translated token" do
      block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[Area units])
      data = { Langsys::UNCATEGORIZED => { block_id => { "Area" => "Superficie", "units" => "unidades" } } }
      _, out = page_render("<p>Area <math><mi>Area</mi></math> units</p>", data)
      p_ = Nokogiri::HTML(out).at_css("p")
      expect(p_.at_css("mi").text).to eq("Area")
      expect(p_.text).to include("Superficie")
    end
  end
end
