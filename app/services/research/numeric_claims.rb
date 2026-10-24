module Research
  # The §6 numeric-claim guardrail (R38): a match reason or the summary may cite only numbers found in this
  # run's stored data. It's an allowlist, not a heuristic.
  #
  # Claims are integers, decimals, percentages, multipliers ("2x"), ordinals ("3rd") and both ends of a range
  # ("25–34"). Digits glued to letters ("AG1", "1Password", "Web3") are names, not claims. A percentage must
  # match a percentage in the data (affinity); any other number must match an allowed value.
  class NumericClaims
    AGE_BOUNDS = %w[24 25 29 30 34 35 44 45 54 55].freeze
    TOKEN = /(?<![[:alnum:]])\d+(?:[.,]\d+)*(?:%|×|x(?![[:alpha:]])|(?:st|nd|rd|th)(?![[:alpha:]]))?(?![[:alnum:]])/i
    DIGITS = /\d+(?:[.,]\d+)*/

    Allowed = Data.define(:numbers, :percents) do
      def merge(other) = with(numbers: numbers | other.numbers, percents: percents | other.percents)
    end

    # The numeric claims in text, as written.
    def self.tokens(text) = text.to_s.scan(TOKEN)

    # One spelling per number: "1,500" => "1500", "0.80" => "0.8", "07" => "7".
    def self.normalize(digits)
      int, frac = digits.to_s.delete(",").split(".", 2)
      int = int.to_s.sub(/\A0+(?=\d)/, "")
      frac = frac.to_s.sub(/0+\z/, "")
      frac.empty? ? int : "#{int}.#{frac}"
    end

    def initialize(toolkit)
      @toolkit = toolkit
    end

    # The claims in text the allowlist doesn't cover, as written.
    def unsupported(text, allowed)
      self.class.tokens(text).reject { |token| allowed?(token, allowed) }.uniq
    end

    # What one match's reason may cite: its fit score, affinity (0.82 and 82%), shared-tag and proven counts,
    # its evidence dates, digits in its name, tags and evidence titles, plus the run-wide values.
    def for_match(scored)
      brand = scored.candidate.entity
      evidence = scored.candidate.proven_evidence
      numbers = base_numbers.dup
      percents = Set.new
      numbers << scored.fit_score.to_s
      if (affinity = scored.candidate.affinity)
        numbers << self.class.normalize(format("%.2f", affinity))
        percent = (affinity.to_f * 100).round.to_s
        numbers << percent
        percents << percent
      end
      tag_names = tag_lists(brand)
      numbers.merge(tag_names.map { |names| names.size.to_s })
      add_evidence(numbers, evidence)
      add_digits(numbers, brand.name, *tag_names.flatten)
      Allowed.new(numbers: numbers, percents: percents)
    end

    # What the summary may cite: everything any saved match may cite, plus the profile's own counts.
    def for_summary
      matches = report.sponsor_matches.to_a
      allowed = Allowed.new(numbers: profile_numbers(matches), percents: Set.new)
      matches.filter_map { |m| @toolkit.scored[m.brand_entity_id] }.reduce(allowed) { |all, s| all.merge(for_match(s)) }
    end

    private

    delegate :report, :show, to: :@toolkit

    def allowed?(token, allowed)
      value = self.class.normalize(token[DIGITS])
      token.end_with?("%") ? allowed.percents.include?(value) : allowed.numbers.include?(value)
    end

    # The shared-tag lists a reason may count: the ones reasons use, the R27 overlap and Qloo compare's.
    def tag_lists(brand)
      [ Templates.shared_tags(@toolkit, brand), @toolkit.shared_audience_tags(brand).map(&:name).uniq,
        Array(@toolkit.explanations[brand.id]).map(&:name).uniq ]
    end

    def add_evidence(numbers, evidence)
      items = Matching::Evidence.items(evidence)
      numbers << Matching::Evidence.count(evidence).to_s << items.size.to_s
      numbers << items.map { |i| Matching::Evidence.value(i, :show) }.uniq.size.to_s
      items.each do |item|
        time = Matching::Evidence.published_at(item)
        numbers.merge([ time.year, time.month, time.day ].map(&:to_s)) if time
        add_digits(numbers, Matching::Evidence.value(item, :show), Matching::Evidence.value(item, :episode_title))
      end
    end

    # Age buckets, the show's downloads, and digits in its title and feed titles (episode numbers).
    def base_numbers
      @base_numbers ||= begin
        numbers = Set.new(AGE_BOUNDS)
        numbers << show.downloads_per_episode.to_s if show.downloads_per_episode
        add_digits(numbers, show.title, *@toolkit.feed.episodes.map(&:title))
      end
    end

    def profile_numbers(matches)
      numbers = base_numbers.dup
      numbers << matches.size.to_s << @toolkit.scored.size.to_s
      numbers << matches.count { |m| m.evidence.dig("proven", "count").to_i.positive? }.to_s
      numbers.merge(matches.map(&:tier).tally.values.map(&:to_s))
      numbers.merge([ @toolkit.seed_count, @toolkit.seed_entity_ids.size, @toolkit.seed_tag_ids.size ].map(&:to_s))
      numbers << Array(report.heatmap.is_a?(Hash) ? report.heatmap["points"] : nil).size.to_s
      audience = report.audience.is_a?(Hash) ? report.audience : {}
      audience.each_value do |list|
        numbers << Array(list).size.to_s
        add_digits(numbers, *Array(list).filter_map { |item| item["name"] if item.is_a?(Hash) })
      end
      add_digits(numbers, *report.seed_items.pluck("name"))
    end

    def add_digits(numbers, *texts)
      texts.each { |text| text.to_s.scan(DIGITS).each { |digits| numbers << self.class.normalize(digits) } }
      numbers
    end
  end
end
