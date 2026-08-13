# frozen_string_literal: true

require "spec_helper"

# Live specs against a real Langsys backend. Skipped unless credentials are in the
# environment. Run with:
#
#   LANGSYS_PROJECT_ID=… LANGSYS_API_KEY=… LANGSYS_API_URL=http://localhost:8000/api \
#     bundle exec rake integration
RSpec.describe "Langsys live", :integration do
  before(:all) do
    skip "set LANGSYS_API_KEY + LANGSYS_PROJECT_ID to run live specs" unless
      ENV["LANGSYS_API_KEY"] && ENV["LANGSYS_PROJECT_ID"]
  end

  let(:client) { Langsys::Client.new(cache: Langsys::Cache::Memory.new) }

  it "authorizes the project" do
    expect(client.project.id).not_to be_empty
    expect(%w[read write]).to include(client.key_type)
  end

  it "translates a known catalog phrase" do
    client.set_locale("es-ES")
    # The Kangen test project ships this phrase under CAT_3.
    expect(client.t("Technical Support", category: "CAT_3")).to eq("Soporte Técnico")
  end

  it "falls back to the source phrase for an unknown one" do
    client.set_locale("es-ES")
    unique = "A phrase that does not exist #{Time.now.to_i}"
    expect(client.t(unique, category: "CAT_3")).to eq(unique)
  end

  it "loads reference data" do
    countries = client.countries("es-ES")
    expect(countries).to be_an(Array)
    expect(countries.first).to respond_to(:code, :label) unless countries.empty?
  end

  it "translates a full HTML page (simple block)" do
    client.set_locale("es-ES")
    page = "<html><head><title>Technical Support</title></head>" \
           "<body><h1>Technical Support</h1></body></html>"
    out = client.translate_page(page, category: "CAT_3")
    expect(out).to include("Soporte Técnico")
    expect(out).to include('lang="es-ES"')
  end
end
