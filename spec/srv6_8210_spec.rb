# frozen_string_literal: true

require "spec_helper"

# SRV-6: URL, then cookie or session, then Accept-Language, then the base locale; every
# candidate validated against the project's locales; Vary names what the choice depended on.
RSpec.describe "spec 8.2.x SRV-6 request locale" do
  let(:supported) { %w[en-us es-es fr-fr] }

  def resolve(**kw) = Langsys::Locale.resolve_request_locale(supported: supported, base: "en-us", **kw)

  it "lets the URL win over a conflicting cookie and header, with no Vary" do
    expect(resolve(url: "fr-FR", cookie: "es-es", accept_language: "es-ES,es;q=0.9"))
      .to eq(locale: "fr-fr", source: :url, vary: [])
  end

  it "lets the cookie win over the header, with Vary: Cookie" do
    expect(resolve(cookie: "es-ES", accept_language: "fr-FR")).to eq(locale: "es-es", source: :cookie, vary: ["Cookie"])
  end

  it "negotiates the header alone, with Vary: Accept-Language" do
    expect(resolve(accept_language: "fr-CA,fr;q=0.8,en;q=0.5"))
      .to eq(locale: "fr-fr", source: :accept_language, vary: ["Accept-Language"])
  end

  it "skips an unsupported cookie and falls through to the header" do
    expect(resolve(cookie: "zz-zz", accept_language: "es")).to eq(locale: "es-es", source: :accept_language,
                                                                  vary: %w[Cookie Accept-Language])
  end

  it "never echoes a candidate that is not a well-formed tag" do
    expect(resolve(url: "<script>", cookie: "es-es\r\nSet-Cookie: x")).to eq(locale: "en-us", source: nil,
                                                                             vary: ["Cookie"])
  end

  it "serves the base locale with source nil when nothing survives" do
    expect(resolve).to eq(locale: "en-us", source: nil, vary: [])
  end

  it "reads the project's locales from authorization for the client helper" do
    stub_request(:get, "https://api.test/api/authorize-project/proj-1")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate(authorize_body.tap do |b|
                   b["data"]["base_locale"] = "en-us"
                   b["data"]["target_locales"] = ["es-es"]
                 end))
    client = build_client
    expect(client.resolve_request_locale(cookie: "fr-fr", accept_language: "es")).to eq(
      locale: "es-es", source: :accept_language, vary: %w[Cookie Accept-Language]
    )
  end

  describe "the locale the framework resolved (8.2.18)" do
    before do
      stub_request(:get, "https://api.test/api/authorize-project/proj-1")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate(authorize_body.tap do |b|
                     b["data"]["base_locale"] = "en-us"
                     b["data"]["target_locales"] = %w[es-es es-mx fr-fr]
                     b["data"]["default_locales"] = { "es" => "es-mx", "fr" => "fr-fr" }
                   end))
    end

    let(:client) { build_client }

    it "maps es-ES and es_ES to the project's form" do
      expect([client.framework_locale("es-ES"), client.framework_locale("es_ES")]).to eq(%w[es-es es-es])
    end

    it "maps a bare language to the project's default locale for it" do
      expect(client.framework_locale("es")).to eq("es-mx")
    end

    it "serves the base locale for a framework locale the project does not serve" do
      expect(client.framework_locale("de-DE")).to eq("en-us")
      expect(client.framework_locale("<script>")).to eq("en-us")
    end

    it "returns nil when the framework resolved nothing" do
      expect([client.framework_locale(nil), client.framework_locale("")]).to eq([nil, nil])
    end

    it "wins over the URL, the cookie and the header, and adds no Vary" do
      expect(client.resolve_request_locale(framework: "es-ES", url: "fr-FR", cookie: "fr-fr", accept_language: "fr"))
        .to eq(locale: "es-es", source: :framework, vary: [])
    end

    it "falls to the SDK's own resolution when the framework resolved nothing (control)" do
      expect(client.resolve_request_locale(framework: nil, url: "fr-FR")).to eq(locale: "fr-fr", source: :url, vary: [])
    end
  end
end
