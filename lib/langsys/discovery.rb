# frozen_string_literal: true

require "set"

module Langsys
  # The discovery queue and the reliability machinery around it (REG-2/3/6/7/8, GATE-5).
  #
  # Split out of +Client+ because these rules are one mechanism, not five: the debounce
  # decides *when* a batch leaves, the in-flight guard decides *whether*, the snapshot
  # decides *what*, the backoff decides *when again*, and the bookkeeping decides what may
  # never be sent twice. Reading them together is the only way to see that they agree.
  #
  # +clock+ is injected so the timing rules are testable without sleeping: a rule that can
  # only be exercised by wall-clock waits ends up with no test at all.
  class Discovery
    # REG-8: 3s, doubling, ceiling ~5min.
    BACKOFF_BASE = 3.0
    BACKOFF_CEILING = 300.0
    # REG-2: a burst from one render becomes one request.
    DEBOUNCE_SECONDS = 0.4
    # ...but a debounce alone starves a stream that never goes quiet: every new miss
    # pushes the window out and nothing is ever due. A ceiling on total wait bounds that.
    MAX_WAIT_SECONDS = 5.0

    # What a flush actually sent. Held separately from the live queue so the success
    # handler can clear exactly this and nothing else (REG-6).
    Snapshot = Struct.new(:phrase_keys, :block_ids, :block_categories, :items, keyword_init: true) do
      def empty? = items.empty?
    end

    attr_reader :retry_delay

    def initialize(project_id, clock: nil, debounce: DEBOUNCE_SECONDS, max_wait: MAX_WAIT_SECONDS)
      @project_id = project_id
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @debounce = debounce
      @max_wait = max_wait
      @dirty_since = nil
      @phrases = {}
      @blocks = {}
      # GATE-5: written only after the server confirms acceptance. Namespaced by project
      # so a marker can never answer for a different one.
      @registered = Set.new
      @mutex = Mutex.new
      @in_flight = false
      @retry_delay = nil
      @retry_at = nil
      @last_activity = nil
    end

    # -- queueing -------------------------------------------------------------

    def queue_phrase(phrase, category)
      key = [category, phrase]
      return if @registered.include?(marker(category, phrase))

      @phrases[key] = true
      touch
    end

    def queue_block(html, category, custom_id, phrases)
      return if @registered.include?(marker(category, custom_id))

      @blocks[custom_id] ||= {
        "content" => html, "category" => category, "custom_id" => custom_id, "phrases" => phrases
      }
      touch
    end

    def pending? = !@phrases.empty? || !@blocks.empty?
    def phrase_count = @phrases.size
    def block_count = @blocks.size
    def pending_phrases = @phrases.keys.map { |category, phrase| { "phrase" => phrase, "category" => category } }
    def pending_blocks = @blocks.values

    def clear
      @phrases.clear
      @blocks.clear
      @last_activity = nil
      @dirty_since = nil
    end

    def registered?(category, phrase) = @registered.include?(marker(category, phrase))

    # -- REG-2: debounce ------------------------------------------------------

    # Due once the burst has settled. Deliberately not an interval: an interval-only path
    # delays every registration by up to its full period, which is most of the renderer's
    # post-scroll grace.
    def due?
      return false unless pending?
      return true if @last_activity.nil?

      now = @clock.call
      return true if @dirty_since && (now - @dirty_since) >= @max_wait

      (now - @last_activity) >= @debounce
    end

    # -- REG-7: one send in flight at a time ----------------------------------

    # Returns false if a send is already running. Callers must not send on false.
    def begin_send
      @mutex.synchronize do
        return false if @in_flight

        @in_flight = true
      end
    end

    def end_send
      @mutex.synchronize { @in_flight = false }
    end

    def in_flight? = @mutex.synchronize { @in_flight }

    # -- REG-8: backoff -------------------------------------------------------

    def backing_off?
      return false if @retry_at.nil?

      @clock.call < @retry_at
    end

    def penalise
      @retry_delay = @retry_delay.nil? ? BACKOFF_BASE : [@retry_delay * 2, BACKOFF_CEILING].min
      @retry_at = @clock.call + @retry_delay
      @retry_delay
    end

    def reset_backoff!
      @retry_delay = nil
      @retry_at = nil
    end

    # -- REG-6: snapshot ------------------------------------------------------

    # Freeze what is about to be sent. Everything queued after this point stays in the
    # live queue and is sent by a later flush; nothing about the response is allowed to
    # touch it.
    def snapshot(batch_limit)
      phrase_keys = @phrases.keys.dup
      block_ids = @blocks.keys.dup

      items = phrase_keys.map do |category, phrase|
        { "phrase" => phrase, "category" => category == UNCATEGORIZED ? nil : category }
      end
      items += block_ids.map { |id| block_item(@blocks[id]) }

      # Categories are captured HERE, not re-read in #confirm: if the live queue is
      # cleared while the request is open, the block is gone by then and the marker would
      # be written under the wrong namespace — a bookkeeping entry that answers for the
      # wrong category, which GATE-5 makes permanent.
      categories = block_ids.to_h { |id| [id, @blocks[id] && @blocks[id]["category"]] }

      Snapshot.new(phrase_keys: phrase_keys, block_ids: block_ids, block_categories: categories,
                   items: items.each_slice(batch_limit).to_a)
    end

    # GATE-5: mark and clear THE SNAPSHOT, only after confirmed acceptance.
    def confirm(snapshot)
      snapshot.phrase_keys.each do |category, phrase|
        @registered << marker(category, phrase)
        @phrases.delete([category, phrase])
      end
      snapshot.block_ids.each do |id|
        @registered << marker(snapshot.block_categories[id], id)
        @blocks.delete(id)
      end
      return unless @phrases.empty? && @blocks.empty?

      @last_activity = nil
      @dirty_since = nil
    end

    private

    def touch
      now = @clock.call
      @dirty_since ||= now
      @last_activity = now
    end

    def marker(category, value)
      "#{@project_id}::#{category || UNCATEGORIZED}::#{value}"
    end

    def block_item(block)
      item = {
        "type" => "content_block",
        "custom_id" => block["custom_id"],
        "content" => block["content"],
        "phrases" => Array(block["phrases"]).map { |p| { "phrase" => p } }
      }
      category = block["category"]
      item["category"] = category unless category.nil? || category == UNCATEGORIZED
      item
    end
  end
end
