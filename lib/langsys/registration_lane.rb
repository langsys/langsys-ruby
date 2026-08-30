# frozen_string_literal: true

module Langsys
  # Client's registration lane: the discovery queue's public surface, the flush paths, and
  # the rules governing them — REG-2/3/6/7/8/9/10/11 plus the GATE-2 and GATE-5
  # bookkeeping they carry.
  #
  # Separated from Client because these rules constrain one another and are only correct
  # read together: the debounce decides when a batch leaves, the in-flight guard whether,
  # the snapshot what, the backoff when again, and the bookkeeping what may never be sent
  # twice. Discovery owns the state machine; this owns the policy and the network edge.
  module RegistrationLane
    # -- discovery queue ------------------------------------------------------

    def has_pending? = @discovery.pending?
    def pending_phrases = @discovery.pending_phrases
    def pending_content_blocks = @discovery.pending_blocks
    def clear_pending = @discovery.clear

    # GATE-5 bookkeeping: true only once the server confirmed acceptance.
    def registered?(category, phrase) = @discovery.registered?(category, phrase)

    # REG-2: whether the current burst has settled and is ready to send.
    def flush_due? = @discovery.due?

    # REG-8: the current backoff delay, or nil when not backing off.
    def retry_delay = @discovery.retry_delay

    # REG-2: send only once the burst has settled. This is the automatic path; it is
    # debounce-driven rather than interval-driven, so a fixed tick is never the only way
    # a registration leaves.
    def flush_if_due
      return empty_result(success: true) unless @discovery.due?

      flush_pending
    end

    # REG-3: the end-of-context flush. Best-effort by construction — it must never raise
    # into a shutdown path, and it cannot be relied on (no hook runs on an OOM kill).
    def flush_on_shutdown
      flush_pending
    rescue StandardError => e
      @logger&.warn("langsys: shutdown flush failed (#{e.class}: #{e.message})")
      empty_result(success: false, reason: "shutdown_failed")
    end

    # Register queued (discovered) phrases and content blocks.
    #
    # One specified behaviour across every path (REG-10): it never raises into a render
    # path, it always logs, and it never returns a success-shaped result for work that did
    # not happen — a skipped write reports +success: false+ with a reason, because a caller
    # that correctly checks the return value must not be told it worked.
    def flush_pending(refresh: false)
      return empty_result(success: true) unless @discovery.pending?

      # REG-7: exactly one send in flight. A second caller is told so rather than being
      # handed a success it did not earn.
      return empty_result(success: false, reason: "in_flight") unless @discovery.begin_send

      begin
        # REG-8: a failing endpoint is not retried until its delay has elapsed.
        return empty_result(success: false, reason: "backing_off") if @discovery.backing_off?

        # Resolving capability is itself a network call, so it can fail. REG-10 says this
        # method has exactly one behaviour and throwing is not it.
        begin
          writable = can_write?(refresh: refresh)
        rescue Langsys::Error => e
          # GATE-2 again: unavailable is not "no". Retain everything and back off, because
          # an unreachable server is exactly what the backoff exists for.
          delay = @discovery.penalise
          @logger&.warn("langsys: could not resolve the write decision (#{e.class}: #{e.message}); " \
                        "#{@discovery.phrase_count} phrase(s) stay queued, retrying in #{delay}s")
          return empty_result(success: false, reason: "decision_unavailable")
        end

        unless writable
          # GATE-2: the queue is RETAINED. Discarding it here would lose phrases because
          # the write decision was unavailable, and the decision can change per response.
          warn_unusable_capability
          return empty_result(success: false, reason: "not_write_enabled")
        end

        send_snapshot
      ensure
        @discovery.end_send
      end
    end

    # -- registration (write key) --------------------------------------------

    def register_phrases(phrases)
      require_write!
      registrar.register_phrases(phrases)
    end

    def register_content_block(content, phrases, category: nil, custom_id: nil, label: nil)
      require_write!
      registrar.register_content_block(content, phrases, category: category, custom_id: custom_id, label: label)
    end

    # Register any of +local_phrases+ not already in the catalog, then refetch.
    def sync(local_phrases, locale: nil)
      loc = effective_locale(locale)
      catalog = @catalog.get(loc, use_cache: false)
      existing = existing_keys(catalog)

      new_items = local_phrases.reject do |phrase|
        text = phrase.is_a?(String) ? phrase : (phrase[:phrase] || phrase["phrase"])
        category = phrase.is_a?(String) ? nil : (phrase[:category] || phrase["category"])
        existing.include?("#{category || UNCATEGORIZED}::#{text}")
      end

      synced = false
      if !new_items.empty? && can_write?
        registrar.register_phrases(new_items)
        @catalog.clear(loc)
        @catalog.get(loc, use_cache: false)
        synced = true
      end

      {
        "new_phrases" => new_items.map { |p| p.is_a?(String) ? p : (p[:phrase] || p["phrase"]) },
        "synced" => synced
      }
    end

    # Internal (used by the HTML page translator): queue a discovered content block.
    def queue_content_block(html, category, custom_id, phrases)
      @discovery.queue_block(html, category, custom_id, phrases)
    end

    private

    # REG-6: send exactly the snapshot, and let the success handler clear exactly the
    # snapshot. Anything queued while the request was open stays queued.
    def send_snapshot
      begin
        limit = registrar.batch_limit
      rescue Langsys::Error => e
        delay = @discovery.penalise
        @logger&.warn("langsys: could not resolve the batch limit (#{e.class}: #{e.message}); " \
                      "queue retained, retrying in #{delay}s")
        return empty_result(success: false, reason: "send_failed")
      end

      snapshot = @discovery.snapshot(limit)
      phrases = snapshot.phrase_keys.size
      blocks = snapshot.block_ids.size

      begin
        snapshot.items.each { |chunk| registrar.register_items(chunk) }
      rescue Langsys::Error => e
        # REG-8: retain the queue and back off. GATE-5: mark nothing — a timeout or a 422
        # that wrote a false "already registered" record is the failure this prevents.
        delay = @discovery.penalise
        @logger&.warn("langsys: registration failed (#{e.class}: #{e.message}); " \
                      "#{phrases} phrase(s) / #{blocks} block(s) stay queued, retrying in #{delay}s")
        return empty_result(success: false, reason: "send_failed")
      end

      @discovery.confirm(snapshot)
      @discovery.reset_backoff!
      @catalog.clear # new items exist server-side now; refetch next time
      { "phrases" => phrases, "content_blocks" => blocks, "success" => true }
    end

    def empty_result(success:, reason: nil)
      result = { "phrases" => 0, "content_blocks" => 0, "success" => success }
      result["reason"] = reason if reason
      result
    end

    # OBS-1: surface an unusable capability at least once — and only once, so a read-key
    # deployment does not warn on every flush for the life of the process.
    def warn_unusable_capability
      return if @warned_unusable

      @warned_unusable = true
      @logger&.warn("langsys: this session is not write-enabled, so #{@discovery.phrase_count} " \
                    "discovered phrase(s) and #{@discovery.block_count} block(s) cannot be " \
                    "registered; they stay queued in case the decision changes")
    end

    def queue_missing(phrase, category, catalog = nil)
      cat = category || UNCATEGORIZED

      if (stem = Ellipsis.ellipsis_stem(phrase))
        if Ellipsis.truncated_twin?(catalog, cat, stem, phrase)
          @logger&.warn("langsys: not registering #{phrase.inspect} — a longer catalog entry " \
                        "shares its prefix, so this is upstream truncation rather than a phrase")
          return
        end
        @logger&.warn("langsys: #{phrase.inspect} ends in an ellipsis. If that is upstream " \
                      "truncation it will be translated and stored separately from the full text; " \
                      "if it is deliberate (\"Loading…\") no action is needed.")
      end

      @discovery.queue_phrase(phrase, cat)
    end

    # The text before a trailing … or ..., or nil when there is none.

    def require_write!
      return if can_write?

      raise AuthorizationError.new("Langsys: the server has not write-enabled this session.",
                                   status_code: 403)
    end

    def registrar
      @registrar ||= Registrar.new(@http, @config.project_id, batch_limit: authorize.batch_limit)
    end

    def existing_keys(catalog)
      keys = Set.new
      catalog.each do |category, entries|
        next unless entries.is_a?(Hash)

        entries.each do |phrase, value|
          next if phrase.start_with?("__") && phrase.end_with?("__")

          if value.is_a?(Hash)
            value.each_key { |child| keys << "#{category}::#{child}" }
          else
            keys << "#{category}::#{phrase}"
          end
        end
      end
      keys
    end
  end
end
