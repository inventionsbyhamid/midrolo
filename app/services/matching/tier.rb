module Matching
  # Reachability tier of a brand, from its Qloo popularity (0..1).
  module Tier
    # How a tier reads to a podcaster, on report cards, the pipeline and its CSV.
    LABELS = { "easy_yes" => "Easy yes", "realistic" => "Realistic", "long_shot" => "Long shot" }.freeze
    # What a tier means when pitching the brand: in a match's Why it fits and in the pitch writer's prompt.
    HINTS = { "easy_yes" => "a smaller brand, likely to welcome a show this size",
              "realistic" => "a midsize brand, so lead with the fit",
              "long_shot" => "a big brand, so keep the ask small and concrete" }.freeze

    # "Easy yes"; an unknown tier humanized, nil for none.
    def self.label(tier) = LABELS[tier.to_s] || tier.to_s.humanize.presence

    # "Realistic: a midsize brand, so lead with the fit"; nil for an unknown tier.
    def self.note(tier) = ("#{LABELS[tier.to_s]}: #{HINTS[tier.to_s]}" if HINTS.key?(tier.to_s))

    def self.for(popularity)
      return :realistic if popularity.nil?

      tiers = Rails.application.config_for(:scoring)[:tiers]
      if popularity >= tiers[:long_shot_min] then :long_shot
      elsif popularity >= tiers[:realistic_min] then :realistic
      else :easy_yes
      end
    end
  end
end
