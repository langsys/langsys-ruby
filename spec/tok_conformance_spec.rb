# frozen_string_literal: true

require "spec_helper"

# Conformance specs for the tokenizer rules (TOK-1..TOK-5), driven by the shared
# canonicalization fixture rather than by values re-typed here.
#
# Namespaced in a module: constants assigned inside a describe block bind on Object and
# will silently rebind a same-named constant in another spec file. That is this repo's own
# find — it happened, and it broke the CID suite's integrity assertions while presenting
# as a fixture problem.
module CanonFixture
  BLOB = "34034931872b93e761faea49fb040f3fd8a6b9f5"
  PATH = File.expand_path("fixtures/canonicalization-reference.json", __dir__)
  CASES = begin
    parsed = JSON.parse(File.read(PATH))
    parsed["cases"] || parsed["rows"] || parsed
  end

  module_function

  def codepoints(str) = str.each_char.map { |c| format("U+%04X", c.ord) }.join(" ")
end

RSpec.describe "TOK conformance" do
  describe "the shared canonicalization fixture" do
    it "is the exact blob it was vendored at" do
      # langsys-js-typescript tests/fixtures/canonicalization-reference.json, blob 34034931 (32 rows).
      blob = `git hash-object #{Shellwords.escape(CanonFixture::PATH)}`.strip
      expect(blob).to eq(CanonFixture::BLOB)
    end

    it "carries codepoints for every row, so nothing here is re-typed from a glyph" do
      expect(CanonFixture::CASES).to all(include("html_codepoints", "expected_tokens_codepoints"))
    end

    CanonFixture::CASES.each do |row|
      context "row #{row['id']}" do
        it "tokenizes to the shared expectation" do
          expect(Langsys::Html.extract_phrases(row["html"])).to eq(row["expected_tokens"]),
                                                                "codepoints: #{CanonFixture.codepoints(row['html'])}"
        end

        it "mints the shared custom_id" do
          tokens = Langsys::Html.extract_phrases(row["html"])
          expect(Langsys.generate_custom_id(row["category"], tokens)).to eq(row["expected_custom_id"])
        end
      end
    end
  end

  # The fixture rows are the cross-SDK contract; these are the spec's own stated tests,
  # which the fixture does not carry a row for in every case.
  describe "TOK-1 — script, style, template and noscript are not tokenized" do
    it "produces exactly one phrase, the ordinary one" do
      # The ordinary-markup control is the whole test: without a phrase that must
      # survive, an implementation that tokenizes nothing at all passes.
      html = "<script>Same sentence</script><style>Same sentence</style>" \
             "<template>Same sentence</template><noscript>Same sentence</noscript>" \
             "<p>Same sentence</p>"
      expect(Langsys::Html.extract_phrases(html)).to eq(["Same sentence"])
    end

    %w[script style template noscript].each do |tag|
      it "emits nothing from <#{tag}> while keeping its sibling" do
        html = "<#{tag}>Excluded text</#{tag}><p>Kept</p>"
        expect(Langsys::Html.extract_phrases(html)).to eq(["Kept"])
      end
    end

    it "excludes by element name, not by how the parser happens to model the children" do
      # script and style passed before this rule was implemented only because Nokogiri
      # models their children as CDATA and the walker tested `text?`. That is libxml2's
      # modelling, not an exclusion — swap the parser and the exclusion disappears with it.
      frag = Langsys::Html.parse_fragment("<script>x</script><style>x</style>")
      expect(frag.children.map(&:name)).to eq(%w[script style])
      expect(Langsys::Html.excluded_from_tokenizing?("script")).to be(true)
      expect(Langsys::Html.excluded_from_tokenizing?("style")).to be(true)
    end
  end

  describe "TOK-2 — U+00A0 collapses like any other whitespace" do
    # Written as escapes, never literals: a literal renders identically to the spaces
    # beside it, so a reviewer cannot see what the test pins and anyone tidying
    # whitespace turns it into an assertion about ordinary spaces that still passes.
    it "collapses an internal U+00A0 to the same token as U+0020" do
      nbsp = Langsys::Html.extract_phrases("<p>Buy\u00A0now</p>")
      plain = Langsys::Html.extract_phrases("<p>Buy\u0020now</p>")
      expect(nbsp).to eq(plain)
      expect(Langsys.generate_custom_id("UI", nbsp)).to eq(Langsys.generate_custom_id("UI", plain))
    end

    it "strips a LEADING and TRAILING U+00A0, which a collapse-only fix leaves behind" do
      # This is the vector that tells a finished implementation from a half-finished one:
      # fixing the collapse alone passes the internal pair and still retains these.
      tokens = Langsys::Html.extract_phrases("<p>\u00A0Buy\u0020now\u00A0</p>")
      expect(tokens).to eq(["Buy now"])
      expect(CanonFixture.codepoints(tokens.first)).not_to include("U+00A0")
    end

    it "produces NO token for a whitespace-only U+00A0 node" do
      # A token COUNT divergence, not a value one: a block's id derives from its phrases
      # in order, so this moves the id of every block containing such a node — including
      # blocks whose visible text is identical.
      expect(Langsys::Html.extract_phrases("<p>\u00A0</p>")).to be_empty
    end

    it "produces NO token for U+2028 / U+2029-only nodes either" do
      expect(Langsys::Html.extract_phrases("<p>\u2028</p>")).to be_empty
      expect(Langsys::Html.extract_phrases("<p>\u2029</p>")).to be_empty
    end

    it "preserves a U+00A0 lead/trail as a space when re-emitting a translation" do
      # The lead/trail detector decides whether the translated text keeps the padding the
      # source node had. It is a separate site from the collapse, and an ASCII-only test
      # here silently reflows text whose padding happens to be a no-break space: the
      # token normalises to "Buy now", the translation goes back without its leading
      # space, and the sentence closes up against whatever precedes it.
      nbsp = Langsys::Html.apply_block_translations("<p>\u00A0Buy\u0020now\u00A0</p>",
                                                    { "Buy now" => "Comprar ahora" })
      plain = Langsys::Html.apply_block_translations("<p>\u0020Buy\u0020now\u0020</p>",
                                                     { "Buy now" => "Comprar ahora" })
      expect(nbsp).to eq(plain)
      expect(nbsp).to eq("<p> Comprar ahora </p>")
    end

    it "normalises a <title> rather than trimming it raw" do
      # A token path that trims without collapsing — the kind TOK-2 warns the collapse fix
      # does not reach. A title padded with U+00A0 would otherwise mint a phrase no other
      # SDK could produce.
      client = build_client
      stub_authorize
      stub_translations("es-es", { Langsys::UNCATEGORIZED => { "Pricing" => "Precios" } })
      client.set_locale("es-ES")
      out = client.translate_page("<html><head><title>\u00A0Pricing\u00A0</title></head><body></body></html>")
      expect(out).to include("<title>Precios</title>")
    end

    it "keeps two ids for text that genuinely differs (control)" do
      a = Langsys::Html.extract_phrases("<p>Buy\u0020now</p>")
      b = Langsys::Html.extract_phrases("<p>Buy\u0020later</p>")
      expect(Langsys.generate_custom_id("UI", a)).not_to eq(Langsys.generate_custom_id("UI", b))
    end
  end

  describe "TOK-3 — the twenty-seven attributes, in this order" do
    it "produces three phrases in list order and none from unlisted attributes" do
      html = '<img data-tooltip="Third" alt="First" title="Second" src="x.png" data-foo="Ignored">'
      expect(Langsys::Html.extract_phrases(html)).to eq(%w[First Second Third])
    end

    it "carries exactly the twenty-seven, in the normative order" do
      # Order is normative: where an element carries several, the order decides the
      # sequence phrases are produced in, and a block's id derives from its phrases in
      # order. A different order agrees on every single-attribute element and diverges on
      # exactly the ones hardest to notice.
      expected = %w[
        placeholder alt title label
        aria-label aria-placeholder aria-description aria-valuetext aria-roledescription
        data-error data-error-message data-validation-message data-invalid-message
        data-required-message data-pattern-message data-confirm data-tooltip
        data-title data-content data-original-title data-bs-title data-bs-content
        data-loading-text data-success-message data-warning-message data-empty-message
        data-placeholder
      ]
      expect(expected.size).to eq(27)
      expect(Langsys::Html::DEFAULT_TRANSLATABLE_ATTRIBUTES).to eq(expected)
    end
  end

  describe "TOK-4 — attribute values collapse internal whitespace exactly as text nodes do" do
    it "gives the same id to the same string in a text node and in a title" do
      text = Langsys::Html.extract_phrases("<p>Buy\u0020\u0020\u0020now</p>")
      attr = Langsys::Html.extract_phrases("<span title=\"Buy\u0020\u0020\u0020now\">x</span>")
      expect(attr.first).to eq(text.first)
    end

    it "collapses U+00A0 inside an attribute value too" do
      expect(Langsys::Html.extract_phrases("<img alt=\"A\u00A0long\u0020\u0020\u0020description\">"))
        .to eq(["A long description"])
    end
  end

  describe "TOK-5 — {name} is the placeholder form; %name% is accepted as its escape" do
    it "interpolates both forms to the same output" do
      braces = Langsys::Interpolate.call("Hello, {name}!", { name: "Sarah" }, "en-US")
      percent = Langsys::Interpolate.call("Hello, %name%!", { name: "Sarah" }, "en-US")
      expect(percent).to eq(braces)
      expect(percent).to eq("Hello, Sarah!")
    end

    it "leaves an unrecognised form literal rather than silently dropping it" do
      expect(Langsys::Interpolate.call("Hello, [name]!", { name: "Sarah" }, "en-US"))
        .to eq("Hello, [name]!")
    end

    it "leaves a %name% whose argument is missing exactly as authored" do
      # Not rewritten into `{name}`. The escape is only substituted when the argument is
      # actually supplied, because ordinary prose is full of percent signs and a greedy
      # rule turns "50%off20%" into a slot. The gap stays visible either way.
      expect(Langsys::Interpolate.call("Hello, %name%!", {}, "en-US")).to eq("Hello, %name%!")
    end

    it "does not turn ordinary percentages into slots" do
      # A single assertion, not an `.or` chain: the alternation's second branch was
      # unreachable, and a matcher that cannot fail on one side is not a check.
      #
      # Measured rather than assumed, and the measurement corrected me: the span between
      # the signs here is `off20`, not `off`, so supplying an `off` argument changes
      # nothing. That is the substitution being narrow in the direction that matters —
      # prose survives untouched.
      expect(Langsys::Interpolate.call("50%off20% today", { off: "X" }, "en-US"))
        .to eq("50%off20% today")
    end

    it "substitutes the escape when the span between the signs IS an argument (control)" do
      # Without this, "prose is left alone" is indistinguishable from an escape that never
      # fires at all.
      expect(Langsys::Interpolate.call("50%off20% today", { "off20" => "X" }, "en-US"))
        .to eq("50X today")
    end

    it "leaves a percentage alone when nothing between the signs is an argument" do
      expect(Langsys::Interpolate.call("50% off, 20% more", { name: "Sarah" }, "en-US"))
        .to eq("50% off, 20% more")
    end

    it "handles a template mixing both forms" do
      expect(Langsys::Interpolate.call("{greeting}, %name%!", { greeting: "Hi", name: "Sarah" }, "en-US"))
        .to eq("Hi, Sarah!")
    end
  end
