# frozen_string_literal: true

module Langsys
  # SRV-3: a miss recorded while a request is being served is sent by no flush until that
  # request's response is out. A host opens a scope when a request starts and ends it once
  # the response has been flushed; a miss is tagged with the scope open at the moment it is
  # recorded, and is released when a scope that recorded it has ended. Outside any scope a
  # miss is released at once, and the shutdown flush releases everything.
  #
  # Scopes live at module level, not on a client, so a host can open one before any client
  # exists: a client built lazily inside a request records into the scope already open.
  #
  # The current scope is fiber-local, so a server running one fiber per request on a shared
  # thread keeps its requests apart. Ending takes the handle explicitly, so it may happen on
  # another thread or fiber (a response-finished callback). A scope that is never ended holds
  # its misses until the shutdown flush.
  class RequestScope
    KEY = :langsys_request_scope

    attr_reader :previous

    def initialize(previous)
      @previous = previous
      @ended = false
    end

    def ended? = @ended

    def end!
      @ended = true
      self
    end

    class << self
      # Fiber storage (Ruby 3.2+) is inherited by fibers and threads a request spawns;
      # Thread#[] is fiber-local on every Ruby, without that inheritance.
      def fiber_storage?
        Fiber.respond_to?(:[])
      end

      def current
        fiber_storage? ? Fiber[KEY] : Thread.current[KEY]
      end

      def current=(scope)
        fiber_storage? ? (Fiber[KEY] = scope) : (Thread.current[KEY] = scope)
      end

      def begin
        scope = new(current)
        self.current = scope
        scope
      end

      def end(scope)
        return if scope.nil?

        scope.end!
        self.current = scope.previous if current.equal?(scope)
        nil
      end
    end
  end

  module_function

  def begin_request_scope = RequestScope.begin

  def end_request_scope(scope) = RequestScope.end(scope)

  def request_scope
    scope = RequestScope.begin
    yield
  ensure
    RequestScope.end(scope)
  end
end
