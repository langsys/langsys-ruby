# frozen_string_literal: true

module Langsys
  # Base class for everything this gem raises. Callers can rescue +Langsys::Error+
  # to catch any SDK-originated failure without leaking +Net::HTTP+ types.
  class Error < StandardError; end

  # Raised for configuration problems (missing api key / project id, bad response shape).
  class ConfigurationError < Error; end

  # Raised when the API can't be reached at all (DNS, connect, timeout).
  class NetworkError < Error; end

  # Raised for any non-2xx API response. Subclasses distinguish the well-known statuses.
  class ApiError < Error
    attr_reader :status_code, :response, :request_id, :errors

    def initialize(message, status_code: nil, response: nil, request_id: nil, errors: nil)
      super(message)
      @status_code = status_code
      @response = response
      @request_id = request_id
      @errors = errors
    end
  end

  # 401 — the key was rejected.
  class AuthenticationError < ApiError; end

  # 403 — the key is valid but not allowed to do this (e.g. a read key registering phrases).
  class AuthorizationError < ApiError; end

  # 402 — a usage limit or subscription problem.
  class PaymentRequiredError < ApiError; end

  # 422 — the request was well-formed but rejected (validation). +errors+ holds the details.
  class ValidationError < ApiError; end

  # 429 — throttled (rate limit or duplicate-request guard).
  class RateLimitError < ApiError; end
end
