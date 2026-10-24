module Matching
  # Reachability tier of a brand, from its Qloo popularity (0..1).
  module Tier
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
