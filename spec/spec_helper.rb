# frozen_string_literal: true

require "uri"
require "shellwords"

require "langsys"
require "webmock/rspec"

# Unit specs never touch the network; integration specs (tag :integration) hit a real
# Langsys backend, so allow localhost for those — plus the host of LANGSYS_API_URL when
# it is set. A local backend is often served from a Valet/Herd +.test+ domain, which
# WebMock does not count as localhost even though it resolves to 127.0.0.1.
integration_host =
  begin
    url = ENV.fetch("LANGSYS_API_URL", nil)
    url.nil? || url.empty? ? nil : URI.parse(url).host
  rescue URI::InvalidURIError
    nil
  end

WebMock.disable_net_connect!(allow_localhost: true, allow: [integration_host].compact)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Clear any environment credentials so unit specs are hermetic (integration specs keep them).
  config.before do |example|
    next if example.metadata[:integration]

    @saved_env = {}
    %w[LANGSYS_API_KEY LANGSYS_PROJECT_ID LANGSYS_API_URL LANGSYS_BASE_LOCALE LANGSYS_CACHE_TTL]
      .each { |k| @saved_env[k] = ENV.delete(k) }
  end

  config.after do
    @saved_env&.each { |k, v| ENV[k] = v unless v.nil? }
    @saved_env = nil
  end
end

# A hermetic client pointed at a fake host, backed by an in-memory cache.
def build_client(**overrides)
  Langsys::Client.new(
    api_key: "test-key",
    project_id: "proj-1",
    api_url: "https://api.test/api",
    base_locale: "en-US",
    cache: Langsys::Cache::Memory.new,
    **overrides
  )
end

def catalog_body(data)
  { "status" => true, "words" => 0, "untranslatedWords" => 0, "data" => data }
end

def authorize_body(key_type: "read", write_enabled: :omit)
  data = {
    "id" => "proj-1", "title" => "Test", "base_locale" => "en-us",
    "target_locales" => [], "default_locales" => {}, "key_type" => key_type,
    "langsys_settings" => { "translatable_items" => { "batch_limit" => 200 } }
  }
  # :omit models a pre-capability server (GATE-8); anything else is sent as the flag.
  data["write_enabled"] = write_enabled unless write_enabled == :omit
  { "status" => true, "data" => data }
end

# Stub the catalog endpoint for +locale+ exactly as it goes on the wire. Per WIRE-3 the
# SDK sends lowercase, so callers pass the lowercase form here.
def stub_translations(locale, data)
  stub_request(:get, "https://api.test/api/translations")
    .with(query: { "project_id" => "proj-1", "locale" => locale, "format" => "flat" })
    .to_return(status: 200, body: JSON.generate(catalog_body(data)),
               headers: { "Content-Type" => "application/json" })
end

def stub_authorize(key_type: "read", write_enabled: :omit)
  stub_request(:get, "https://api.test/api/authorize-project/proj-1")
    .to_return(status: 200,
               body: JSON.generate(authorize_body(key_type: key_type, write_enabled: write_enabled)),
               headers: { "Content-Type" => "application/json" })
end
