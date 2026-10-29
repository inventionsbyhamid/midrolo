module Sponsors
  # Finds the sponsor reads in a podcast's episodes (build spec L2). Precision first: a wrong sponsor is worse than a
  # missed one.
  #
  #   1. Patterns (Sponsors::Notes) per episode: lead-ins, "Sponsors" blocks, promo codes, vanity paths, offers.
  #   2. Recurrence across the podcast's recent episodes: a strong read that recurs (3+ episodes over 30+ days) gains
  #      confidence; a code or vanity link in nearly every episode's footer is more likely the show's own plug, so only
  #      the model may confirm it.
  #   3. The model (Sponsors::LlmCheck), for episodes with any candidate, in batches of 10, on the catalog budget.
  #      Skipped in fake LLM mode, and once the catalog's daily budget is spent or the provider fails.
  #
  # An episode the model checked gets exactly what it confirmed, plus strong pattern reads it didn't reject. Any other
  # episode gets its strong pattern reads only; weak hints are never saved without the model.
  #
  # Returns a Result: the detections; checked_episode_ids (the model's answer is complete for these, so their mentions
  # are replaced); scanned_episode_ids (done: no candidates, checked, or fake mode; an episode whose check was skipped
  # for budget or an error stays unscanned so a later scan can check it); stage2 (:done, :not_needed, :fake, :budget,
  # :failed).
  class Scan
    BATCH = LlmCheck::MAX_EPISODES
    # What one batch is assumed to cost when checking the catalog budget (about $0.003 on the cheap model).
    BATCH_ESTIMATE_USD = 0.02
    MIN_LLM_CONFIDENCE = 0.7
    PATTERN_CONFIDENCE = { lead_in: 0.9, section: 0.9, code: 0.8, vanity: 0.75 }.freeze
    RECURRENCE_BONUS = 0.05
    MAX_CONFIDENCE = 0.95
    RECURRING_EPISODES = 3
    RECURRING_SPAN = 30.days
    FOOTER_SHARE = 0.8
    FOOTER_MIN_EPISODES = 6
    # The podcast's newest episodes read for recurrence and for its own site.
    CONTEXT_EPISODES = 50
    PROVIDER_ERRORS = [ Llm::Error, RubyLLM::Error, Faraday::Error, JSON::ParserError ].freeze

    Detection = Data.define(:episode, :name, :domain, :url, :promo_code, :offer, :evidence, :detected_by, :confidence)
    Result = Data.define(:detections, :checked_episode_ids, :scanned_episode_ids, :stage2)

    def self.call(podcast, episodes) = new(podcast, episodes).call

    def initialize(podcast, episodes)
      @podcast = podcast
      @episodes = episodes.to_a.uniq(&:id)
    end

    def call
      recent = @podcast.episodes.newest_first.limit(CONTEXT_EPISODES).to_a
      @context = Context.for(@podcast, episodes: recent)
      @notes = @episodes.to_h { |episode| [ episode.id, Notes.new(episode.description, @context) ] }
      weigh_recurrence(recent)

      pending = @episodes.select { |episode| @notes[episode.id].candidates.any? }
      verdicts, stage2 = check(pending)
      detections = @episodes.flat_map { |episode| detections_for(episode, verdicts[episode.id]) }
      unchecked = %i[budget failed].include?(stage2) ? pending.map(&:id) - verdicts.keys : []
      Result.new(detections: detections, checked_episode_ids: verdicts.keys,
                 scanned_episode_ids: @episodes.map(&:id) - unchecked, stage2: stage2)
    end

    private

    # ---- 2. recurrence ----

    def weigh_recurrence(recent)
      episodes = (recent + @episodes).uniq(&:id)
      seen = Hash.new { |hash, key| hash[key] = [] }
      episodes.each do |episode|
        notes = @notes[episode.id] || Notes.new(episode.description, @context)
        notes.domains.each { |domain| seen[domain] << episode.published_at }
      end
      @recurring = seen.select { |_, dates| recurring?(dates) }.keys.to_set
      @footer = seen.select { |_, dates| episodes.size >= FOOTER_MIN_EPISODES && dates.size >= episodes.size * FOOTER_SHARE }.keys.to_set
      @notes.each_value do |notes|
        notes.candidates.each do |candidate|
          next unless candidate.domain && @footer.include?(candidate.domain)
          next if candidate.signals.intersect?(%i[lead_in section])

          candidate.signals.subtract(%i[code vanity]) << :hint
        end
      end
    end

    def recurring?(dates)
      dates = dates.compact
      dates.size >= RECURRING_EPISODES && dates.max - dates.min >= RECURRING_SPAN
    end

    # ---- 3. the model ----

    # [{ episode_id => [Verdict] } for the episodes it checked, stage2].
    def check(pending)
      return [ {}, :not_needed ] if pending.empty?
      return [ {}, :fake ] if Llm.fake?

      verdicts = {}
      pending.each_slice(BATCH) do |batch|
        return [ verdicts, :budget ] unless Llm::Budget.allow?(:catalog, estimate_usd: BATCH_ESTIMATE_USD)

        found = LlmCheck.call(@podcast, batch.map { |episode| [ episode, @notes[episode.id] ] }, @context)
        batch.each { |episode| verdicts[episode.id] = found.fetch(episode.id, []) }
      rescue Llm::BudgetExceeded
        return [ verdicts, :budget ]
      rescue *PROVIDER_ERRORS => e
        Rails.error.report(e, handled: true, context: { podcast_id: @podcast.id, job: "Sponsors::Scan" })
        return [ verdicts, :failed ]
      end
      [ verdicts, :done ]
    end

    # ---- the answer per episode ----

    def detections_for(episode, verdicts)
      candidates = @notes[episode.id].candidates
      return candidates.select(&:strong?).map { |c| from_pattern(episode, c) } if verdicts.nil?

      confirmed = verdicts.select { |v| v.sponsor && v.confidence >= MIN_LLM_CONFIDENCE }
      rejected = verdicts.reject(&:sponsor)
      found = confirmed.map do |verdict|
        candidate = candidates.find { |c| c.same_brand?(as_candidate(verdict)) }
        from_verdict(episode, verdict, candidate)
      end
      candidates.select(&:strong?).each do |candidate|
        next if rejected.any? { |v| candidate.same_brand?(as_candidate(v)) }
        next if found.any? { |d| candidate.same_brand?(as_candidate(d)) }

        found << from_pattern(episode, candidate)
      end
      found.uniq { |d| d.domain || Research::ProvenSponsorScan.key_for(d.name) }
    end

    def from_pattern(episode, candidate)
      Detection.new(episode: episode, name: candidate.name, domain: candidate.domain, url: candidate.url,
                    promo_code: candidate.promo_code, offer: candidate.offer, evidence: candidate.evidence,
                    detected_by: "pattern", confidence: pattern_confidence(candidate))
    end

    # The model's verdict, with what the notes themselves showed for the brand preferred: the name as written, the
    # link, the code and the evidence sentence.
    def from_verdict(episode, verdict, candidate)
      name = candidate && !candidate.domain_named? ? candidate.name : verdict.name
      confidence = [ verdict.confidence, (pattern_confidence(candidate) if candidate&.strong?) ].compact.max
      Detection.new(episode: episode, name: name, domain: candidate&.domain || verdict.domain, url: candidate&.url || verdict.url,
                    promo_code: candidate&.promo_code || verdict.promo_code, offer: verdict.offer || candidate&.offer,
                    evidence: candidate&.evidence || verdict.evidence, detected_by: "llm", confidence: confidence.round(2))
    end

    def pattern_confidence(candidate)
      base = candidate.signals.filter_map { |signal| PATTERN_CONFIDENCE[signal] }.max.to_f
      base += RECURRENCE_BONUS if candidate.domain && @recurring.include?(candidate.domain)
      [ base, MAX_CONFIDENCE ].min.round(2)
    end

    def as_candidate(found)
      Notes::Candidate.new(name: found.name).tap { |c| c.domain = found.domain }
    end
  end
end
