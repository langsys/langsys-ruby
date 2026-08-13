# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Locale do
  describe ".canonicalize_locale" do
    it "cases language/script/region" do
      expect(described_class.canonicalize_locale("en-us")).to eq("en-US")
      expect(described_class.canonicalize_locale("zh-hant-tw")).to eq("zh-Hant-TW")
      expect(described_class.canonicalize_locale("ES_es")).to eq("es-ES")
    end

    it "returns empty for nil/blank" do
      expect(described_class.canonicalize_locale(nil)).to eq("")
      expect(described_class.canonicalize_locale("  ")).to eq("")
    end
  end

  describe ".parse_accept_language" do
    it "orders by q-value, dropping * and invalid weights" do
      header = "es-ES,en;q=0.8,*;q=0.1,fr;q=bad"
      expect(described_class.parse_accept_language(header)).to eq(%w[es-ES en])
    end

    it "returns [] for a blank header" do
      expect(described_class.parse_accept_language(nil)).to eq([])
    end
  end

  describe ".detect_preferred_locale" do
    it "matches exactly against supported" do
      expect(described_class.detect_preferred_locale("es-ES,en;q=0.5", %w[en-US es-ES])).to eq("es-ES")
    end

    it "matches by primary language" do
      expect(described_class.detect_preferred_locale("es", %w[en-US es-ES])).to eq("es-ES")
    end

    it "returns nil when nothing matches" do
      expect(described_class.detect_preferred_locale("de", %w[en-US es-ES])).to be_nil
    end

    it "returns the top preference when no supported list is given" do
      expect(described_class.detect_preferred_locale("fr-fr,en;q=0.5")).to eq("fr-FR")
    end
  end
end
