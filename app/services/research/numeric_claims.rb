module Research
  # The §6 numeric-claim guardrail (R38): a match reason or the summary may cite only numbers found in this
  # run's stored data. It's an allowlist, not a heuristic. Claims come in three kinds:
  #   percent — "40%", "40 %", "25 percent", "25 per cent", "25 pct": only an affinity percentage passes.
  #   name    — magnitudes ("10k", "3.5k", "2M", "$5M", "2 million"), decades ("40s") and multipliers
  #             ("3x", "x3"): only when that exact token is part of an allowed name (a brand called "3M").
  #   number  — integers, decimals, ordinals ("3rd") and both ends of a range ("25–34"): any allowed value.
  # Digits glued to letters ("AG1", "1Password", "Web3") are names, not claims.
  class NumericClaims
    AGE_BOUNDS = %w[24 25 29 30 34 35 44 45 54 55].freeze
    PERCENT = /\d+(?:[.,]\d+)?\s*(?:%|(?:percent|per\s?cent|pct)(?![[:alpha:]]))/i
    MAGNITUDE = /\$?\d+(?:[.,]\d+)*(?:\s?(?:thousand|million|billion)|bn|mn|[kmb])(?![[:alnum:]])/i
    DECADE = /\d*0s(?![[:alnum:]])/i
    MULTIPLIER = /\d+(?:\.\d+)?\s?[x×](?![[:alnum:]])|[x×]\s?\d+(?:\.\d+)?(?![[:alnum:]])/i
    NUMBER = /\$?\d+(?:[.,]\d+)*(?:st|nd|rd|th)?(?![[:alnum:]])/i
    TOKEN = /(?<![[:alnum:]])(?:(?<percent>#{PERCENT})|(?<name>#{MAGNITUDE}|#{DECADE}|#{MULTIPLIER})|(?<number>#{NUMBER}))/i
    DIGITS = /\d+(?:[.,]\d+)*/

    Allowed = Data.define(:numbers, :percents, :names) do
      def self.empty = new(numbers: Set.new, percents: Set.new, names: Set.new)

      def merge(other)
        with(numbers: numbers | other.numbers, percents: percents | other.percents, names: names | other.names)
      end
    end

    # The numeric claims in text, as written.
    def self.tokens(text) = claims(text).map(&:first)

    # [[token, :percent | :name | :number]] in order.
    def self.claims(text)
      text.to_s.to_enum(:scan, TOKEN).map do
        match = Regexp.last_match
        kind = %i[percent name number].find { |k| match[k] }
        [ match[0], kind ]
      end
    end

    # One spelling per number: "1,500" => "1500", "0.80" => "0.8", "07" => "7".
    def self.normalize(digits)
      int, frac = digits.to_s.delete(",").split(".", 2)
      int = int.to_s.sub(/\A0+(?=\d)/, "")
      frac = frac.to_s.sub(/0+\z/, "")
      frac.empty? ? int : "#{int}.#{frac}"
    end

    # A name-kind token as compared: "3.5 K" => "3.5k".
    def self.name_key(token) = token.downcase.gsub(/\s+/, "")

    # The claims in text the allowlist doesn't cover, as written.
    def self.unsupported(text, allowed)
      claims(text).reject { |token, kind| allowed?(token, kind, allowed) }.map(&:first).uniq
    end

    def self.allowed?(token, kind, allowed)
      case kind
      when :percent then allowed.percents.include?(normalize(token[DIGITS]))
      when :name then allowed.names.include?(name_key(token))
      else allowed.numbers.include?(normalize(token[DIGITS]))
      end
    end

    # The building blocks below add to an allowlist in place and return it; Pitches::Inputs uses them too.

    # An affinity cited as a decimal (0.82) or a percentage (82, 82%).
    def self.add_affinity(allowed, affinity)
      return allowed unless affinity

      percent = (affinity.to_f * 100).round.to_s
      allowed.numbers << normalize(format("%.2f", affinity)) << percent
      allowed.percents << percent
      allowed
    end

    # Proven-sponsor evidence: its counts, each item's date, and the sponsored shows' and episodes' titles.
    def self.add_evidence(allowed, evidence)
      items = Matching::Evidence.items(evidence)
      allowed.numbers << Matching::Evidence.count(evidence).to_s << items.size.to_s
      allowed.numbers << items.map { |i| Matching::Evidence.value(i, :show) }.uniq.size.to_s
      items.each do |item|
        time = Matching::Evidence.published_at(item)
        allowed.numbers.merge([ time.year, time.month, time.day ].map(&:to_s)) if time
        add_texts(allowed, Matching::Evidence.value(item, :show), Matching::Evidence.value(item, :episode_title))
      end
      allowed
    end

    # Names and titles: their digits are allowed numbers, and their own magnitude-style tokens ("3M") are
    # allowed names.
    def self.add_texts(allowed, *texts)
      texts.each do |text|
        text.to_s.scan(DIGITS).each { |digits| allowed.numbers << normalize(digits) }
        claims(text).each { |token, kind| allowed.names << name_key(token) if kind == :name }
      end
      allowed
    end

    def initialize(toolkit)
      @toolkit = toolkit
    end

    # The claims in text the allowlist doesn't cover, as written.
    def unsupported(text, allowed) = self.class.unsupported(text, allowed)

    # What one match's reason may cite: its fit score, affinity (0.82 and 82%), shared-tag and proven counts,
    # its evidence dates, its name, tags and evidence titles, plus the run-wide values.
    def for_match(scored)
      brand = scored.candidate.entity
      allowed = base.with(numbers: base.numbers.dup, names: base.names.dup, percents: Set.new)
      allowed.numbers << scored.fit_score.to_s
      self.class.add_affinity(allowed, scored.candidate.affinity)
      tag_names = tag_lists(brand)
      allowed.numbers.merge(tag_names.map { |names| names.size.to_s })
      self.class.add_evidence(allowed, scored.candidate.proven_evidence)
      self.class.add_texts(allowed, brand.name, *tag_names.flatten)
    end

    # What the summary may cite: everything any saved match may cite, plus the profile's own counts.
    def for_summary
      matches = report.sponsor_matches.to_a
      profile = profile_allowed(matches)
      matches.filter_map { |m| @toolkit.scored[m.brand_entity_id] }.reduce(profile) { |all, s| all.merge(for_match(s)) }
    end

    private

    delegate :report, :show, to: :@toolkit

    # The shared-tag lists a reason may count: the ones reasons use, the R27 overlap and Qloo compare's.
    def tag_lists(brand)
      [ Templates.shared_tags(@toolkit, brand), @toolkit.shared_audience_tags(brand).map(&:name).uniq,
        Array(@toolkit.explanations[brand.id]).map(&:name).uniq ]
    end

    # Run-wide: age buckets, the show's downloads, and its title and feed titles (episode numbers).
    def base
      @base ||= begin
        allowed = Allowed.new(numbers: Set.new(AGE_BOUNDS), percents: Set.new, names: Set.new)
        allowed.numbers << show.downloads_per_episode.to_s if show.downloads_per_episode
        self.class.add_texts(allowed, show.title, *@toolkit.feed.episodes.map(&:title))
      end
    end

    def profile_allowed(matches)
      allowed = base.with(numbers: base.numbers.dup, names: base.names.dup, percents: Set.new)
      numbers = allowed.numbers
      numbers << matches.size.to_s << @toolkit.scored.size.to_s
      numbers << matches.count { |m| m.evidence.dig("proven", "count").to_i.positive? }.to_s
      numbers.merge(matches.map(&:tier).tally.values.map(&:to_s))
      numbers.merge([ @toolkit.seed_count, @toolkit.seed_entity_ids.size, @toolkit.seed_tag_ids.size ].map(&:to_s))
      numbers << Array(report.heatmap.is_a?(Hash) ? report.heatmap["points"] : nil).size.to_s
      audience = report.audience.is_a?(Hash) ? report.audience : {}
      audience.each_value do |list|
        numbers << Array(list).size.to_s
        self.class.add_texts(allowed, *Array(list).filter_map { |item| item["name"] if item.is_a?(Hash) })
      end
      self.class.add_texts(allowed, *report.seed_items.pluck("name"))
    end
  end
end
