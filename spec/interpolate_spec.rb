# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Interpolate do
  describe ".icu?" do
    it "detects ICU MessageFormat" do
      expect(described_class.icu?("{n, plural, one {#} other {#}}")).to be true
      expect(described_class.icu?("{n, number}")).to be true
      expect(described_class.icu?("Hello, {name}!")).to be false
    end
  end

  describe "simple slots" do
    it "substitutes params" do
      expect(described_class.call("Hello, {name}!", { name: "Sarah" })).to eq("Hello, Sarah!")
    end

    it "accepts string keys too" do
      expect(described_class.call("Hi {name}", { "name" => "Al" })).to eq("Hi Al")
    end

    it "leaves an unknown or nil slot visible" do
      expect(described_class.call("Hi {name}", {})).to eq("Hi {name}")
      expect(described_class.call("Hi {name}", { name: nil })).to eq("Hi {name}")
    end

    it "renders booleans as words" do
      expect(described_class.call("{flag}", { flag: true })).to eq("true")
      expect(described_class.call("{flag}", { flag: false })).to eq("false")
    end
  end

  describe "ICU plurals" do
    let(:phrase) { "You have {count, plural, one {# new message} other {# new messages}}." }

    it "selects the one branch" do
      expect(described_class.call(phrase, { count: 1 }, "en")).to eq("You have 1 new message.")
    end

    it "selects the other branch" do
      expect(described_class.call(phrase, { count: 3 }, "en")).to eq("You have 3 new messages.")
    end

    it "honors exact =N selectors" do
      p = "{n, plural, =0 {none} one {#} other {# items}}"
      expect(described_class.call(p, { n: 0 }, "en")).to eq("none")
    end

    it "applies the offset to #" do
      p = "{n, plural, offset:1 one {you and # other} other {you and # others}}"
      expect(described_class.call(p, { n: 3 }, "en")).to eq("you and 2 others")
    end
  end

  describe "ICU select" do
    let(:phrase) { "{gender, select, female {She} male {He} other {They}} replied" }

    it "picks the matching branch" do
      expect(described_class.call(phrase, { gender: "female" })).to eq("She replied")
    end

    it "falls back to other" do
      expect(described_class.call(phrase, { gender: "x" })).to eq("They replied")
    end
  end

  it "degrades malformed ICU to simple interpolation instead of raising" do
    expect(described_class.call("{n, plural, one {# unclosed", { n: 1 })).to be_a(String)
  end

  # Same recovery as langsys-js-typescript 0.6.4 and langsys-php 1.3.1. Reachable with no
  # caller mistake: Langsys promotes a plain "{username}" phrase to
  # "{username_gender, select, …}" in gendered target locales, so the app never passes
  # username_gender. It must read as a sentence, not as "{username_gender}".
  describe "a missing ICU argument" do
    let(:gendered) do
      "{username_gender, select, female {{username} ha sido invitada} " \
        "male {{username} ha sido invitado} other {{username} ha sido invitade}}"
    end

    it "takes the other branch of a select" do
      expect(described_class.call(gendered, { username: "Ana" }, "es-ES")).to eq("Ana ha sido invitade")
    end

    it "treats nil as missing" do
      expect(described_class.call(gendered, { username: "Ana", username_gender: nil }, "es-ES")).to eq("Ana ha sido invitade")
    end

    it "leaves a supplied select alone" do
      expect(described_class.call(gendered, { username: "Ana", username_gender: "female" }, "es-ES")).to eq("Ana ha sido invitada")
    end

    it "takes the other branch of a plural, with # shown as the slot" do
      phrase = "{count, plural, one {Tienes # mensaje nuevo.} other {Tienes # mensajes nuevos.}}"
      expect(described_class.call(phrase, {}, "es-ES")).to eq("Tienes {count} mensajes nuevos.")
      expect(described_class.call(phrase, { count: nil }, "es-ES")).to eq("Tienes {count} mensajes nuevos.")
      expect(described_class.call(phrase, { count: 0 }, "es-ES")).to eq("Tienes 0 mensajes nuevos.")
    end

    it "keeps simple and number slots visible" do
      expect(described_class.call("{n, number} por {who}, {g, select, other {ok}}", {}, "es-ES")).to eq("{n} por {who}, ok")
    end

    it "costs nothing inside a branch that isn't chosen" do
      phrase = "{g, select, f {Ella} other {{n, plural, one {# amiga} other {# amigas}}}}"
      expect(described_class.call(phrase, { g: "f" }, "es-ES")).to eq("Ella")
      expect(described_class.call(phrase, {}, "es-ES")).to eq("{n} amigas")
    end

    it "leaves a select without an other branch visible" do
      expect(described_class.call("{g, select, male {He} female {She}} won", {}, "en")).to eq("{g} won")
    end
  end
end
