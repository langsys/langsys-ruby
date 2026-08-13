# frozen_string_literal: true

require "langsys"
require "webmock/rspec"

# Unit specs never touch the network; integration specs (tag :integration) hit a real
# Langsys backend, so allow localhost for those.
WebMock.disable_net_connect!(allow_localhost: true)

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

def authorize_body(key_type: "read")
  {
    "status" => true,
    "data" => {
      "id" => "proj-1", "title" => "Test", "base_locale" => "en-us",
      "target_locales" => [], "default_locales" => {}, "key_type" => key_type,
      "langsys_settings" => { "translatable_items" => { "batch_limit" => 200 } }
    }
  }
end
