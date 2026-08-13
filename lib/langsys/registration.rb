# frozen_string_literal: true

require "digest"

module Langsys
  # Deterministic id for a content block: +md5+ of +category+ and the phrases joined with
  # +|+ — the scheme the backend's stored content blocks actually use (verified against the
  # live catalog), so a block registered by any server-side SDK resolves to the same id.
  def self.generate_custom_id(category, phrases)
    tokens = [category.nil? ? "" : category, *phrases]
    Digest::MD5.hexdigest(tokens.join("|"))
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
