# The share images (og:image) of the sample reports, the public media kits, the blog posts (R148) and the catalog's
# pages (a podcast, an episode, a category, the directory, a brand): 1200x630 PNGs drawn by ShareImages and kept in
# Rails.cache under a key that changes with the kit, show, podcast, report, post file or stored artwork. Only what is
# public has one: an unknown, unfinished or retired sample, a kit that isn't public (Show#public_kit?), a draft or
# future post, a removed podcast and a brand with no sponsored show listed are 404s, as their pages are.
#
# Pages link their card with ?v=<the card's version>; a request carrying the current version is cached for a month
# (Cloudflare and browsers), since a change to the card makes a new URL. Any other request is cached for a day.
#
# A request never touches the network (R98): a kit card draws the artwork ArtworkStore holds and, when there is none
# yet, asks FetchShareArtworkJob for it; a catalog card reads the artwork Catalog::ArtworkJob stored (StoredArtwork). One request at a time draws a card (a lock in the cache); others meanwhile,
# and any request whose drawing fails, get the landing page's static og.png for a short while.
class ShareImagesController < ApplicationController
  MAX_AGE = 1.day
  # A request for the card's current version (?v=).
  VERSIONED_MAX_AGE = 30.days
  # A card drawn without its artwork, or the static stand-in after a failed drawing, is tried again within the hour.
  RETRY_AGE = 1.hour
  # The static stand-in while another request draws the card.
  BUSY_AGE = 1.minute
  CACHE_TTL = 30.days
  LOCK_TTL = 30.seconds
  STATIC_IMAGE = Rails.root.join("app/assets/images/og.png")

  def sample
    serve ShareImages::SampleCard.new(Samples.find!(params[:slug], preload: { show: :podcast }))
  end

  # An earlier slug of the podcast 301s to the current one's card, as /k/:slug does to the page, so og.png links in
  # pitches already sent keep working after a rename (code review L5).
  def kit
    podcast = Podcast.find_by_slug_or_redirect(params[:slug])
    raise ActiveRecord::RecordNotFound if podcast.nil? || podcast.removed?
    return redirect_to(kit_share_image_path(podcast), status: :moved_permanently) if podcast.slug != params[:slug].to_s

    show = podcast.owner_show
    raise ActiveRecord::RecordNotFound unless show&.public_kit?

    ShareImages::ArtworkStore.request(show)
    serve ShareImages::KitCard.new(show.media_kit)
  end

  def blog_post
    serve ShareImages::BlogCard.new(Blog::Post.find!(params[:slug]))
  end

  def podcast
    serve ShareImages::PodcastCard.new(shared_podcast)
  end

  def episode
    podcast = shared_podcast
    serve ShareImages::PodcastCard.new(podcast, episode: Episode.find_by!(podcast_id: podcast.id, slug: params[:episode_slug].to_s))
  end

  def directory
    serve ShareImages::ListCard.directory
  end

  def category
    name = Podcast.category_for_slug(params[:category].to_s) || raise(ActiveRecord::RecordNotFound)
    serve ShareImages::ListCard.category(name, count: Podcast.category_counts.to_h.fetch(name, 0))
  end

  def brand
    brand = Brand.find_by!(slug: params[:slug].to_s)
    podcasts = ShareImages::ListCard.brand_podcasts(brand)
    raise ActiveRecord::RecordNotFound if podcasts.empty?

    serve ShareImages::ListCard.brand(brand, podcasts: podcasts)
  end

  private

  def serve(card)
    key = card.cache_key
    image = Rails.cache.read(key) || draw_once(card, key)
    return serve_static(BUSY_AGE) if image == :busy
    return serve_static(RETRY_AGE) unless image

    expires_in max_age(card, image), public: true
    return unless stale?(etag: [ key, image.complete ], public: true)

    send_data image.png, type: "image/png", disposition: "inline"
  end

  # The card, drawn by this request alone (a lock in the cache): :busy while another request holds the lock, nil when
  # drawing fails. Solid Cache's unless_exist isn't atomic for a missing row, so a request a moment behind another may
  # get the lock after the card is drawn: it reads again first. Two draws can still race, rarely; that costs CPU, never
  # a fetch.
  def draw_once(card, key)
    lock = "#{key}/lock"
    return :busy unless Rails.cache.write(lock, true, unless_exist: true, expires_in: LOCK_TTL)

    begin
      Rails.cache.read(key) || draw(card, key)
    ensure
      Rails.cache.delete(lock)
    end
  end

  def draw(card, key)
    image = card.draw
    Rails.cache.write(key, image, expires_in: image.complete ? CACHE_TTL : RETRY_AGE)
    image
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { share_image: key })
    nil
  end

  def max_age(card, image)
    return RETRY_AGE unless image.complete

    params[:v].present? && params[:v] == card.version ? VERSIONED_MAX_AGE : MAX_AGE
  end

  # The podcast at :slug with what its card reads (artwork with its variants, readings, listing); a removed one is a
  # 404. An earlier slug isn't followed: pages link the current one.
  def shared_podcast
    podcast = Podcast.includes(ShareImages::StoredArtwork::PRELOAD, :stat_readings, :listing).find_by!(slug: params[:slug].to_s)
    raise ActiveRecord::RecordNotFound if podcast.removed?

    podcast
  end

  def serve_static(max_age)
    expires_in max_age, public: true
    send_file STATIC_IMAGE, type: "image/png", disposition: "inline"
  end

  # Link-preview crawlers fetch these with all sorts of user agents.
  def any_browser? = true
end
