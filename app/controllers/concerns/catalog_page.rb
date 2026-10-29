# What the public catalog's pages share (podcasts, episodes, categories, brands, removal): the marketing layout, any
# browser, a podcast found by its slug or an earlier one, noindex for pages without unique value, the removed page and
# conditional GET for visitors.
module CatalogPage
  extend ActiveSupport::Concern

  included do
    # A frame's poll (adding, status) gets turbo-rails' bare frame layout instead of the whole site around it.
    layout -> { turbo_frame_request? ? "turbo_rails/frame" : "marketing" }
    helper_method :noindex?
  end

  private

  # Brands, crawlers and link previews arrive in every kind of browser.
  def any_browser? = true

  # Search engines skip this page: the layout's meta robots tag (through the page's meta) and the X-Robots-Tag header.
  def noindex!
    @noindex = true
    response.headers["X-Robots-Tag"] = "noindex"
  end

  def noindex? = @noindex == true

  # The podcast at params[:slug] from scope. An earlier slug (a renamed show) 301s to the same page at the current one,
  # whose path the block builds from the current slug, and returns nil. An unknown slug is a 404.
  def find_podcast(scope = Podcast.all)
    slug = params[:slug].to_s
    podcast = scope.find_by(slug: slug)
    return podcast if podcast

    current = PodcastRedirect.joins(:podcast).where(from_slug: slug).pick("podcasts.slug")
    raise ActiveRecord::RecordNotFound unless current

    redirect_to yield(current), status: :moved_permanently
    nil
  end

  # "Remove this page" took the podcast out: 410 Gone, so search engines drop it, with a short page saying why.
  def render_removed
    noindex!
    render "podcasts/removed", status: :gone
  end

  # A 304 for a visitor whose copy is current. The ETag names the viewer ("anon"; never public, spec section 10).
  # Signed-in pages aren't conditional: their parts (Save, Request a spot) change without the podcast changing, and a
  # browser would show its stale copy.
  def fresh_for_visitors(etag:, last_modified: nil)
    return false if user_signed_in?

    fresh_when(etag: [ *Array(etag), "anon" ], last_modified: last_modified)
    request.fresh?(response)
  end
end
