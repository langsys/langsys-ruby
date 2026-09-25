# frozen_string_literal: true

# The %{name} strings here are Rails i18n source text under test, not Ruby format strings.
# rubocop:disable Style/FormatStringToken

require "spec_helper"
require "logger"
require "stringio"
require "tmpdir"
require_relative "support/contract_fixture"

# MIG-1..7 at langsys2 a1b7568c (spec 8.2.12). mig-vectors.json is not authored yet, so these
# are local vectors written from the rule texts; they are re-cited when the shared file lands.
RSpec.describe "spec 8.2.12 legacy-key migration (MIG)" do
  let(:dir) { File.expand_path("fixtures/migration", __dir__) }
  let(:log) { StringIO.new }
  let(:logger) { Logger.new(log) }

  def client(files = nil, **opts)
    stub_authorize(key_type: "write", write_enabled: true)
    stub_translations("en-us", {})
    build_client(migration: files, logger: logger, **opts)
  end

  def queued(sdk) = sdk.pending_phrases.map { |p| [p["category"], p["phrase"]] }

  describe "MIG-1 — the mode is explicit, and off by default" do
    it "never reads a file or treats the argument as a key when unset, even beside an app's locale file" do
      Dir.mktmpdir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "config/locales"))
        FileUtils.cp(File.join(dir, "en.yml"), File.join(tmp, "config/locales/en.yml"))
        Dir.chdir(tmp) do
          expect(File).not_to receive(:read)
          sdk = client
          sdk.t("checkout.submit")
          expect(queued(sdk)).to eq([[Langsys::UNCATEGORIZED, "checkout.submit"]])
        end
      end
    end

    it "does the key lookup when set" do
      sdk = client([File.join(dir, "en.yml")])
      sdk.t("checkout.submit")
      expect(queued(sdk)).to eq([["checkout", "Place order"]])
    end
  end

  describe "MIG-2 — resolve the argument as a key first" do
    let(:sdk) { client([File.join(dir, "en.yml")]) }

    it "takes a hit's source value as the phrase, and a miss as literal source text" do
      sdk.t("checkout.submit")
      sdk.t("Already source text")
      expect(queued(sdk)).to eq([["checkout", "Place order"], [Langsys::UNCATEGORIZED, "Already source text"]])
    end

    it "registers I18n.t('Hello %{name}', name:) as the same phrase as t('Hello {name}')" do
      legacy = sdk.translate_legacy("Hello %{name}", entry_point: :rails, params: { name: "Ada" })
      modern = sdk.t("Hello {name}", params: { name: "Ada" })
      expect(legacy).to eq(modern)
      expect(queued(sdk)).to eq([[Langsys::UNCATEGORIZED, "Hello {name}"]])
    end

    it "converts only the %{key} placeholders an I18n.t call passes" do
      expect(Langsys::Migration.convert_literal("A %{x} and %{y}", entry_point: :rails, params: { x: 1 }))
        .to eq("A {x} and %{y}")
    end

    it "converts nothing in a Langsys t() literal" do
      expect(Langsys::Migration.convert_literal("A %{x}", entry_point: :langsys, params: { x: 1 })).to eq("A %{x}")
    end

    it "registers a rails-i18n zero/one/other hash as an ICU plural under its namespace" do
      sdk.t("cart.items", params: { count: 2 })
      expect(queued(sdk)).to eq([["cart", "{count, plural, =0 {Your cart is empty} one {# item} other {# items}}"]])
    end
  end

  describe "MIG-3 — the catalog holds source text, never keys", contract: true do
    it "leaves the server holding the value, never the key" do
      contract.seed("projects" => [{ "id" => "proj-c" }],
                    "keys" => [{ "key" => "w", "project" => "proj-c", "type" => "write" }])
      sdk = contract_client(key: "w", migration: [File.join(dir, "en.yml")])
      sdk.t("checkout.submit")
      sdk.flush_pending
      expect(contract.phrases("proj-c").keys).to eq([["checkout", "Place order"]])
    end
  end

  describe "MIG-4 — convert legacy interpolation and plurals" do
    def convert(value, format: "plain") = Langsys::Migration.convert(value, format: format)

    {
      "Hi {{name}}" => "Hi {name}", "Hi {name}" => "Hi {name}", "Hello :name" => "Hello {name}",
      "Hello %{name}" => "Hello {name}", "Hello %(name)s" => "Hello {name}", "Age %(age)d" => "Age {age}",
      "100%% sure" => "100% sure", "Note:done" => "Note:done"
    }.each do |from, to|
      it "converts #{from.inspect} to #{to.inspect}" do
        expect(convert(from).phrase).to eq(to)
      end
    end

    ["Total %<amount>.2f", "Rate %(rate).2f", "Positional %s", "Hello :Name", "HELLO :NAME"].each do |value|
      it "registers #{value.inspect} verbatim and warns" do
        result = convert(value)
        expect([result.phrase, result.warning]).to match([value, a_string_matching(/verbatim/)])
      end
    end

    it "leaves a pipe verbatim in a plain file, warned" do
      result = convert("car | cars")
      expect([result.phrase, result.warning]).to match(["car | cars", a_string_matching(/verbatim/)])
    end

    it "converts a gettext plural pair to =1/other with # in the branches" do
      expect(Langsys::Migration.gettext_plural("%(count)s item", "%(count)s items"))
        .to eq("{count, plural, =1 {# item} other {# items}}")
    end

    it "spells branches canonically and never leaves {count} inside one" do
      phrase = Langsys::Migration.rails_plural({ "other" => "%{count} left", "1" => "Last one", "few" => "%{count} few",
                                                 "zero" => "None" })
      expect(phrase).to eq("{count, plural, =0 {None} =1 {Last one} few {# few} other {# left}}")
      expect(phrase).not_to include("{count}}")
    end
  end

  describe "MIG-5 — the key's namespace is the category unless the call passes one" do
    it "uses the namespace, and lets an explicit category win" do
      sdk = client([File.join(dir, "en.yml")])
      sdk.t("checkout.submit")
      sdk.t("checkout.submit", category: "Buttons")
      expect(queued(sdk)).to eq([["checkout", "Place order"], ["Buttons", "Place order"]])
    end
  end

  describe "MIG-6 — drift is treated, never silent" do
    it "warns at debug for a key absent from the file and registers the argument as literal text" do
      sdk = client([File.join(dir, "en.yml")])
      sdk.t("checkout.typo")
      expect(queued(sdk)).to eq([[Langsys::UNCATEGORIZED, "checkout.typo"]])
      expect(log.string).to match(/DEBUG.*checkout\.typo/)
    end

    it "registers a changed value as a new phrase" do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "en.yml")
        File.write(path, "en:\n  a: \"First\"\n")
        first = client([path])
        first.t("a")
        File.write(path, "en:\n  a: \"Second\"\n")
        second = client([path])
        second.t("a")
        expect(queued(first) + queued(second)).to eq([[Langsys::UNCATEGORIZED, "First"],
                                                      [Langsys::UNCATEGORIZED, "Second"]])
      end
    end
  end

  describe "MIG-7 — files, formats, nesting, and more than one" do
    it "resolves a nested key by path in JSON and in YAML" do
      sdk = client([File.join(dir, "plain.json"), File.join(dir, "en.yml")])
      sdk.t("nav.home")
      sdk.t("checkout.submit")
      expect(queued(sdk)).to eq([["nav", "Home page"], ["checkout", "Place order"]])
    end

    it "lets the first configured file win and reports the duplicate" do
      sdk = client([File.join(dir, "en.yml"), File.join(dir, "second.yml")])
      sdk.t("shared")
      expect(queued(sdk)).to eq([[Langsys::UNCATEGORIZED, "From the first file"]])
      expect(sdk.migration.duplicates).to include("shared")
    end

    it "reads a .po as gettext: msgid is the phrase and msgctxt the category" do
      sdk = client([File.join(dir, "django.po")])
      sdk.t("Remove")
      sdk.t("Wrapped message")
      expect(queued(sdk)).to eq([%w[cart Remove], ["nav", "Wrapped message"]])
    end

    it "refuses a configured .mo, naming the .po it was compiled from" do
      expect { client(["locale/es/LC_MESSAGES/django.mo"]).t("x") }
        .to raise_error(Langsys::ConfigurationError, %r{locale/es/LC_MESSAGES/django\.po})
    end

    %w[laravel vue-i18n i18next].each do |format|
      it "refuses the #{format} format at load, naming the format and the file" do
        expect { client([{ path: File.join(dir, "plain.json"), format: format }]).t("x") }
          .to raise_error(Langsys::ConfigurationError, /#{format}.*plain\.json/)
      end
    end

    it "refuses a PHP-array file, which is not a Ruby source" do
      expect { client(["lang/en/auth.php"]).t("x") }.to raise_error(Langsys::ConfigurationError, /laravel.*auth\.php/)
    end

    it "registers an undeclared JSON file's pipe verbatim and warns naming the file and the key" do
      sdk = client([File.join(dir, "plain.json")])
      sdk.t("nav.cars")
      expect(queued(sdk)).to eq([["nav", "car | cars"]])
      expect(log.string).to match(/WARN.*plain\.json.*nav\.cars/)
    end
  end
end
# rubocop:enable Style/FormatStringToken
