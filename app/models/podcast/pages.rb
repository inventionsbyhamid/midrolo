# Podcast: the public pages (Podcast.for_page, categories, languages, similar shows, removal). Search is
# Podcast.search_catalog, lane L1's (Podcast::Catalog), so the directory and Catalog::LazyAdd find the same shows.
# Lane L3 adds its methods here, and only here (build spec section 10), so lanes don't edit the same model file.
module Podcast::Pages
  extend ActiveSupport::Concern

  # The statuses the directory, category pages and similar shows list. A pending podcast is still being read (search
  # shows it as "Adding this show"); a failed or removed one isn't listed anywhere.
  LISTED_STATUSES = %w[active dormant].freeze
  SIMILAR_LIMIT = 6
  SIMILAR_CACHE = 6.hours
  CATEGORY_CACHE = 10.minutes

  included do
    # Everything the podcast page reads in one go (spec section 10): the stored artwork, the owner's workspace and its
    # listing, the readings and the people. Lanes' partials read only these, or run one query of their own.
    scope :for_page, lambda {
      includes(artwork_image: { file_attachment: :blob }, owner_show: %i[podcast media_kit user], listing: [],
               people: { image: { file_attachment: :blob } }, stat_readings: [])
    }
    # What a podcast card needs: its artwork.
    scope :for_cards, -> { includes(artwork_image: { file_attachment: :blob }) }
    scope :listed, -> { where(status: LISTED_STATUSES) }
    scope :in_category, ->(name) { where("podcasts.categories @> ?", [ name.to_s ].to_json) }
  end

  class_methods do
    # [[name, count]] of every category a listed podcast has, the biggest first (cached a few minutes).
    def category_counts
      Rails.cache.fetch("pages/category_counts", expires_in: CATEGORY_CACHE) do
        connection.select_rows(<<~SQL.squish).map { |name, count| [ name, count.to_i ] }
          SELECT category, COUNT(*) FROM podcasts, jsonb_array_elements_text(podcasts.categories) AS category
          WHERE podcasts.status IN ('active', 'dormant') AND category <> ''
          GROUP BY category ORDER BY COUNT(*) DESC, category
        SQL
      end
    end

    def category_slug(name) = name.to_s.parameterize

    # The category a URL slug names ("true-crime" => "True Crime"), or nil when no listed podcast has it.
    def category_for_slug(slug)
      slug = slug.to_s
      category_counts.map(&:first).find { |name| category_slug(name) == slug }
    end

    # [[code, count]] of the languages listed podcasts are in ("en" from "en-us"), the biggest first (cached).
    def language_counts
      Rails.cache.fetch("pages/language_counts", expires_in: CATEGORY_CACHE) do
        connection.select_rows(<<~SQL.squish).map { |code, count| [ code, count.to_i ] }
          SELECT lower(split_part(podcasts.language, '-', 1)) AS code, COUNT(*) FROM podcasts
          WHERE podcasts.status IN ('active', 'dormant') AND podcasts.language IS NOT NULL AND podcasts.language <> ''
          GROUP BY code ORDER BY COUNT(*) DESC, code
        SQL
      end
    end

    # A language filter: "en" matches "en", "EN" and "en-us".
    def in_language(code)
      code = code.to_s.downcase
      where("lower(podcasts.language) = :code OR lower(podcasts.language) LIKE :prefix", code: code,
                                                                                         prefix: "#{sanitize_sql_like(code)}-%")
    end
  end

  # Whether search engines may index the page: the catalog's own verdict (ingest sets it), never for a removed show.
  def page_indexable? = indexable? && !removed?

  def listed? = LISTED_STATUSES.include?(status)

  # Up to limit other listed podcasts like this one: those sharing the most sponsors first, then those sharing a
  # category, the claimed and most recently active first. Plain SQL (no Qloo), so visitors and crawlers get it too; the
  # ids are cached a few hours, the records loaded fresh.
  def similar_podcasts(limit: SIMILAR_LIMIT)
    ids = Rails.cache.fetch([ "pages/similar", id, limit ], expires_in: SIMILAR_CACHE) { similar_podcast_ids(limit) }
    return [] if ids.empty?

    self.class.for_cards.listed.where(id: ids).in_order_of(:id, ids).to_a
  end

  # Who removes a page (remove!): its verified owner at once, or an admin approving a removal request.
  REMOVERS = %i[owner admin].freeze

  # Takes the podcast out of the catalog for good ("Remove this page"): its page answers 410 and it leaves the directory
  # and sitemaps. Cloudflare may serve a cached image until it expires (the data rights page says so).
  #
  # by: :owner, the verified owner's instant removal, suppresses only the podcast's own feed URL (the feed they proved
  # control of), so no seed or search brings that feed back, and detaches its artwork and people's photos, deleting the
  # files no other podcast or person uses. It never suppresses a podcast:guid or a picture: a feed can declare another
  # show's guid or use its artwork, and the owner proved neither (code review H2).
  # by: :admin, an approved removal request, also suppresses the podcast:guid and the pictures' sha256s, and hides and
  # purges those pictures wherever they are used.
  def remove!(by: :owner)
    raise ArgumentError, "unknown remover #{by.inspect}" unless REMOVERS.include?(by)

    images = [ artwork_image, *Image.where(id: people.where.not(image_id: nil).select(:image_id)) ].compact.uniq
    transaction do
      update!(status: "removed", indexable: false, open_to_sponsors: false)
      by == :admin ? take_down!(images) : release_images!(images)
    end
    images.each { |image| image.file.purge_later if image.file.attached? } if by == :admin
    self
  end

  private

  def take_down!(images)
    suppress!([ ([ "podcast", podcast_guid ] if podcast_guid.present?), feed_suppression,
                *images.map { |image| [ "image", image.sha256 ] } ].compact, reason: "removal request")
    images.each { |image| image.update!(suppressed_at: Time.current) }
  end

  # Unlinks the podcast's pictures, and deletes those nothing else links to (their files go with them).
  def release_images!(images)
    suppress!([ feed_suppression ], reason: "removed by the owner")
    update!(artwork_image: nil) if artwork_image_id
    people.where.not(image_id: nil).update_all(image_id: nil)
    images.each { |image| image.destroy! unless image.podcasts.exists? || image.podcast_people.exists? }
  end

  def feed_suppression = [ "podcast", Suppression.feed_digest(feed_url) ]

  def suppress!(rows, reason:)
    Suppression.upsert_all(rows.map { |kind, value| { kind: kind, value: value, reason: reason } }, unique_by: %i[kind value])
  end

  def similar_podcast_ids(limit)
    shared = SponsorMention.where(brand_id: SponsorMention.where(podcast_id: id).select(:brand_id))
                           .where.not(podcast_id: id).joins(:podcast).merge(self.class.listed)
                           .group(:podcast_id).order(Arel.sql("COUNT(DISTINCT sponsor_mentions.brand_id) DESC"), :podcast_id)
                           .limit(limit).pluck(:podcast_id)
    return shared if shared.size >= limit || categories.blank?

    nearby = self.class.listed.where.not(id: [ id, *shared ])
                       .where("podcasts.categories ?| array[:names]", names: categories.first(5))
                       .order(Arel.sql("podcasts.claimed_at IS NULL"), Arel.sql("podcasts.last_published_at DESC NULLS LAST"), :id)
                       .limit(limit - shared.size).pluck(:id)
    shared + nearby
  end
end
