class MediaKit
  # What a kit page shows, assembled in one place for the preview, the public page and the editor:
  #   - stats from the show (self-reported downloads, episode count, cadence from the feed)
  #   - audience taste from the show's latest done report, agent or snapshot: brands (minus the hidden ones),
  #     taste tags, other tastes, leans and the heatmap. Never sponsor matches.
  #   - the rate card from Pricing::RateCard with the owner's figures on top, suggested from the podcast's best downloads
  #     reading, else the workspace's typed figure (downloads_basis)
  #   - the contact link: the contact email the owner chose, else the show's website, else none. The feed's owner
  #     address is never used here.
  class Content
    BRAND_LIMIT = 12
    TAG_LIMIT = 12
    TASTE_LIST_LIMIT = 5
    TASTE_LISTS = { "podcasts" => "Podcasts they love", "tv_shows" => "TV they love", "artists" => "Music they love" }.freeze
    SHARE_DESCRIPTION_LIMIT = 200

    Rates = Data.define(:midroll, :preroll, :postroll, :bundle4, :custom, :basis) do
      def custom? = custom
    end

    # The downloads figure the suggested rates use (lane L4): the podcast's best reading (Podcast#best_downloads_reading:
    # verified, then provided by the show), else the figure typed into this workspace (reading nil).
    DownloadsBasis = Data.define(:value, :reading) do
      def demo? = reading&.evidence.is_a?(Hash) && reading.evidence["demo"].present? || false
    end

    attr_reader :kit, :show

    # podcast: the show's podcast when the caller has it loaded already (the podcast page, with its readings), so the
    # rate card's figure comes from what's loaded.
    def initialize(kit, podcast: nil)
      @kit = kit
      @show = kit.show
      @podcast = podcast
    end

    def report
      return @report if defined?(@report)

      @report = show.reports.done.order(created_at: :desc, id: :desc).first
    end

    def audience? = report.present?

    # Brand hashes ({"id", "name", "image_url", "affinity", ...}) in the report's order. The editor lists them all.
    def brands(include_hidden: false)
      list = items("brands")
      return list if include_hidden

      hidden = kit.hidden_brand_ids
      list.reject { |brand| hidden.include?(brand["id"].to_s) }.first(BRAND_LIMIT)
    end

    def taste_tags = items("tags").map { |tag| tag["name"] }.first(TAG_LIMIT)

    # [[label, names]] for the podcasts, TV and music the audience loves (agent reports have them; snapshots don't).
    def taste_lists
      TASTE_LISTS.filter_map do |key, label|
        names = items(key).map { |item| item["name"] }.first(TASTE_LIST_LIMIT)
        [ label, names ] if names.any?
      end
    end

    # [[label, names]] for the taste chips: interests, brands (minus the hidden ones), then podcasts, TV and music.
    def taste_groups
      names = { "tags" => taste_tags, "brands" => brands.map { |brand| brand["name"] } }
      Report::AUDIENCE_LABELS.filter_map do |key, label|
        list = names.fetch(key) { items(key).map { |item| item["name"] }.first(TASTE_LIST_LIMIT) }
        [ label, list ] if list.any?
      end
    end

    def demographics
      leans = report&.demographics
      leans if leans.is_a?(Hash) && (leans["age"].present? || leans["gender"].present?)
    end

    def heatmap
      map = report&.heatmap
      map if map.is_a?(Hash)
    end

    def about = kit.about.presence || show.description.presence

    def share_description
      (kit.headline.presence || about).to_s.squish.truncate(SHARE_DESCRIPTION_LIMIT).presence
    end

    def suggested_rates
      @suggested_rates ||= Pricing::RateCard.call(downloads: downloads_basis&.value, categories: show.categories)
    end

    # The DownloadsBasis for the suggestion, or nil when there's no figure at all.
    def downloads_basis
      return @downloads_basis if defined?(@downloads_basis)

      reading = (@podcast || show.podcast).listing_downloads_reading
      typed = show.downloads_per_episode
      @downloads_basis = reading ? DownloadsBasis.new(value: reading.value, reading:) : (DownloadsBasis.new(value: typed, reading: nil) if typed)
    end

    # The bundle follows the effective mid-roll, so an owner's mid-roll prices the bundle too.
    def rates
      suggested = suggested_rates
      own = kit.rate_card_overrides.select { |_, figure| figure.is_a?(Integer) }
      midroll = own.fetch("midroll", suggested.midroll)
      Rates.new(midroll: midroll, preroll: own.fetch("preroll", suggested.preroll),
                postroll: own.fetch("postroll", suggested.postroll), bundle4: Pricing::RateCard.bundle_price(midroll),
                custom: own.any?, basis: suggested.basis)
    end

    def cadence
      days = show.cadence_days.to_i
      return nil unless days.positive?

      case days
      when 1 then "Daily"
      when 6..8 then "Weekly"
      when 13..15 then "Every 2 weeks"
      when 28..31 then "Monthly"
      else (days % 7).zero? ? "Every #{days / 7} weeks" : "Every #{days} days"
      end
    end

    def contact_email = show.contact_email.presence

    def contact_href
      contact_email ? "mailto:#{contact_email}" : website
    end

    def website = Show.http_url(show.website)

    private

    def items(key)
      audience = report&.audience
      Report.distinct_tastes(Array(audience.is_a?(Hash) ? audience[key] : nil).select { |item| item.is_a?(Hash) && item["name"].present? })
    end
  end
end
