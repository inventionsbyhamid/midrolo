module Pricing
  # Suggested ad rates for a show, from config/rate_card.yml.
  class RateCard
    Result = Data.define(:mode, :midroll, :preroll, :postroll, :bundle4, :basis)

    def self.call(downloads:, categories:)
      new(downloads: downloads, categories: categories).call
    end

    # The bundle price for a mid-roll figure, whether suggested here or set by the owner on their media kit.
    def self.bundle_price(midroll, config = Rails.application.config_for(:rate_card))
      (midroll * config[:bundle_episodes] * (1 - config[:bundle_discount])).round
    end

    def initialize(downloads:, categories:)
      @downloads = downloads.to_i
      @categories = Array(categories)
      @config = Rails.application.config_for(:rate_card)
    end

    def call
      niche, niche_key = niche_multiplier
      flat = @downloads < @config[:flat_threshold_downloads]
      midroll = flat ? flat_midroll(niche) : cpm_midroll(niche)
      pre = @config[:pre_roll_multiplier]
      post = @config[:post_roll_multiplier]

      Result.new(
        mode: flat ? :flat : :cpm,
        midroll: midroll.to_i,
        preroll: scale(midroll, pre, flat),
        postroll: scale(midroll, post, flat),
        bundle4: self.class.bundle_price(midroll, @config),
        basis: flat ? flat_basis : cpm_basis(niche, niche_key)
      )
    end

    private

    def flat_midroll(niche)
      raw = @downloads * @config[:flat_rate_per_download_usd] * niche
      round_to([ @config[:flat_floor_usd], raw ].max)
    end

    def cpm_midroll(niche)
      (@downloads / 1000.0 * @config[:cpm_usd] * niche).round
    end

    def scale(midroll, factor, flat)
      flat ? round_to(midroll * factor) : (midroll * factor).round
    end

    # Round half-up to the nearest configured step.
    def round_to(value)
      step = @config[:round_to_usd]
      ((value.to_f / step).round(6) + 0.5).floor * step
    end

    # Max multiplier across categories (case-insensitive substring match on the configured keys).
    def niche_multiplier
      keys = @config[:niche_multipliers].except(:default)
      default = @config[:niche_multipliers][:default]
      matches = @categories.flat_map do |cat|
        keys.select { |key, _| cat.to_s.downcase.include?(key.to_s) }.to_a
      end
      best = matches.max_by { |_, mult| mult }
      best && best[1] > default ? [ best[1], best[0] ] : [ default, nil ]
    end

    def flat_basis
      "Flat rate for shows under #{@config[:flat_threshold_downloads].to_fs(:delimited)} downloads per episode, " \
        "based on the $15 to $40 per spot suggested for small shows"
    end

    def cpm_basis(niche, niche_key)
      base = "$#{@config[:cpm_usd]} CPM baseline for host reads"
      base += " × #{niche} #{niche_key} niche multiplier" if niche_key
      "#{base}, in line with published 2026 benchmarks ($20 to $30 CPM)"
    end
  end
end
