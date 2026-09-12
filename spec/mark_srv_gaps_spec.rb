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
        "<html><head><meta name=\"description\" content=\" Buy   now \"></head><body></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Buy now"])
    end

    it "collapses U+2028 in an og:title meta" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta property=\"og:title\" content=\"Buy now\"></head><body></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }).to eq(["Buy now"])
    end

    it "gives a meta and a text node carrying the same authored string one id" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta name=\"description\" content=\"Buy now\"></head>" \
        "<body><p>Buy now</p></body></html>"
      )
      expect(client.pending_phrases.map { |p| p["phrase"] }.uniq).to eq(["Buy now"])
    end

    it "emits no phrase for a whitespace-only meta content" do
      client = rendering_client
      client.translate_page(
        "<html><head><meta name=\"description\" content=\" \"></head><body></body></html>"
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
        queued = client.pending_content_blocks.flat_map { |b| b["phrases"] }
        expect(queued).to eq(["friend"])
        expect(queued).not_to include("Welcome")
      end

      it "registers nothing for a standalone #{attr} host's text" do
        client = rendering_client
        client.translate_page("<html><body><div><p #{attr}=\"Welcome\">Welcome</p></div></body></html>")
        expect(client.pending_phrases.map { |p| p["phrase"] }).not_to include("Welcome")
      end
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
