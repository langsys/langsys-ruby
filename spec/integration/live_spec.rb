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
    # `ip_write` is a first-class key type, not an unrecognised one. Asserting only
    # read/write here is what an SDK that collapses ip_write to read looks like from
    # the outside, and this assertion failed outright on the ip_write fixture key.
    expect(%w[read write ip_write]).to include(client.key_type)
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

  # --- GATE evidence, live -------------------------------------------------
  #
  # These carry the `live` grades in CONFORMANCE.md. Graded evidence has to be
  # re-runnable by whoever reads the row, so the probes that produced those grades are
  # committed rather than described. Each needs its own key, since the whole point of
  # GATE-1 is that the same project answers differently per key.
  #
  #   LANGSYS_READ_KEY=…  LANGSYS_IPWRITE_KEY=…  bundle exec rake integration
  describe "GATE, against the live server" do
    def client_for(key)
      Langsys::Client.new(api_key: key, cache: Langsys::Cache::Memory.new)
    end

    it "refuses to register on a read key the server has not write-enabled" do
      key = ENV.fetch("LANGSYS_READ_KEY", nil)
      skip "set LANGSYS_READ_KEY to run the read arm" if key.nil? || key.empty?

      c = client_for(key)
      expect(c.project.write_enabled).to be(false)
      expect(c.can_write?).to be(false)
      expect { c.register_phrases(["GATE-1 live probe (read)"]) }
        .to raise_error(Langsys::AuthorizationError)
    end

    it "registers on an ip_write key the server HAS write-enabled" do
      # The renderer runs a customer page through their unmodified SDK on exactly this
      # key type. Before this branch the SDK collapsed it to `read` and refused.
      key = ENV.fetch("LANGSYS_IPWRITE_KEY", nil)
      skip "set LANGSYS_IPWRITE_KEY to run the ip_write arm" if key.nil? || key.empty?

      c = client_for(key)
      expect(c.key_type).to eq("ip_write")
      expect(c.project.write_enabled).to be(true)
      expect(c.can_write?).to be(true)
      # Asserts the server ACCEPTED the write. Downstream processing is not asserted:
      # the local queue workers are deliberately down, so a phrase is enqueued and
      # never processed. That is the E2E wave's scope, not this row's.
      expect { c.register_phrases(["GATE-1 live probe (ip_write) #{Time.now.to_i}"]) }
        .not_to raise_error
    end

    it "keeps the write decision out of the cache (GATE-4)" do
      cache = Langsys::Cache::Memory.new
      Langsys::Client.new(cache: cache).project
      stored = cache.get("auth_#{ENV.fetch('LANGSYS_PROJECT_ID')}")
      expect(stored).to be_a(Hash)
      expect(stored).not_to have_key("write_enabled")
      expect(stored).to have_key("key_type")
    end

    it "sends a lowercase locale on the wire (WIRE-3)" do
      seen = []
      tap = Module.new do
        define_method(:request) do |req, *a, &b|
          seen << req.path
          super(req, *a, &b)
        end
      end
      Net::HTTP.prepend(tap)
      c = Langsys::Client.new(cache: Langsys::Cache::Memory.new)
      c.set_locale("es-ES")
      c.t("Technical Support", category: "CAT_3")
      expect(seen.find { |p| p.include?("translations") }).to include("locale=es-es")
    end
  end
end