end

RSpec.describe "MARK conformance" do
  def page_client
    build_client.tap do
      stub_authorize(key_type: "write", write_enabled: true)
    end
  end

  describe "MARK-1 — a rendered host carries the identity it was rendered from" do
    it "stamps data-ls-contentblock with the id the tokenizer independently derives" do
      # Two paths to one value. A test that reads back the attribute the renderer just
      # wrote, without re-deriving it, proves only that the attribute was written.
      inner = "<span>Welcome</span> <em>friend</em>"
      client = page_client
      custom_id = Langsys.generate_custom_id("Home", Langsys::Html.extract_phrases(inner))
      stub_translations("es-es", { "Home" => { custom_id => { "Welcome" => "Bienvenido", "friend" => "amigo" } } })
      client.set_locale("es-ES")

      out = client.translate_page("<html><body><p data-langsys-category=\"Home\">#{inner}</p></body></html>")
      doc = Nokogiri::HTML(out)
      host = doc.at_css("p")
      expect(host["data-ls-contentblock"]).to eq(custom_id)
      expect(out).to include("Bienvenido")
    end

    it "stamps the id even when the block is not yet registered" do
      # The identity is what the block WOULD register as; a debugger needs it most when
      # the block has not resolved.
      inner = "<span>Welcome</span> <em>friend</em>"
      client = page_client
      stub_translations("es-es", { "Home" => {} })
      client.set_locale("es-ES")
      out = client.translate_page("<html><body><p data-langsys-category=\"Home\">#{inner}</p></body></html>")
      expected = Langsys.generate_custom_id("Home", Langsys::Html.extract_phrases(inner))
      expect(Nokogiri::HTML(out).at_css("p")["data-ls-contentblock"]).to eq(expected)
    end
  end

  describe "MARK-2 — both spellings are accepted on read" do
    { "data-langsys-contentblock" => "legacy", "data-ls-contentblock" => "current" }.each do |attr, label|
      it "honours #{attr} (#{label} spelling) as a content-block marker" do
        expect(Langsys::Html::Page.content_block_marked?({ attr => "1" })).to be(true)
      end
    end

    { "data-langsys-category" => "legacy", "data-ls-category" => "current" }.each do |attr, label|
      it "reads a category from #{attr} (#{label} spelling)" do
        client = page_client
        stub_translations("es-es", { "Marked" => { "Welcome" => "Bienvenido" } })
        client.set_locale("es-ES")
        out = client.translate_page("<html><body><p #{attr}=\"Marked\">Welcome</p></body></html>")
        expect(out).to include("Bienvenido")
      end
    end

    it "does not re-split a host already marked with the current spelling" do
      # A reader that knows one spelling walks into the other's host and splits a block
      # that was already identified, registering it a second time.
      client = page_client
      stub_translations("es-es", { Langsys::UNCATEGORIZED => {} })
      client.set_locale("es-ES")
      client.translate_page('<html><body><p data-ls-contentblock="1"><span>A</span> <em>B</em></p></body></html>')
      expect(client.pending_content_blocks.size).to eq(1)
      expect(client.pending_phrases).to be_empty
    end

    it "does not re-split a host marked with the legacy spelling either (mirror case)" do
      client = page_client
      stub_translations("es-es", { Langsys::UNCATEGORIZED => {} })
      client.set_locale("es-ES")
      client.translate_page('<html><body><p data-langsys-contentblock="1"><span>A</span> <em>B</em></p></body></html>')
      expect(client.pending_content_blocks.size).to eq(1)
      expect(client.pending_phrases).to be_empty
    end
  end
end
