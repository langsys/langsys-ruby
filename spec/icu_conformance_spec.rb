# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

# Conformance specs for the ICU rule family (ICU-1..ICU-5).
# Distinct text per branch: a simplified renderer that only knows one/other cannot fake
# `few` or `many`, so a wrong branch is visible in the output.
PL_PLURAL = "{n, plural, one {# plik} few {# pliki} many {# plikow} other {# pliku}}"

RSpec.describe "ICU conformance" do
  # --------------------------------------------------------------------------
  # This block is the protection, and it was green before any recovery work
  # began. Recovery may rewrite missing nodes and nothing else; the moment it
  # routes a whole template through a simplified one/other renderer, Polish stops
  # selecting `few` and these fail. English cannot show that — one/other is the
  # entire English plural set, so an English-only suite passes either way.
  # --------------------------------------------------------------------------
  describe "ICU-5 — supplied arguments keep CLDR selection (discriminating guard)" do
    it "selects `few` for n=3 in Polish, where a one/other renderer would say `other`" do
      expect(Langsys::Interpolate.call(PL_PLURAL, { n: 3 }, "pl-PL")).to eq("3 pliki")
    end

    it "selects `many` for n=5 in Polish" do
      expect(Langsys::Interpolate.call(PL_PLURAL, { n: 5 }, "pl-PL")).to eq("5 plikow")
    end

    it "selects `one` for n=1 in Polish" do
      expect(Langsys::Interpolate.call(PL_PLURAL, { n: 1 }, "pl-PL")).to eq("1 plik")
    end
  end

  describe "ICU-1 — a missing argument selects the `other` branch" do
    it "renders the `other` branch of a select whose argument was not supplied" do
      expect(Langsys::Interpolate.call("{g, select, male {He} female {She} other {They}}", {}, "en-US"))
        .to eq("They")
    end

    it "renders the `other` branch of a plural whose argument was not supplied" do
      expect(Langsys::Interpolate.call("{n, plural, one {# item} other {# items}}", {}, "en-US"))
        .to eq("{n} items")
    end

    it "leaves a malformed node (no `other` branch) to normal error handling" do
      # No `other` to fall back to: degrade rather than invent a branch.
      expect { Langsys::Interpolate.call("{g, select, male {He}}", {}, "en-US") }.not_to raise_error
    end
  end

  describe "ICU-2 — null counts as missing" do
    it "treats a present-but-nil select argument as absent" do
      expect(Langsys::Interpolate.call("{g, select, male {He} other {They}}", { g: nil }, "en-US"))
        .to eq("They")
    end

    it "treats a present-but-nil plural argument as absent" do
      expect(Langsys::Interpolate.call("{n, plural, one {# item} other {# items}}", { n: nil }, "en-US"))
        .to eq("{n} items")
    end

    it "recovers a nil argument as a missing one, with ICU-4's notice and no formatter-failure warning" do
      Langsys::Interpolate::RECOVERY_NOTICES_SEEN.clear
      Langsys::Interpolate::FAILURE_NOTICES_SEEN.clear
      log = StringIO.new
      logger = Logger.new(log)
      out = Langsys::Interpolate.call("{n, plural, one {# item} other {# items}}", { n: nil }, "en-US", logger: logger)
      expect(out).to eq("{n} items")
      expect(log.string).to match(/DEBUG.*\{n\}/)
      expect(log.string).not_to match(/formatter failed/)
    end

    it "does not render nil as 0 — the plausible-but-false rendering" do
      expect(Langsys::Interpolate.call("{n, plural, other {# items}}", { n: nil }, "en-US"))
        .not_to eq("0 items")
    end
  end

  describe "ICU-3 — recovery is recursive, and `#` becomes the visible argument name" do
    it "descends into the branches of a nested select" do
      expect(Langsys::Interpolate.call("{a, select, x {A} other {{b, select, y {B} other {C}}}}", {}, "en-US"))
        .to eq("C")
    end

    it "recovers an argument missing two levels down" do
      template = "{a, select, other {{b, select, other {{c, select, other {deep}}}}}}"
      expect(Langsys::Interpolate.call(template, {}, "en-US")).to eq("deep")
    end

    it "emits the literal {argName} for `#` inside a recovered plural, never a number" do
      expect(Langsys::Interpolate.call("You have {n, plural, one {# msg} other {# msgs}}.", {}, "en-US"))
        .to eq("You have {n} msgs.")
    end

    it "recovers a nested plural inside a recovered select" do
      template = "{g, select, other {{n, plural, one {# file} other {# files}}}}"
      expect(Langsys::Interpolate.call(template, {}, "en-US")).to eq("{n} files")
    end

    it "still renders a supplied argument inside a recovered branch" do
      template = "{g, select, other {Hello {name}}}"
      expect(Langsys::Interpolate.call(template, { name: "Sarah" }, "en-US")).to eq("Hello Sarah")
    end
  end

  describe "ICU-5 — recovery rewrites only the missing nodes" do
    it "keeps CLDR selection for a supplied argument when another argument is missing" do
      template = "{who, select, m {Pan} other {Osoba}}: #{PL_PLURAL}"
      expect(Langsys::Interpolate.call(template, { n: 3 }, "pl-PL")).to eq("Osoba: 3 pliki")
    end

    it "keeps CLDR selection when the missing argument follows the supplied one" do
      template = "#{PL_PLURAL} — {who, select, m {Pan} other {Osoba}}"
      expect(Langsys::Interpolate.call(template, { n: 3 }, "pl-PL")).to eq("3 pliki — Osoba")
    end

    it "keeps the recovered literal visible when the argument is present-and-null" do
      # The formatter must not substitute the recovered {amt} with an empty string —
      # that erases the gap ICU-3 just created.
      expect(Langsys::Interpolate.call("{amt} due", { amt: nil }, "en-US")).to eq("{amt} due")
    end
  end

  describe "ICU-4 — recovery is observable" do
    let(:notices) { [] }
    let(:logger) { double("logger").tap { |l| allow(l).to receive(:debug) { |m| notices << m } } }

    # The dedup is process-lifetime by design (that is the rule), so the process state
    # has to be reset between examples or the first one to run hides the rest.
    before { Langsys::Interpolate::RECOVERY_NOTICES_SEEN.clear }

    it "names every defaulted argument and the locale" do
      Langsys::Interpolate.call("{g, select, other {They}} {h, select, other {X}}", {}, "en-US", logger: logger)
      expect(notices.join).to include("g").and include("h").and include("en-US")
    end

    it "fires for plural recoveries as well as select" do
      Langsys::Interpolate.call("{n, plural, other {# items}}", {}, "en-US", logger: logger)
      expect(notices.join).to include("n")
    end

    it "is silent when no logger is supplied" do
      expect { Langsys::Interpolate.call("{g, select, other {They}}", {}, "en-US") }.not_to raise_error
    end

    it "deduplicates per (template, locale) for the process lifetime" do
      3.times { Langsys::Interpolate.call("{g, select, other {They}}", {}, "en-US", logger: logger) }
      expect(notices.size).to eq(1)
    end

    it "notifies again for the same template in a different locale" do
      Langsys::Interpolate.call("{g, select, other {They}}", {}, "en-US", logger: logger)
      Langsys::Interpolate.call("{g, select, other {They}}", {}, "es-ES", logger: logger)
      expect(notices.size).to eq(2)
    end
  end

  # Through t(), not Interpolate.call. Every example above calls the renderer directly, so
  # none could see Client#interpolate skip it when the caller passed no params, which is the
  # spec's own motivating case: "Welcome" asks for nothing and its translation selects.
  describe "ICU-1/ICU-3/ICU-4 through t() when the caller passes no params" do
    let(:notices) { [] }
    let(:logger) do
      double("logger").tap do |l|
        allow(l).to receive(:debug) { |m| notices << m }
        allow(l).to receive_messages(warn: nil, info: nil, error: nil)
      end
    end
    let(:catalog) do
      { "UI" => { "Welcome" => "{gender, select, female {Bienvenida} other {Bienvenido}}",
                  "Items" => "Tienes {n, plural, one {# elemento} other {# elementos}}.",
                  "Greeting" => "Hola { name }" } }
    end

    before do
      Langsys::Interpolate::RECOVERY_NOTICES_SEEN.clear
      stub_translations("es-es", catalog)
    end

    def spanish_client(**opts) = build_client(base_locale: "es-ES", **opts)

    it "renders the other branch of a select when params is omitted" do
      expect(spanish_client.t("Welcome", category: "UI")).to eq("Bienvenido")
    end

    it "renders the other branch of a select when params is empty" do
      expect(spanish_client.t("Welcome", category: "UI", params: {})).to eq("Bienvenido")
    end

    it "recovers a plural with no params, `#` becoming the argument name" do
      expect(spanish_client.t("Items", category: "UI")).to eq("Tienes {n} elementos.")
    end

    it "surfaces the ICU-4 notice on that path" do
      spanish_client(logger: logger).t("Welcome", category: "UI")
      expect(notices.join).to include("{gender}").and match(/es-es/i)
    end

    it "leaves a template with no ICU syntax byte-identical when no params are passed (control)" do
      expect(spanish_client.t("Greeting", category: "UI")).to eq("Hola { name }")
    end
  end
end
