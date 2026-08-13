# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langsys::Catalog do
  describe ".resolve" do
    let(:catalog) do
      {
        "UI" => { "Save" => "Guardar", "Empty" => "", "Null" => nil },
        "Home" => { "abc123" => { "Welcome" => "Bienvenido" } }
      }
    end

    it "returns a translation hit" do
      res = described_class.resolve(catalog, "Save", "UI")
      expect(res.text).to eq("Guardar")
      expect(res.missing).to be false
    end

    it "falls back to the source phrase for present-but-empty/null (not missing)" do
      expect(described_class.resolve(catalog, "Empty", "UI").text).to eq("Empty")
      expect(described_class.resolve(catalog, "Empty", "UI").missing).to be false
      expect(described_class.resolve(catalog, "Null", "UI").missing).to be false
    end

    it "marks an absent key as missing" do
      res = described_class.resolve(catalog, "Delete", "UI")
      expect(res.text).to eq("Delete")
      expect(res.missing).to be true
    end

    it "uses __uncategorized__ when no category is given" do
      cat = { Langsys::UNCATEGORIZED => { "Hi" => "Hola" } }
      expect(described_class.resolve(cat, "Hi").text).to eq("Hola")
    end

    it "resolves a phrase inside a content block" do
      res = described_class.resolve(catalog, "Welcome", "Home", "abc123")
      expect(res.text).to eq("Bienvenido")
      expect(res.missing).to be false
    end
  end
end
