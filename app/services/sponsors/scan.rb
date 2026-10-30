module Sponsors
  # Finds the sponsor reads in a podcast's episodes. AI-first since 2026-10-30 (the user's call, after production
  # showed the pattern stage finding 73 reads on its own and the model 2,531). Precision first: a wrong sponsor is worse
  # than a missed one.
  #
  #   1. Every episode whose notes (ad choices and privacy notices dropped) have at least MIN_NOTES characters goes to
  #      the model (Sponsors::LlmCheck), ten a call, on the catalog budget. Shorter notes are settled with no call. The
  #      pattern scan (Sponsors::Notes) never decides which episodes go: its candidates are hints in the prompt, and the
  #      link, code and evidence it read fill in what the model confirms.
  #   2. The model's answer is final for the episodes it checked: the reads it confirmed (is_sponsor, confidence 0.7 or
  #      more) that the notes back up. A confirmed read the pattern scan also found keeps the higher confidence, plus a
  #      little for a domain that recurs over a month of episodes.
  #   3. When the catalog budget is spent or the provider fails, the episodes it didn't check are left as they were,
  #      with nothing saved, for a later run (the daily sweep).
  #   4. Without a model (fake LLM mode: development and tests) the strong pattern reads stand in.
  #
  # Which episodes come here is Sponsors::Due's call (recent ones never checked, a few per podcast a run).
  #
  # Returns a Result: the detections; checked_episode_ids (the model answered, so their mentions are replaced);
  # settled_episode_ids (the AI-first scan is done with them: checked, or notes too short; they get
  # sponsor_ai_checked_at); scanned_episode_ids (they get sponsor_scanned_at); stage2 (:done, :not_needed, :fake,
  # :budget, :failed).
  class Scan
    BATCH = LlmCheck::MAX_EPISODES
    # Notes shorter than this, in characters, are settled without a call.
    MIN_NOTES = 80
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
    Result = Data.define(:detections, :checked_episode_ids, :settled_episode_ids, :scanned_episode_ids, :stage2)

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

      short, pending = @episodes.partition { |episode| @notes[episode.id].text.length < MIN_NOTES }
      verdicts, stage2 = check(pending)
      fake = stage2 == :fake
      detections = pending.flat_map { |episode| detections_for(episode, verdicts[episode.id], fake: fake) }
      # Without a model nothing is settled for the AI-first scan; every episode is still marked as read.
      settled = fake ? [] : verdicts.keys + short.map(&:id)
      Result.new(detections: detections, checked_episode_ids: verdicts.keys, settled_episode_ids: settled,
                 scanned_episode_ids: fake ? @episodes.map(&:id) : settled, stage2: stage2)
    end

    private

    # ---- recurrence ----

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

    # ---- the model ----

    # [{ episode_id => [Verdict] } for the episodes it checked, stage2].
    def check(pending)
      return [ {}, :fake ] if Llm.fake?
      return [ {}, :not_needed ] if pending.empty?

      verdicts = {}
      pending.each_slice(BATCH) do |batch|
        return [ verdicts, :budget ] unless Llm::Budget.allow?(:catalog, estimate_usd: LlmCheck.batch_estimate_usd)

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

    # The model's confirmed reads for an episode it checked; the strong pattern reads in fake mode; nothing for an
    # episode it didn't check.
    def detections_for(episode, verdicts, fake:)
      candidates = @notes[episode.id].candidates
      return candidates.select(&:strong?).map { |c| from_pattern(episode, c) } if fake
      return [] if verdicts.nil?

      found = verdicts.select { |v| v.sponsor && v.confidence >= MIN_LLM_CONFIDENCE }.map do |verdict|
        candidate = candidates.find { |c| c.same_brand?(as_candidate(verdict)) }
        from_verdict(episode, verdict, candidate)
      end
      found.uniq { |d| d.domain || Research::ProvenSponsorScan.key_for(d.name) }
    end

    def from_pattern(episode, candidate)
      Detection.new(episode: episode, name: candidate.name, domain: candidate.domain, url: candidate.url,
                    promo_code: candidate.promo_code, offer: candidate.offer, evidence: candidate.evidence,
                    detected_by: "pattern", confidence: pattern_confidence(candidate))
    end

    # The model's verdict: its proper name for the brand (the notes' own name when the model's didn't hold up and the
    # brand went by its domain), with the link, code and evidence sentence the pattern scan read for it preferred.
    def from_verdict(episode, verdict, candidate)
      name = Brand.domain_like?(verdict.name) && candidate && !candidate.domain_named? ? candidate.name : verdict.name
      confidence = [ verdict.confidence, (pattern_confidence(candidate) if candidate&.strong?) ].compact.max
      Detection.new(episode: episode, name: name, domain: verdict.domain || candidate&.domain, url: candidate&.url || verdict.url,
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
