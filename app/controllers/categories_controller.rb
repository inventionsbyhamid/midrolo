# A category page (plan 4.2): "Technology podcasts that take sponsors", the directory narrowed to one category with
# the same filters (open to sponsors, verified, price, size). The slug is the category's name parameterized; a
# category no listed podcast has is a 404. Indexed when it lists enough shows to be worth a visit.
class CategoriesController < ApplicationController
  include CatalogPage

  # Fewer listed shows than this and the page is thin: noindex.
  MIN_INDEXABLE = 3

  def show
    slug = params[:category].to_s
    return redirect_to(podcast_category_path(slug.parameterize), status: :moved_permanently) if slug != slug.parameterize

    @category = Podcast.category_for_slug(slug) || raise(ActiveRecord::RecordNotFound)
    @directory = PodcastDirectory.new(params, category: @category)
    @podcasts = @directory.podcasts
    @sponsor_counts = @podcasts.empty? ? {} : SponsorMention.where(podcast_id: @podcasts.map(&:id)).group(:podcast_id).distinct.count(:brand_id)
    @total = Podcast.category_counts.to_h.fetch(@category, 0)
    noindex! unless @directory.plain? && @podcasts.count(&:page_indexable?) >= MIN_INDEXABLE
  end
end
