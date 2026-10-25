# The share images (og:image) of the sample reports and the public media kits: 1200x630 PNGs drawn by ShareImages and
# kept in Rails.cache under a key that changes with the kit, show, report or stored artwork. Only what is public has
# one: an unknown, unfinished or retired sample and a kit that isn't public (Show#public_kit?) are 404s, as their pages
# are.
#
# A request never touches the network (R98): a kit card draws the artwork ArtworkStore holds and, when there is none
# yet, asks FetchShareArtworkJob for it. One request at a time draws a card (a lock in the cache); others meanwhile,
# and any request whose drawing fails, get the landing page's static og.png for a short while.
class ShareImagesController < ApplicationController
  MAX_AGE = 1.day
  # A card drawn without its artwork, or the static stand-in after a failed drawing, is tried again within the hour.
  RETRY_AGE = 1.hour
  # The static stand-in while another request draws the card.
  BUSY_AGE = 1.minute
  CACHE_TTL = 30.days
  LOCK_TTL = 30.seconds
  STATIC_IMAGE = Rails.root.join("app/assets/images/og.png")

  def sample
    serve ShareImages::SampleCard.new(Samples.find!(params[:slug], preload: :show))
  end

  def kit
    show = Show.includes(:media_kit).find_by!(slug: params[:slug].to_s)
    raise ActiveRecord::RecordNotFound unless show.public_kit?

    ShareImages::ArtworkStore.request(show)
    serve ShareImages::KitCard.new(show.media_kit)
  end

  private

  def serve(card)
    key = card.cache_key
    image = Rails.cache.read(key)
    unless image
      return serve_static(BUSY_AGE) unless Rails.cache.write("#{key}/lock", true, unless_exist: true, expires_in: LOCK_TTL)

      image = draw(card, key)
      return serve_static(RETRY_AGE) unless image
    end

    expires_in image.complete ? MAX_AGE : RETRY_AGE, public: true
    return unless stale?(etag: [ key, image.complete ], public: true)

    send_data image.png, type: "image/png", disposition: "inline"
  end

  def draw(card, key)
    image = card.draw
    Rails.cache.write(key, image, expires_in: image.complete ? CACHE_TTL : RETRY_AGE)
    image
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { share_image: key })
    nil
  ensure
    Rails.cache.delete("#{key}/lock")
  end

  def serve_static(max_age)
    expires_in max_age, public: true
    send_file STATIC_IMAGE, type: "image/png", disposition: "inline"
  end

  # Link-preview crawlers fetch these with all sorts of user agents.
  def any_browser? = true
end
