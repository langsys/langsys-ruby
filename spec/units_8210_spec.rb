# frozen_string_literal: true

require "spec_helper"
require "nokogiri"

# Spec 8.2.10/8.2.11: TOK-6 (the unit and its shape), MARK-2 (a marked host that misses
# registers whole), MARK-3 (the content-block marker's three meanings), MARK-4 (a marked host
# inside a walked unit is excised) and GATE-10's producing half, on every path this SDK has.
RSpec.describe "spec 8.2.10 units and markers" do
  def page(html, data = {}, locale: "es-ES", base: "en-us")
    stub_request(:get, "https://api.test/api/authorize-project/proj-1")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate(authorize_body(key_type: "write", write_enabled: true)
                                       .tap { |b| b["data"]["base_locale"] = base }))
    stub_translations(Langsys::Locale.normalize_locale(locale), data)
    client = build_client
    client.set_locale(locale)
    [client, client.translate_page("<html><body>#{html}</body></html>")]
  end

  def block(html, data = {})
    stub_authorize(key_type: "write", write_enabled: true)
    stub_translations("es-es", data)
    client = build_client
    client.set_locale("es-ES")
    [client, client.translate_content_block(html, category: "UI")]
  end

  def phrases(client) = client.pending_phrases.map { |p| p["phrase"] }
  def blocks(client) = client.pending_content_blocks.map { |b| b["phrases"] }
  def id(tokens, category = Langsys::UNCATEGORIZED) = Langsys.generate_custom_id(category, tokens)

  describe "TOK-6 — a unit is a phrase only when its one token is its one text node" do
    {
      "<p>Hello</p>" => [["Hello"], []],
      '<p title="Tooltip">Hello</p>' => [[], [%w[Tooltip Hello]]],
      '<img alt="Logo">' => [[], [%w[Logo]]],
      "<p><svg><text>Label</text><path/></svg></p>" => [["Label"], []],
      "<p>Hello <b>bold</b></p>" => [[], [%w[Hello bold]]],
      '<button data-confirm="Are you sure?">Go</button>' => [[], [["Are you sure?", "Go"]]],
      '<a title="Home page">Home</a>' => [[], [["Home page", "Home"]]],
      "<span>Loose inline</span>" => [["Loose inline"], []]
    }.each do |html, (want_phrases, want_blocks)|
      it "registers #{html} on the page path as #{want_phrases.empty? ? 'a block' : 'a phrase'}" do
        client, = page(html)
        expect(phrases(client)).to eq(want_phrases)
        expect(blocks(client)).to eq(want_blocks)
      end

      it "registers #{html} through translate_content_block the same way" do
        client, = block(html)
        expect(phrases(client)).to eq(want_phrases)
        expect(blocks(client)).to eq(want_blocks)
      end
    end

    it "translates a leaf's own attribute and its text as one block" do
      data = { Langsys::UNCATEGORIZED => { id(%w[Tooltip Hello]) => { "Tooltip" => "Ayuda", "Hello" => "Hola" } } }
      _, out = page('<p title="Tooltip">Hello</p>', data)
      p_el = Nokogiri::HTML(out).at_css("p")
      expect([p_el["title"], p_el.text]).to eq(%w[Ayuda Hola])
    end

    it "translates a top-level img's alt" do
      data = { Langsys::UNCATEGORIZED => { id(%w[Logo]) => { "Logo" => "Logotipo" } } }
      _, out = page('<img alt="Logo">', data)
      expect(Nokogiri::HTML(out).at_css("img")["alt"]).to eq("Logotipo")
    end

    it "translates an svg label in place and keeps its path" do
      _, out = page("<p><svg><text>Label</text><path d=\"M0\"/></svg></p>",
                    { Langsys::UNCATEGORIZED => { "Label" => "Etiqueta" } })
      doc = Nokogiri::HTML(out)
      expect([doc.at_css("text").text, doc.at_css("path")["d"]]).to eq(%w[Etiqueta M0])
    end

    it "registers content that re-tokenizes to the block's own tokens, attribute included" do
      client, = page('<p title="Tooltip">Hello</p>')
      queued = client.pending_content_blocks.first
      expect(Langsys::Html.extract_phrases(queued["content"])).to eq(queued["phrases"])
    end

    it "keeps a declared block a block even when it holds one text node" do
      client, = page("<p data-ls-contentblock>Hello</p>")
      expect([phrases(client), blocks(client)]).to eq([[], [%w[Hello]]])
    end
  end

  describe "MARK-3 — the content-block marker's three meanings" do
    %w[data-ls-contentblock data-langsys-contentblock].each do |attr|
      ["", "true", "1", "YES", " yes "].each do |value|
        it "#{attr}=#{value.inspect} declares one block, with the same id every time" do
          client, = page(%(<section #{attr}="#{value}"><b>Welcome</b> <em>friend</em></section>))
          expect(client.pending_content_blocks.map { |b| b["custom_id"] }).to eq([id(%w[Welcome friend])])
        end
      end

      it "a bare #{attr} declares a block" do
        client, = page(%(<section #{attr}><b>Welcome</b> <em>friend</em></section>))
        expect(blocks(client)).to eq([%w[Welcome friend]])
      end

      %w[0 false FALSE].each do |value|
        it "#{attr}=#{value.inspect} opts out: the content registers as its units would" do
          client, out = page(%(<div #{attr}="#{value}"><p>One</p><p>Two <b>x</b></p></div>))
          expect([phrases(client), blocks(client)]).to eq([["One"], [%w[Two x]]])
          expect(Nokogiri::HTML(out).at_css("div")[attr]).to eq(value)
        end
      end

      it "never overwrites an opt-out #{attr} on a leaf it registers as a block" do
        client, out = page(%(<p #{attr}="0">Two <b>x</b></p>))
        expect(blocks(client)).to eq([%w[Two x]])
        expect(Nokogiri::HTML(out).at_css("p")[attr]).to eq("0")
      end

      %w[abc123 on off no].each do |value|
        it "#{attr}=#{value.inspect} is an identity: nothing registered, catalog entry rendered" do
          data = { Langsys::UNCATEGORIZED => { value => { "Welcome" => "Bienvenido" } } }
          client, out = page(%(<section #{attr}="#{value}"><b>Welcome</b></section>), data)
          expect([phrases(client), blocks(client)]).to eq([[], []])
          expect(Nokogiri::HTML(out).at_css("b").text).to eq("Bienvenido")
          expect(Nokogiri::HTML(out).at_css("section")[attr]).to eq(value)
        end

        it "#{attr}=#{value.inspect} with no catalog entry renders its source" do
          client, out = page(%(<section #{attr}="#{value}"><b>Welcome</b></section>))
          expect([phrases(client), blocks(client)]).to eq([[], []])
          expect(Nokogiri::HTML(out).at_css("b").text).to eq("Welcome")
        end
      end
    end
  end

  describe "MARK-4 — a marked host inside a walked unit is excised" do
    let(:markup) do
      "<div><p>Outer <b>text</b> <span data-ls-contentblock><i>Inner</i> <u>block</u></span> " \
        "<em data-ls-phrase>Kept whole</em></p></div>"
    end

    it "keeps both nested hosts' words out of the outer unit, and registers each once on its own" do
      client, = page(markup)
      expect(blocks(client)).to contain_exactly(%w[Outer text], %w[Inner block])
      expect(phrases(client)).to eq(["Kept whole"])
    end

    it "excises them on the block path too" do
      client, = block(markup)
      expect(blocks(client)).to contain_exactly(%w[Outer text], %w[Inner block])
      expect(phrases(client)).to eq(["Kept whole"])
    end

    it "folds a nested block marked false into the outer tokens (control)" do
      client, = page('<div><p>Outer <span data-ls-contentblock="false"><i>Inner</i></span></p></div>')
      expect(blocks(client)).to eq([%w[Outer Inner]])
    end
  end

  describe "MARK-2 — a marked phrase host that misses registers whole" do
    %w[data-ls-phrase data-langsys-phrase].each do |attr|
      it "registers #{attr} with inline markup as one tokenized phrase" do
        client, = page(%(<p #{attr}>Based on {n} <strong>reviews</strong></p>))
        expect(phrases(client)).to eq(["Based on {n} {m0o}reviews{m0c}"])
        expect(blocks(client)).to eq([])
      end

      it "renders a #{attr} translation that moves the markup, keeping the element" do
        data = { Langsys::UNCATEGORIZED => { "Based on {n} {m0o}reviews{m0c}" => "{m0o}Reseñas{m0c}: {n}" } }
        _, out = page(%(<p #{attr}>Based on {n} <strong class="x">reviews</strong></p>), data)
        para = Nokogiri::HTML(out).at_css("p")
        expect(para.inner_html).to eq('<strong class="x">Reseñas</strong>: {n}')
      end
    end

    it "opts out with data-ls-phrase=\"false\"" do
      client, = page('<p data-ls-phrase="false">Hello <b>there</b></p>')
      expect(blocks(client)).to eq([%w[Hello there]])
    end

    it "registers a phrase host nested in a declared block whole, on the declared-block path" do
      client, = page("<section data-ls-contentblock><b>Hi</b> " \
                     "<span data-langsys-phrase>Keep <i>me</i></span></section>")
      expect(blocks(client)).to eq([%w[Hi]])
      expect(phrases(client)).to eq(["Keep {m0o}me{m0c}"])
    end
  end

  describe "GATE-10 — a render in a non-base locale marks its root resolved" do
    it "marks the root data-ls-resolved with the render locale" do
      _, out = page("<p>Hello</p>", locale: "es-ES", base: "en-us")
      expect(Nokogiri::HTML(out).at_css("html")["data-ls-resolved"]).to eq("es-es")
    end

    it "does not mark a base-locale render" do
      _, out = page("<p>Hello</p>", locale: "en-US", base: "en-us")
      expect(Nokogiri::HTML(out).at_css("html")["data-ls-resolved"]).to be_nil
    end

    it "records no miss inside a resolved subtree, and does under an opt-out" do
      client, = page("<div data-langsys-resolved><p>Already out</p></div>" \
                     '<div data-ls-resolved="false"><p>Source</p></div>')
      expect(phrases(client)).to eq(["Source"])
    end
  end
end
