# The share images (og:image) of the sample reports and the public media kits: 1200x630 PNGs drawn by ShareImages and
# kept in Rails.cache under a key that changes with the kit, show or report. Only what is public has one: an unknown,
# unfinished or retired sample and a kit that isn't public (Show#public_kit?) are 404s, as their pages are.
class ShareImagesController < ApplicationController
  MAX_AGE = 1.day
  # A card drawn without its artwork (the fetch failed) is cached briefly, so the next request tries again.
  RETRY_AGE = 1.hour
  CACHE_TTL = 30.days

  def sample
    serve ShareImages::SampleCard.new(Samples.find!(params[:slug]))
  end

  def kit
    show = Show.includes(:media_kit).find_by!(slug: params[:slug].to_s)
    raise ActiveRecord::RecordNotFound unless show.public_kit?

    serve ShareImages::KitCard.new(show.media_kit)
  end

  private

  def serve(card)
    key = card.cache_key
    image = Rails.cache.read(key) || draw(card, key)
    expires_in image.complete ? MAX_AGE : RETRY_AGE, public: true
    return unless stale?(etag: [ key, image.complete ], public: true)

    send_data image.png, type: "image/png", disposition: "inline"
  end

  def draw(card, key)
    card.draw.tap { |image| Rails.cache.write(key, image, expires_in: image.complete ? CACHE_TTL : RETRY_AGE) }
  end

  # Link-preview crawlers fetch these with all sorts of user agents.
  def any_browser? = true
end
