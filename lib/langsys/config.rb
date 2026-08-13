# frozen_string_literal: true

require_relative "errors"

module Langsys
  # Resolved client configuration. Explicit arguments win; anything left +nil+ falls back
  # to the matching +LANGSYS_*+ environment variable, then to the documented default.
  class Config
    DEFAULT_API_URL = "https://api.langsys.dev/api"
    DEFAULT_CACHE_TTL = 3600
    DEFAULT_TIMEOUT = 30.0

    attr_reader :api_key, :project_id, :api_url, :base_locale, :cache_ttl, :timeout, :debug

    def initialize(api_key:, project_id:, api_url:, base_locale:, cache_ttl:, timeout:, debug:)
      @api_key = api_key
      @project_id = project_id
      @api_url = api_url
      @base_locale = base_locale
      @cache_ttl = cache_ttl
      @timeout = timeout
      @debug = debug
    end

    # Build a Config, filling gaps from the environment and validating required fields.
    def self.resolve(api_key: nil, project_id: nil, api_url: nil, base_locale: nil,
                     cache_ttl: nil, timeout: nil, debug: false)
      api_key = present(api_key) || env("LANGSYS_API_KEY")
      project_id = present(project_id) || env("LANGSYS_PROJECT_ID")
      raise ConfigurationError, "Langsys: missing API key (pass api_key: or set LANGSYS_API_KEY)." unless api_key
      unless project_id
        raise ConfigurationError, "Langsys: missing project id (pass project_id: or set LANGSYS_PROJECT_ID)."
      end

      url = present(api_url) || env("LANGSYS_API_URL") || DEFAULT_API_URL
      ttl = cache_ttl || env("LANGSYS_CACHE_TTL")&.to_i || DEFAULT_CACHE_TTL

      new(
        api_key: api_key,
        project_id: project_id,
        api_url: url.sub(%r{/+\z}, ""),
        base_locale: present(base_locale) || env("LANGSYS_BASE_LOCALE"),
        cache_ttl: ttl,
        timeout: timeout || DEFAULT_TIMEOUT,
        debug: debug
      )
    end

    def self.env(name)
      value = ENV.fetch(name, nil)
      value.nil? || value.empty? ? nil : value
    end

    def self.present(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?) ? nil : value
    end

    private_class_method :env, :present
  end
end
