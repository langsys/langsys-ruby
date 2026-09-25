# frozen_string_literal: true

require "spec_helper"
require "json"
require "nokogiri"

# Parse-model fixture vendored from langsys-php-sdk at blob a3b0cf8c (commit 5400248).
# Vendored from the COMMITTED blob, not a working copy: the file moved between two reads
# during this lane, and a vendored copy that no commit can reproduce is not a citation.
module ParseModel
  BLOB = "a3b0cf8c2277bb37e40e55511a59a678e351ea4b"
  PATH = File.expand_path("fixtures/parse-model-reference.json", __dir__)
  CASES = JSON.parse(File.read(PATH))["cases"]
  LIBXML2 = Nokogiri::VERSION_INFO.dig("libxml", "loaded")
end

RSpec.describe "spec 8.0.1 identity on every path" do
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

  describe "MARK-2/MARK-4 — a phrase-marked host is excised from the unit around it, on every path" do
    %w[data-ls-phrase data-langsys-phrase].each do |attr|
      it "excises a #{attr} host on the block path" do
        html = %(<span #{attr}="Welcome">Welcome</span> <em>friend</em>)
        expect(Langsys::Html.extract_phrases(html)).to eq(["friend"])
      end

      it "excises a #{attr} host through translate_content_block, and registers it on its own" do
        stub_authorize(key_type: "write", write_enabled: true)
        stub_translations("es-es", { "Home" => {} })
        client = build_client
        client.set_locale("es-ES")
        client.translate_content_block(%(<span #{attr}="Welcome">Welcome</span> <em>friend</em>), category: "Home")
        expect(client.pending_content_blocks).to be_empty
        expect(client.pending_phrases.map { |p| p["phrase"] }).to contain_exactly("friend", "Welcome")
      end
    end
  end

  describe "CONF-1 — the apply path skips exactly what the extract path skips" do
    let(:inner) { '<b>Welcome</b> <span data-ls-phrase="Welcome">Welcome</span> <em>friend</em>' }
    let(:translations) { { "Welcome" => "Bienvenido", "friend" => "amigo" } }

    it "does not rewrite a phrase-marked host whose text matches a sibling token, on the page path" do
      block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[Welcome friend])
      _, out = page_render("<p>#{inner}</p>", { Langsys::UNCATEGORIZED => { block_id => translations } })
      p_ = Nokogiri::HTML(out).at_css("p")
      expect(p_.at_css("b").text).to eq("Bienvenido")
      expect(p_.at_css("[data-ls-phrase]").text).to eq("Welcome")
    end

    it "does not rewrite it on the block path either" do
      block_id = Langsys.generate_custom_id("Home", %w[Welcome friend])
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("es-es", { "Home" => { block_id => translations } })
      client = build_client
      client.set_locale("es-ES")
      out = Nokogiri::HTML.fragment(client.translate_content_block(inner, category: "Home"))
      expect(out.at_css("b").text).to eq("Bienvenido")
      expect(out.at_css("[data-ls-phrase]").text).to eq("Welcome")
    end
  end

  describe "declaration, opt-out and identity on the content-block attribute" do
    %w[data-ls-contentblock data-langsys-contentblock].each do |attr|
      it "leaves a #{attr} identity value whole: no registration, no re-stamp" do
        client, out = page_render(%(<div #{attr}="deadbeef"><p>One</p><p>Two</p></div><p>Kept</p>))
        host = Nokogiri::HTML(out).at_css("div")
        expect(host[attr]).to eq("deadbeef")
        expect(host["data-ls-contentblock"]).to eq(attr == "data-ls-contentblock" ? "deadbeef" : nil)
        expect(queued_tokens(client)).to eq(["Kept"])
      end

      ["0", "false", " FALSE "].each do |value|
        it "walks #{attr}=#{value.inspect} as ordinary content" do
          client, = page_render(%(<div #{attr}="#{value}"><p>One</p><p>Two</p></div>))
          expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(%w[One Two])
          expect(client.pending_content_blocks).to be_empty
        end
      end

      it "treats the bare #{attr} as a declaration: one block" do
        client, = page_render(%(<div #{attr}><p>One</p><p>Two</p></div>))
        expect(client.pending_content_blocks.map { |b| b["phrases"] }).to eq([%w[One Two]])
        expect(client.pending_phrases).to be_empty
      end

      ["", "1", "true", "yes", " TRUE "].each do |value|
        it "treats #{attr}=#{value.inspect} as a declaration: one block" do
          client, = page_render(%(<div #{attr}="#{value}"><p>One</p><p>Two</p></div>))
          expect(client.pending_content_blocks.map { |b| b["phrases"] }).to eq([%w[One Two]])
          expect(client.pending_phrases).to be_empty
        end
      end
    end

    it "does not rewrite the text of an identity host" do
      _, out = page_render('<div data-ls-contentblock="deadbeef"><p>Hello</p></div>',
                           { Langsys::UNCATEGORIZED => { "Hello" => "Hola" } })
      expect(Nokogiri::HTML(out).at_css("div p").text).to eq("Hello")
    end
  end

  describe "stamp placement is not corrupted by the markup around it" do
    let(:block_id) { Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[Hello there]) }
    let(:titled_id) { Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[a>b Hello there]) }

    it "stamps a host whose double-quoted title contains >" do
      _, out = page_render('<p title="a>b">Hello <b>there</b></p>')
      host = Nokogiri::HTML(out).at_css("p")
      expect(host["title"]).to eq("a>b")
      expect(host["data-ls-contentblock"]).to eq(titled_id)
    end

    it "stamps a host whose single-quoted title contains >" do
      _, out = page_render("<p title='a>b'>Hello <b>there</b></p>")
      host = Nokogiri::HTML(out).at_css("p")
      expect(host["title"]).to eq("a>b")
      expect(host["data-ls-contentblock"]).to eq(titled_id)
    end

    it "stamps the host, not a leading comment containing markup" do
      _, out = page_render("<!-- a > b <p> --><p>Hello <b>there</b></p>")
      doc = Nokogiri::HTML(out)
      expect(doc.xpath("//comment()").size).to eq(1)
      expect(doc.at_css("p")["data-ls-contentblock"]).to eq(block_id)
    end

    it "stamps a single-phrase host whose inline child's title contains >" do
      _, out = page_render('<p><a href="/x" data-x="a>b">Hello</a></p>')
      host = Nokogiri::HTML(out).at_css("p")
      expect(host.at_css("a")["data-x"]).to eq("a>b")
      expect(host["data-ls-phrase"]).to eq("Hello")
    end
  end

  describe "page-path apply keeps inline wrappers" do
    it "keeps the <a> when a single phrase sits inside it" do
      _, out = page_render('<ul><li><a href="#">Label</a></li></ul>',
                           { Langsys::UNCATEGORIZED => { "Label" => "Etiqueta" } })
      a = Nokogiri::HTML(out).at_css("li a")
      expect(a).not_to be_nil
      expect(a["href"]).to eq("#")
      expect(a.text).to eq("Etiqueta")
    end

    it "keeps the <a> in a two-phrase block" do
      block_id = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, ["X:", "Label"])
      data = { Langsys::UNCATEGORIZED => { block_id => { "X:" => "Y:", "Label" => "Etiqueta" } } }
      _, out = page_render('<ul><li>X: <a href="#">Label</a></li></ul>', data)
      li = Nokogiri::HTML(out).at_css("li")
      expect(li.at_css("a")["href"]).to eq("#")
      expect(li.at_css("a").text).to eq("Etiqueta")
      expect(li.text).to include("Y:")
    end
  end

  describe "GATE-7 — every detection path feeds exactly one lane" do
    it "routes t(), translate_content_block and both page-path shapes into the one registration lane" do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", {})
      stub_request(:post, "https://api.test/api/translatable-items")
        .to_return(status: 200, body: JSON.generate({ "status" => true }),
                   headers: { "Content-Type" => "application/json" })
      other_lane = stub_request(:any, /hint|report|discover/)
      client = build_client
      client.t("Direct miss", category: "UI")
      client.translate_content_block("<p>Block <b>miss</b></p>", category: "UI")
      client.translate_page("<html><body><p>Page phrase miss</p><p>Page <b>block</b> miss</p></body></html>")

      expect(client.pending_phrases.map { |p| p["phrase"] }).to contain_exactly("Direct miss", "Page phrase miss")
      expect(client.pending_content_blocks.map do |b|
        b["phrases"]
      end).to contain_exactly(%w[Block miss], %w[Page block miss])
      client.flush_pending
      # Every detection path landed in the one lane: a single flush accepted all four items.
      block_ui = Langsys.generate_custom_id("UI", %w[Block miss])
      block_page = Langsys.generate_custom_id(Langsys::UNCATEGORIZED, %w[Page block miss])
      expect(client.registered?("UI", "Direct miss")).to be(true)
      expect(client.registered?(Langsys::UNCATEGORIZED, "Page phrase miss")).to be(true)
      expect(client.registered?("UI", block_ui)).to be(true)
      expect(client.registered?(Langsys::UNCATEGORIZED, block_page)).to be(true)
      expect(client.has_pending?).to be(false)
      expect(other_lane).not_to have_been_requested
    end
  end

  describe "SRV-5 — each child is captured once per subtree" do
    it "registers each miss in a depth-3 nested block exactly once" do
      html = "<div><section><article><p>Miss one <b>bold</b></p><p>Miss two</p></article></section></div>"
      client, = page_render(html)
      expect(queued_tokens(client).tally).to eq({ "Miss one" => 1, "bold" => 1, "Miss two" => 1 })
    end
  end

  measured_on = "Nokogiri #{Nokogiri::VERSION}, libxml2 #{ParseModel::LIBXML2}"
  describe "parser residuals independent of the strip ruling (#{measured_on})" do
    def dom(kind, html)
      kind == :fragment ? Nokogiri::HTML.fragment(html) : Nokogiri::HTML(html)
    end

    def cps(str) = str.to_s.each_char.map { |c| format("U+%04X", c.ord) }

    it "records the libxml2 these residuals were measured on, so a version bump forces a re-measure" do
      expect(ParseModel::LIBXML2).to start_with("2.13.")
    end

    %i[fragment document].each do |kind|
      it "#{kind}: turns a raw U+0000 in text into U+0020" do
        expect(cps(dom(kind, "<p>a#{[0].pack('U')}b</p>").at_css("p").text)).to eq(%w[U+0061 U+0020 U+0062])
      end

      it "#{kind}: drops &#x00; in text" do
        expect(cps(dom(kind, "<p>a&#x00;b</p>").at_css("p").text)).to eq(%w[U+0061 U+0062])
      end

      it "#{kind}: keeps a lone CR raw" do
        expect(cps(dom(kind, "<p>a#{[13].pack('U')}b</p>").at_css("p").text)).to eq(%w[U+0061 U+000D U+0062])
      end

      it "#{kind}: keeps CRLF raw" do
        expect(cps(dom(kind,
                       "<p>a#{[13, 10].pack('U*')}b</p>").at_css("p").text)).to eq(%w[U+0061 U+000D U+000A U+0062])
      end

      it "#{kind}: keeps raw C0 in an attribute value byte for byte" do
        html = %(<p title="a#{[0x1C].pack('U')}b#{[0x0B].pack('U')}c#{[0x01].pack('U')}d">x</p>)
        expect(cps(dom(kind, html).at_css("p")["title"])).to eq(%w[U+0061 U+001C U+0062 U+000B U+0063 U+0001 U+0064])
      end

      it "#{kind}: truncates an attribute value at &#x1C;" do
        expect(dom(kind, '<p title="a&#x1C;b">x</p>').at_css("p")["title"]).to eq("a")
      end

      it "#{kind}: does not truncate at a printable character reference (control)" do
        expect(dom(kind, '<p title="a&#x58;b">x</p>').at_css("p")["title"]).to eq("aXb")
      end
    end
  end

  describe "parse model on Nokogiri #{Nokogiri::VERSION} / libxml2 #{ParseModel::LIBXML2}" do
    it "is the exact parse-model blob vendored from langsys-php-sdk" do
      expect(`git hash-object #{Shellwords.escape(ParseModel::PATH)}`.strip).to eq(ParseModel::BLOB)
    end

    ParseModel::CASES.each do |c|
      it "#{c['id']}: block-path tokens equal libxml2's recorded tokens" do
        expect(Langsys::Html.extract_phrases(c["html"])).to eq(c["content_block"]["libxml2_tokens"])
      end
    end

    it "agrees with the JS family's token arrays on 5 of 7, the raw-text rows being the split" do
      agreeing = ParseModel::CASES.select { |c| Langsys::Html.extract_phrases(c["html"]) == c["content_block"]["js_family_tokens"] }
      expect(agreeing.map { |c| c["id"] }).to contain_exactly(
        "foster-stray-element", "foster-loose-text", "implied-close-p", "implied-close-li", "implied-close-option"
      )
    end
  end
end
