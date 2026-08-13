# frozen_string_literal: true

module Langsys
  # A minimal synchronous observable — the binding point framework wrappers hook into.
  #
  # The base gem is framework-agnostic, but a Rails/Sinatra/Hanami wrapper needs a clean,
  # synchronous way to (a) supply the current user locale and (b) react when it changes.
  # +Signal+ is that primitive, mirroring the other Langsys SDKs' signal contract:
  #
  # * +subscribe+ fires the callback **immediately** with the current value.
  # * +set+ is a no-op when the new value equals the current one; otherwise it notifies
  #   every subscriber synchronously.
  #
  # Any object responding to +get+ and +subscribe+ can act as a +LocaleSource+ — the client
  # only ever reads and subscribes, it never writes the source.
  class Signal
    def initialize(initial)
      @value = initial
      @subscribers = []
    end

    def get
      @value
    end

    def set(value)
      return if value == @value

      @value = value
      @subscribers.dup.each { |callback| callback.call(value) }
    end

    def update
      set(yield(@value))
    end

    # Register +callback+ (a proc/lambda taking the new value). Fires once immediately with
    # the current value; returns an unsubscribe proc.
    def subscribe(callback = nil, &block)
      callback ||= block
      @subscribers << callback
      callback.call(@value)
      -> { @subscribers.delete(callback) }
    end
  end
end
