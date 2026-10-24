module Matching
  # Reachability tier of a brand, from its Qloo popularity (0..1).
  module Tier
    # How a tier reads to a podcaster, on report cards, the pipeline and its CSV.
    LABELS = { "easy_yes" => "Easy yes", "realistic" => "Realistic", "long_shot" => "Long shot" }.freeze

    # "Easy yes"; an unknown tier humanized, nil for none.
    def self.label(tier) = LABELS[tier.to_s] || tier.to_s.humanize.presence

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
