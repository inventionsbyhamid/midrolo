module ShareImages
  # The show artwork that kit share images draw, fetched off the request path by FetchShareArtworkJob (R98) and kept
  # in Rails.cache: Solid Cache in production, a database table, so it outlives restarts and deploys. The key is the
  # artwork URL's digest, so a changed URL is simply a new, empty entry. What's stored is Artwork's output: a PNG
  # we encoded ourselves, already cropped and rounded, which the card decodes with the PNG loader alone.
  module ArtworkStore
    TTL = 60.days
    # A share image that finds nothing stored asks for the fetch at most this often per URL.
    REQUEST_EVERY = 10.minutes

    module_function

    def key(url) = "share_images/artwork/v1/#{Digest::SHA256.hexdigest(url)}"

    def stored?(url) = Rails.cache.exist?(key(url))

    # A Vips::Image, or nil when nothing (readable) is stored.
    def read(url)
      png = Rails.cache.read(key(url))
      Vips::Image.pngload_buffer(png) if png
    rescue Vips::Error
      nil
    end

    def write(url, png) = Rails.cache.write(key(url), png, expires_in: TTL)

    # Queues FetchShareArtworkJob for the show's artwork unless it is stored, or was asked for within REQUEST_EVERY.
    def request(show)
      url = Show.http_url(show.artwork_url)
      return if url.nil? || stored?(url)
      return unless Rails.cache.write("#{key(url)}/requested", true, unless_exist: true, expires_in: REQUEST_EVERY)

      FetchShareArtworkJob.perform_later(show.id)
    end
  end
end
