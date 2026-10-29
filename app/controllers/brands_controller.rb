# The public brand page (plan 4.2): "Podcasts Notion sponsors", from sponsor reads found in show notes, then shows like
# the ones it sponsors. A brand member who is signed in also sees the brand's latest fit search, cached (no Qloo call
# on a page view). A brand with no sponsor reads on a listed show is a 404 (spec section 10). The brand workspace is
# /brand, lane L6's.
class BrandsController < ApplicationController
  include CatalogPage

  SHOW_LIMIT = 60
  SIMILAR_LIMIT = 6
  FIT_LIMIT = 5

  def show
    @brand = Brand.strict_loading.find_by!(slug: params[:slug].to_s)
    @rows = sponsored_rows
    raise ActiveRecord::RecordNotFound if @rows.empty?

    noindex! unless @rows.any? { |row| row.podcast.page_indexable? }
    @fit_search = latest_fit_search
    return if fresh_for_visitors(etag: [ @brand, @rows.map(&:podcast), @rows.map(&:last_seen).max ])

    @similar = similar_podcasts
  end

  Row = Data.define(:podcast, :episodes_count, :first_seen, :last_seen, :codes)

  private

  # One row per listed podcast the brand sponsored: how many episodes, first and last seen, the promo codes used. The
  # most recent first.
  def sponsored_rows
    stats = SponsorMention.where(brand_id: @brand.id).joins(:podcast).merge(Podcast.listed).group(:podcast_id)
                          .order(Arel.sql("MAX(sponsor_mentions.published_at) DESC NULLS LAST"), :podcast_id).limit(SHOW_LIMIT)
                          .pluck(:podcast_id, Arel.sql("COUNT(*)"), Arel.sql("MIN(sponsor_mentions.published_at)"),
                                 Arel.sql("MAX(sponsor_mentions.published_at)"),
                                 Arel.sql("ARRAY_REMOVE(ARRAY_AGG(DISTINCT sponsor_mentions.promo_code), NULL)"))
    # By id, as brands/_sponsored_shows preloads the same artwork, so its queries are this request's cached ones.
    podcasts = Podcast.for_cards.strict_loading.where(id: stats.map(&:first)).order(:id).index_by(&:id)
    stats.filter_map do |id, count, first, last, codes|
      Row.new(podcast: podcasts[id], episodes_count: count, first_seen: first, last_seen: last, codes: codes.first(3)) if podcasts[id]
    end
  end

  # Listed shows in the categories the brand's shows are in that it hasn't sponsored: likely next buys.
  def similar_podcasts
    categories = @rows.flat_map { |row| row.podcast.categories }.tally.sort_by { |name, count| [ -count, name ] }.map(&:first).first(3)
    return [] if categories.empty?

    Podcast.listed.for_cards.strict_loading.where.not(id: @rows.map { |row| row.podcast.id })
           .where("podcasts.categories ?| array[:names]", names: categories)
           .order(Arel.sql("podcasts.claimed_at IS NULL"), Arel.sql("podcasts.last_published_at DESC NULLS LAST"), :id)
           .limit(SIMILAR_LIMIT).to_a
  end

  # The latest finished fit search with its top results, for a signed-in member of the brand only, by the workspace's
  # rule (Brands::BaseController#visible_searches): a verified member sees the brand's latest, an unverified one only
  # their own (review M2).
  def latest_fit_search
    member = current_user && BrandMember.find_by(brand_id: @brand.id, user_id: current_user.id)
    return nil unless member

    searches = FitSearch.where(brand_id: @brand.id, status: "done")
    searches = searches.where(user_id: current_user.id) unless member.verified?
    searches.order(finished_at: :desc, id: :desc).includes(results: { podcast: { artwork_image: { file_attachment: :blob } } }).first
  end
end
