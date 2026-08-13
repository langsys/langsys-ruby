# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

require_relative "errors"
require_relative "version"

module Langsys
  # HTTP transport for the nova API — a thin wrapper over +Net::HTTP+ that owns the request
  # contract every Langsys SDK shares:
  #
  # * auth header +X-Authorization: <key>+ (raw key, no +Bearer+),
  # * +X-Langsys-Capabilities: icu+ so nova returns raw ICU MessageFormat strings (without
  #   it the server pre-flattens plurals to the CLDR +other+ branch),
  # * JSON envelope parsing and status-code mapping onto typed errors.
  class Http
    USER_AGENT = "langsys-ruby/#{VERSION}".freeze

    def initialize(api_url, api_key, timeout: 30.0)
      @base = api_url.sub(%r{/+\z}, "")
      @api_key = api_key
      @timeout = timeout
    end

    def get(path, params = nil)
      send_request(Net::HTTP::Get, path, params: params)
    end

    def post(path, body = nil)
      send_request(Net::HTTP::Post, path, body: body)
    end

    # Percent-encode a single path segment (e.g. a project id or locale).
    def self.encode_segment(value)
      URI.encode_www_form_component(value.to_s)
    end

    private

    def send_request(verb, path, params: nil, body: nil)
      uri = build_uri(path, params)
      request = verb.new(uri)
      request["Content-Type"] = "application/json; charset=utf-8"
      request["Accept"] = "application/json"
      request["X-Authorization"] = @api_key
      request["X-Langsys-Capabilities"] = "icu"
      request["User-Agent"] = USER_AGENT
      request.body = JSON.generate(body) if body

      response = perform(uri, request)
      parse(response, verb, path)
    end

    def build_uri(path, params)
      uri = URI.parse("#{@base}/#{path.sub(%r{\A/+}, '')}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.request(request)
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise NetworkError, "Could not reach the Langsys API: #{e.message}"
    end

    def parse(response, _verb, _path)
      request_id = response["X-Request-ID"]
      body =
        begin
          response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
        rescue JSON::ParserError
          {}
        end
      body = {} unless body.is_a?(Hash)

      status = response.code.to_i
      raise map_error(status, body, request_id) if status >= 400

      body
    end

    def map_error(status, body, request_id)
      message = body["error"] || body["message"] || "HTTP #{status}"
      opts = { status_code: status, response: body, request_id: request_id }
      case status
      when 401 then AuthenticationError.new(message, **opts)
      when 402 then PaymentRequiredError.new(message, **opts)
      when 403 then AuthorizationError.new(message, **opts)
      when 422 then ValidationError.new(message, errors: body["errors"], **opts)
      when 429 then RateLimitError.new(message, **opts)
      else ApiError.new(message, **opts)
      end
    end
  end
end
