# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

module Langsys
  # Cache backends. Any object responding to +get+/+set+/+delete+/+clear+ can be passed as
  # the client's +cache:+.
  #
  # The contract:
  #   get(key)               -> value or nil (nil on miss/expiry)
  #   set(key, value, ttl)   -> stores for +ttl+ seconds (0 = no expiry)
  #   delete(key)            -> removes key (no error if absent)
  #   clear                  -> drops everything this backend owns
  module Cache
    # In-process cache. Cleared when the process exits; ideal as the fast first tier.
    class Memory
      def initialize
        @store = {}
      end

      def get(key)
        entry = @store[key]
        return nil if entry.nil?

        expires, value = entry
        if expires.positive? && expires < Time.now.to_f
          @store.delete(key)
          return nil
        end
        value
      end

      def set(key, value, ttl = 3600)
        expires = ttl.positive? ? Time.now.to_f + ttl : 0.0
        @store[key] = [expires, value]
      end

      def delete(key)
        @store.delete(key)
      end

      def clear
        @store.clear
      end
    end

    # JSON-file cache — survives across processes (the default persistent tier). Each entry
    # is a small JSON file +{"expires": <epoch|0>, "value": …}+; keys are sanitized to safe
    # filenames. Corrupt or expired files are treated as misses.
    class File
      SAFE = /[^A-Za-z0-9_.-]/

      def initialize(path = nil)
        @dir = path || ::File.join(Dir.tmpdir, "langsys-cache")
        FileUtils.mkdir_p(@dir)
      end

      def get(key)
        raw = ::File.read(path_for(key), encoding: "UTF-8")
        entry = JSON.parse(raw)
        expires = entry["expires"]
        if expires&.positive? && expires < Time.now.to_f
          delete(key)
          return nil
        end
        entry["value"]
      rescue Errno::ENOENT, JSON::ParserError, TypeError
        nil
      end

      def set(key, value, ttl = 3600)
        expires = ttl.positive? ? Time.now.to_f + ttl : 0
        payload = JSON.generate({ "expires" => expires, "value" => value })
        file = path_for(key)
        tmp = "#{file}.tmp"
        ::File.write(tmp, payload, encoding: "UTF-8")
        ::File.rename(tmp, file) # atomic within the same directory
      rescue SystemCallError
        FileUtils.rm_f(tmp) if tmp
      end

      def delete(key)
        FileUtils.rm_f(path_for(key))
      end

      def clear
        Dir.glob(::File.join(@dir, "*.json")).each { |f| FileUtils.rm_f(f) }
      end

      private

      def path_for(key)
        ::File.join(@dir, "#{key.gsub(SAFE, '_')}.json")
      end
    end

    # A cache that stores nothing — every read misses. For always-fresh setups.
    class Null
      def get(_key) = nil
      def set(_key, _value, _ttl = 3600) = nil
      def delete(_key) = nil
      def clear = nil
    end
  end
end
