module Pitches
  # What one pitch is written from (spec §9, "The pitch writer"): the show, the brand's Qloo data, the taste overlap,
  # proven-sponsor evidence and the rate card. The live prompt, the fake template and the numeric-claim allowlist
  # (R49) all read these same facts, so a pitch can cite only what it was given.
  class Inputs
    AUDIENCE_TAGS = 6
    PROVEN_SHOWN = 3

    attr_reader :match

    delegate :report, :show, to: :match

    def initialize(match)
      @match = match
    end

    def brand = match.name.to_s.squish

    def category = match.category.to_s.squish.presence

    def website = match.website.to_s.strip.presence

    # Qloo's description of the brand (R52), as saved with the match.
    def brand_description = match.brand_description.to_s.squish.presence

    def tier = match.tier.to_s.presence

    def shared_tags = Array(Matching::Evidence.value(match.evidence, :shared_tags)).map { |tag| tag.to_s.squish }.compact_blank.uniq

    def proven = Matching::Evidence.value(match.evidence, :proven)

    # The newest sponsored episodes, as stored (R34 shape: show, episode_title, published_at).
    def proven_items = Matching::Evidence.items(proven).first(PROVEN_SHOWN)

    def proven_count = [ Matching::Evidence.count(proven), Matching::Evidence.items(proven).size ].max

    def proven_show = proven_items.filter_map { |item| Matching::Evidence.value(item, :show).to_s.squish.presence }.first

    def affinity_percent = match.affinity && (match.affinity.to_f * 100).round

    def downloads = show.downloads_per_episode

    def host = show.author.to_s.squish.presence

    def show_title = show.title.to_s.squish

    # The listeners' top taste tags from the report's audience section, when it has one.
    def audience_tags
      tags = report.audience.is_a?(Hash) ? Array(report.audience["tags"]) : []
      tags.filter_map { |tag| tag["name"].to_s.squish.presence if tag.is_a?(Hash) }.uniq.first(AUDIENCE_TAGS)
    end

    def rate_card = @rate_card ||= Pricing::RateCard.call(downloads: downloads, categories: show.categories)

    def bundle_episodes = rate_config[:bundle_episodes].to_i

    def bundle_discount_percent = (rate_config[:bundle_discount].to_f * 100).round

    # "$1,080"
    def money(amount) = ActiveSupport::NumberHelper.number_to_currency(amount, precision: 0)

    # Every number a pitch may cite (R49): the rate card's figures, the affinity as a percentage, the shared-tag
    # count, the proven-sponsor count and the dates of the sponsorships the prompt shows, the show's downloads, and
    # numbers inside the names and the brand description given.
    def allowed
      @allowed ||= begin
        card = rate_card
        allowed = Research::NumericClaims::Allowed.empty
        allowed.numbers.merge([ card.midroll, card.preroll, card.postroll, card.bundle4, bundle_episodes,
                                bundle_discount_percent, shared_tags.size ].map(&:to_s))
        allowed.percents << bundle_discount_percent.to_s
        allowed.numbers << downloads.to_s if downloads
        Research::NumericClaims.add_affinity(allowed, match.affinity)
        Research::NumericClaims.add_evidence(allowed, { "items" => proven_items, "count" => proven_count })
        Research::NumericClaims.add_texts(allowed, brand, category, brand_description, show_title, host, *shared_tags,
                                          *audience_tags)
      end
    end

    private

    def rate_config = @rate_config ||= Rails.application.config_for(:rate_card)
  end
end
