# frozen_string_literal: true

require "spec_helper"

# Gaps found by refute-framed review of the canonicalization lane: a fourth token path,
# and the half of MARK-2 the rule's own test names.
RSpec.describe "canonicalization gaps" do
  def rendering_client
    build_client.tap do
      stub_authorize(key_type: "write", write_enabled: true)
      stub_translations("en-us", {})
    end
  end

  describe "TOK-2 — meta content is a token path too" do
    # Found by review, not by my grep, and the reason is worth keeping: this path neither
    # collapses nor trims, so searching for `\s`, `strip` and `split` could not find it.
    # A path that does NOTHING is invisible to a search for what it does wrong.
    it "collapses U+00A0 in a description meta exactly as in a text node" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta name=\"description\" " \
        "content=\"\u00A0Buy\u0020\u0020\u0020now\u00A0\"></head><body></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Buy now"])
    end

    it "collapses U+2028 in an og:title meta" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta property=\"og:title\" content=\"Buy\u2028now\"></head><body></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Buy now"])
    end

    it "gives a meta and a text node carrying the same authored string one id" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta name=\"description\" content=\"Buy\u00A0now\"></head>" \
        "<body><p>Buy now</p></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }.uniq).to eq(["Buy now"])
    end

    it "emits no phrase for a whitespace-only meta content" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta name=\"description\" content=\"\u00A0\"></head><body></body></html>"
      )
      expect(client.pending_phrases).to be_empty
    end
  end

  describe "MARK-2 — the phrase-marker spelling the rule's own test names" do
    %w[data-ls-phrase data-langsys-phrase].each do |attr|
      it "does not re-split a block containing a #{attr} host" do
        # The spec's test literally: a page containing a JS-rendered host is not
        # re-split, and no new phrase is registered for its text.
        client = rendering_client
        client.translate_page(
          "<html><body><p data-langsys-category=\"Home\">" \
          "<span #{attr}=\"Welcome\">Welcome</span> <em>friend</em></p></body></html>"
        )
        # Not re-split: the host's words stay out of the unit around it, and the host
        # registers once, whole, as the one string it defines (MARK-2, 8.2.10).
        expect(client.pending_content_blocks).to be_empty
        expect(client.pending_phrases.map { |p| p["phrase"] }).to contain_exactly("friend", "Welcome")
      end

      it "registers a standalone #{attr} host whole, once" do
        client = rendering_client
        client.translate_page("<html><body><div><p #{attr}=\"Welcome\">Welcome <b>home</b></p></div></body></html>")
        expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Welcome {m0o}home{m0c}"])
        expect(client.pending_content_blocks).to be_empty
      end

      it "excises a #{attr} host from an EXPLICIT content-block host too" do
        # The leaf path (walk_block) excised marked hosts; the explicit-host path
        # (handle_block, reached via data-*-contentblock) handed the raw inner HTML
        # straight to the tokenizer. So a marked span inside a declared block still had
        # its text folded into that block's id — a second registration for content that
        # already has one, which is exactly what MARK-2 forbids. Two paths, one rule; the
        # rule was met on whichever path happened to be tested.
        client = rendering_client
        client.translate_page(
          "<html><body><div data-langsys-contentblock=\"1\">" \
          "<span #{attr}=\"Welcome\">Welcome</span> <em>friend</em></div></body></html>"
        )
        expect(client.pending_content_blocks.map { |b| b["phrases"] }).to eq([["friend"]])
        expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Welcome"])
      end
    end

    it "still splits an unmarked explicit content-block host (control)" do
      client = rendering_client
      client.translate_page(
        '<html><body><div data-langsys-contentblock="1">' \
        "<span>Welcome</span> <em>friend</em></div></body></html>"
      )
      expect(client.pending_content_blocks.flat_map { |b| b["phrases"] }).to eq(%w[Welcome friend])
    end

    it "still splits an unmarked block (control)" do
      # Without this, recognising the marker is indistinguishable from tokenizing nothing.
      client = rendering_client
      client.translate_page(
        '<html><body><p data-langsys-category="Home"><span>Welcome</span> <em>friend</em></p></body></html>'
      )
      expect(client.pending_content_blocks.flat_map { |b| b["phrases"] }).to eq(%w[Welcome friend])
    end
  end

  describe "MARK-1 — a rendered single-phrase host carries its identity too" do
    it "stamps data-ls-phrase on a host rendered as a single phrase" do
      client = rendering_client
      out = client.translate_page('<html><body><p data-langsys-category="Home">Welcome</p></body></html>')
      expect(Nokogiri::HTML(out).at_css("p")["data-ls-phrase"]).to eq("Welcome")
    end

    it "leaves the content-block stamp to blocks, not single phrases" do
      client = rendering_client
      out = client.translate_page('<html><body><p data-langsys-category="Home">Welcome</p></body></html>')
      expect(Nokogiri::HTML(out).at_css("p")["data-ls-contentblock"]).to be_nil
    end
  end
end
