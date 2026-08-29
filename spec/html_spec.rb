# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Html do
  describe ".extract_phrases" do
    it "collects text, attributes, and skips translate=no in order" do
      html = '<div><h3>Welcome</h3><p title="Tip">Browse <strong>now</strong></p>' \
             '<span translate="no">Kangen</span></div>'
      expect(described_class.extract_phrases(html)).to eq(%w[Welcome Tip Browse now])
    end

    it "collects submit/button values" do
      html = '<form><input type="submit" value="Send" /><button value="Go">x</button></form>'
      expect(described_class.extract_phrases(html)).to include("Send", "Go")
    end
  end

  describe ".apply_block_translations" do
    it "substitutes text and attributes, preserving whitespace and translate=no" do
      html = '<div><h3>Welcome</h3><p title="Tip">Browse <strong>now</strong></p>' \
             '<span translate="no">Kangen</span></div>'
      translations = { "Welcome" => "Bienvenido", "Tip" => "Consejo", "Browse" => "Explorar", "now" => "ahora" }
      out = described_class.apply_block_translations(html, translations)
      expect(out).to include("Bienvenido")
      expect(out).to include('title="Consejo"')
      expect(out).to include("Explorar <strong>ahora</strong>")
      expect(out).to include('translate="no">Kangen')
    end
  end
end

RSpec.describe "Langsys::Client HTML translation" do
  def stub_translations(locale, data)
    stub_request(:get, "https://api.test/api/translations")
      .with(query: { "project_id" => "proj-1", "locale" => locale, "format" => "flat" })
      .to_return(status: 200, body: JSON.generate(catalog_body(data)),
                 headers: { "Content-Type" => "application/json" })
  end

  describe "#translate_content_block" do
    it "applies a stored content block" do
      custom_id = Langsys.generate_custom_id("Home", ["Welcome"])
      stub_translations("es-es", { "Home" => { custom_id => { "Welcome" => "Bienvenido" } } })
      client = build_client
      client.set_locale("es-ES")
      expect(client.translate_content_block("<h3>Welcome</h3>", category: "Home")).to eq("<h3>Bienvenido</h3>")
    end

    it "returns the original and queues an unknown block" do
      stub_translations("es-es", { "Home" => {} })
      client = build_client
      client.set_locale("es-ES")
      out = client.translate_content_block("<h3>Welcome</h3>", category: "Home")
      expect(out).to eq("<h3>Welcome</h3>")
      expect(client.has_pending?).to be true
      expect(client.pending_content_blocks.first["phrases"]).to eq(["Welcome"])
    end
  end

  describe "#translate_page" do
    it "translates the title, simple blocks, and sets html lang" do
      stub_translations("es-es", { Langsys::UNCATEGORIZED => { "Welcome" => "Bienvenido", "Hello" => "Hola" } })
      client = build_client
      client.set_locale("es-ES")
      page = "<html><head><title>Welcome</title></head><body><h1>Hello</h1></body></html>"
      out = client.translate_page(page)
      expect(out).to include("<title>Bienvenido</title>")
      expect(out).to include("<h1>Hola</h1>")
      expect(out).to include('lang="es-ES"')
    end

    it "honors data-langsys-category and translate=no" do
      cid = Langsys.generate_custom_id("News", ["Read more", "today"])
      stub_translations("es-es", {
                          "News" => { cid => { "Read more" => "Leer más", "today" => "hoy" } }
                        })
      client = build_client
      client.set_locale("es-ES")
      page = '<html><body><div data-langsys-category="News"><p>Read more <strong>today</strong></p></div>' \
             '<p translate="no">Kangen</p></body></html>'
      out = client.translate_page(page)
      expect(out).to include("Leer más")
      expect(out).to include("hoy")
      expect(out).to include('translate="no">Kangen')
    end
  end
end
