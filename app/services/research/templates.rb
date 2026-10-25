module Research
  # Reasons and summaries written from the run's own data, with no LLM: the scripted runner uses them in
  # fake-LLM mode, and the agent runner falls back to the summary when the model saved matches but no summary.
  # They keep the agent's rules (R99): a reason is one plain sentence of 25 words or fewer, the summary 1 to 3
  # bullets of 20 words or fewer, and the audience is spoken of as a group. Neutral wording ("this audience") reads
  # right on the owner's report and on a public sample alike.
  module Templates
    REASON_LIMIT = SponsorMatch::REASON_LENGTH
    REASON_WORDS = SponsorMatch::REASON_WORDS
    SUMMARY_WORDS = Report::SUMMARY_POINT_WORDS
    SUMMARY_LENGTH = Report::SUMMARY_POINT_LENGTH
    TIER_LABELS = { easy_yes: "easy yes", realistic: "realistic", long_shot: "long shot" }.freeze

    module_function

    # "Notion fans share this audience's love of Remote Work, Side Projects and Early Adopters." Fewer tastes are named
    # until it fits. The row's chips already count the tastes and name a proven show, so the reason names the tastes,
    # and the proven show only when no taste is shared.
    def reason(toolkit, scored)
      brand = scored.candidate.entity
      tags = shared_tags(toolkit, brand)
      proven = proven_show(scored)
      3.downto(1).each do |shown|
        text = reason_text(brand.name, tags, shown, proven)
        return text if Llm::PlainText.word_count(text) <= REASON_WORDS && text.length <= REASON_LIMIT
      end
      Llm::PlainText.clip_words(reason_text(brand.name, tags, 1, proven), REASON_WORDS, max_chars: REASON_LIMIT)
    end

    # The At a glance bullets: who the audience is, how the sponsors rank, and for a proxy profile what it was built
    # from.
    def summary(toolkit, scored_list)
      tastes = toolkit.audience_tags.first(3).map(&:name)
      tiers = scored_list.map(&:tier).tally
      tier_line = TIER_LABELS.filter_map { |tier, label| "#{tiers[tier]} #{label}" if tiers[tier] }.join(", ")
      proven = scored_list.count { |s| proven_show(s) }
      [
        (tastes.any? ? "This audience leans toward #{Copy.and_list(tastes)}." : "This audience's tastes come from #{basis(toolkit)}."),
        "We ranked #{scored_list.size} #{'sponsor'.pluralize(scored_list.size)}: #{tier_line.presence || 'none yet'}." \
          "#{" #{proven} already #{proven == 1 ? 'sponsors' : 'sponsor'} similar podcasts." if proven.positive?}",
        ("Built from shows and topics like this one, since Qloo doesn't know the show itself." unless toolkit.report.direct?)
      ].compact.map { |bullet| Llm::PlainText.clip_words(bullet, SUMMARY_WORDS, max_chars: SUMMARY_LENGTH) }
    end

    def reason_text(name, tags, shown, proven)
      if tags.any?
        "#{name} fans share this audience's love of #{Copy.and_list(tags.first(shown))}."
      elsif proven
        "#{name} already sponsors #{proven}, a show much like this one."
      else
        "This audience loves #{name} more than most people do."
      end
    end

    def shared_tags(toolkit, brand)
      (toolkit.explanations[brand.id].presence || toolkit.shared_audience_tags(brand)).map(&:name).uniq
    end

    # The newest similar show the brand sponsored, or nil.
    def proven_show(scored)
      item = Matching::Evidence.items(scored.candidate.proven_evidence).first
      Matching::Evidence.value(item, :show).presence
    end

    def basis(toolkit) = toolkit.report.direct? ? "the show's own Qloo profile" : "shows and topics like this one"
  end
end
