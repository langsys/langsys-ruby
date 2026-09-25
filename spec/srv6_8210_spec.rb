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
end
