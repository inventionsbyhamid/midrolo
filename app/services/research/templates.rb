module Research
  # Reasons and summaries written from the run's own data, with no LLM: the scripted runner uses them in
  # fake-LLM mode, and the agent runner falls back to the summary when the model saved matches but no summary.
  module Templates
    REASON_LIMIT = Tools::SaveSponsorMatches::REASON_LIMIT
    SUMMARY_LIMIT = Tools::SaveSummary::MAX_LENGTH
    TIER_LABELS = { easy_yes: "easy yes", realistic: "realistic", long_shot: "long shot" }.freeze

    module_function

    # "Your audience shares 6 taste signals with Notion fans (Remote Work, Side Projects, Early Adopters)."
    # plus " Seen sponsoring The Founder's Ledger." for a proven sponsor; always under 200 characters.
    def reason(toolkit, scored)
      brand = scored.candidate.entity
      tags = shared_tags(toolkit, brand)
      proven = proven_show(scored)
      3.downto(1).each do |shown|
        text = reason_text(brand, tags, shown, proven)
        return text if text.length <= REASON_LIMIT
      end
      reason_text(brand, tags, 1, proven).truncate(REASON_LIMIT)
    end

    def summary(toolkit, scored_list)
      report = toolkit.report
      basis = report.direct? ? "your show's own Qloo profile" : "a proxy profile built from shows and topics like yours"
      tastes = toolkit.audience_tags.first(3).map(&:name)
      tiers = scored_list.map(&:tier).tally
      tier_line = TIER_LABELS.filter_map { |tier, label| "#{tiers[tier]} #{label}" if tiers[tier] }.to_sentence
      proven = scored_list.count { |s| proven_show(s) }
      top = scored_list.first(3).map { |s| s.candidate.entity.name }
      [
        "Built from #{basis}.",
        ("Your listeners' tastes center on #{tastes.to_sentence}." if tastes.any?),
        "We ranked #{scored_list.size} #{'sponsor'.pluralize(scored_list.size)}: #{tier_line.presence || 'none yet'}" \
          "#{"; #{proven} already #{proven == 1 ? 'sponsors' : 'sponsor'} similar podcasts" if proven.positive?}.",
        ("Start with #{top.to_sentence}." if top.any?)
      ].compact.join(" ").truncate(SUMMARY_LIMIT)
    end

    def reason_text(brand, tags, shown, proven)
      text = if tags.any?
        "Your audience shares #{tags.size} taste #{'signal'.pluralize(tags.size)} with #{brand.name} fans (#{tags.first(shown).join(', ')})."
      else
        "Your audience's taste profile has a strong affinity for #{brand.name}."
      end
      proven ? "#{text} Seen sponsoring #{proven}." : text
    end

    def shared_tags(toolkit, brand)
      (toolkit.explanations[brand.id].presence || toolkit.shared_audience_tags(brand)).map(&:name).uniq
    end

    # The newest similar show the brand sponsored, or nil.
    def proven_show(scored)
      item = Matching::Evidence.items(scored.candidate.proven_evidence).first
      Matching::Evidence.value(item, :show).presence
    end
  end
end
