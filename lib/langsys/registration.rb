# frozen_string_literal: true

require "digest"
require "json"

require_relative "types"

module Langsys
  # Canonical serialization behind a content block's +custom_id+ (CID-1):
  #
  #   md5( json_encode([category, tokens]) )
  #
  # with unescaped slashes, unescaped unicode, and unescaped line terminators. In Ruby the
  # equivalent of those three flags is **setting nothing**: +JSON.generate+ escapes neither
  # +/+ nor non-ASCII, and emits U+2028/U+2029 raw.
  #
  # Do NOT pass +script_safe: true+ here. It escapes U+2028 to +\u2028+ and silently breaks
  # byte-identity with every other SDK — the lookup then misses and the block re-registers
  # forever. It is the one option in this file that can do that, and no id-level assertion
  # would catch it, which is why the suite pins +serialized_hex+ bytes and not just the hash.
  def self.canonical_block_json(category, phrases)
    JSON.generate([normalize_category(category), Array(phrases)])
  end

  # CID-2: no-category is the empty string — never nil, and never the +__uncategorized__+
  # sentinel, which is a cache-lookup namespace rather than a hash input. Enforced here
  # because the caller list grows; verified at the callers by spec, because whether the
  # rule currently holds is a fact about them and not about this function.
  def self.normalize_category(category)
    return "" if category.nil? || category == UNCATEGORIZED

    category.to_s
  end

  # The canonical content-block id. +Digest::MD5+ hashes the UTF-8 bytes of the string,
  # which is what CID-1 requires — a UTF-16 code-unit hash agrees across ASCII and
  # diverges everywhere above it.
  def self.generate_custom_id(category, phrases)
    Digest::MD5.hexdigest(canonical_block_json(category, phrases))
  end

  # A historical id shape: PHP's pipe-join over category-plus-phrases. **Accepted on
  # lookup, never emitted** (CID-3). Kept as a named function so the tolerance is
  # greppable and so nothing reimplements it from a description.
  #
  # This space is not injective — an unescaped delimiter loses the field boundary, so
  # category +"UI|Buy now"+ with no phrases collides with category +"UI"+ and phrase
  # +"Buy now"+ — which is why a match must be content-verified before it is attached
  # to (CID-4), and why stored rows are never re-keyed.
  def self.legacy_custom_id(category, phrases)
    Digest::MD5.hexdigest([normalize_category(category), *Array(phrases)].join("|"))
  end

  # Posts translatable items to nova. The caller is responsible for write-key gating.
  class Registrar
    attr_reader :batch_limit

    def initialize(http, project_id, batch_limit: 200)
      @http = http
      @project_id = project_id
      @batch_limit = batch_limit.positive? ? batch_limit : 200
    end

    def register_phrases(phrases)
      items = phrases.map { |p| phrase_item(p) }
      post_items(items)
    end

    def register_content_block(content, phrases, category: nil, custom_id: nil, label: nil)
      item = {
        "type" => "content_block",
        "custom_id" => custom_id || Langsys.generate_custom_id(category, phrases),
        "content" => content,
        "phrases" => phrases.map { |p| { "phrase" => p } }
      }
      item["category"] = category unless category.nil?
      item["label"] = label unless label.nil?
      responses = post_items([item])
      responses.first || { "status" => true }
    end

    private

    def phrase_item(phrase)
      if phrase.is_a?(String)
        { "type" => "phrase", "phrase" => phrase, "category" => nil, "translatable" => true }
      else
        {
          "type" => "phrase",
          "phrase" => phrase[:phrase] || phrase["phrase"],
          "category" => phrase[:category] || phrase["category"],
          "translatable" => phrase.fetch(:translatable) { phrase.fetch("translatable", true) }
        }
      end
    end

    def post_items(items)
      responses = []
      items.each_slice(@batch_limit) do |chunk|
        responses << @http.post(
          "translatable-items",
          { "project_id" => @project_id, "translatable_items" => chunk }
        )
      end
      responses
    end
  end
end
