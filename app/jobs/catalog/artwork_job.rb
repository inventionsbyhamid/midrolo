module Catalog
  # Stores a podcast's artwork: fetched from its artwork_url through ShareImages::Artwork's hardened download (SafeUrl on
  # every hop, pinned, one deadline, here a 15 MB cap), checked to be a JPEG, PNG or WebP of sane size by its first
  # bytes and header before anything decodes it, kept once per distinct file (Image, by sha256) with its square webp
  # variants made on attach (preprocessed, on this queue), and linked to the podcast, whose indexable flag follows.
  # A taken down picture (a suppression, or an image suppressed_at) is never linked. Failures leave what was there.
  # Enqueued by Catalog::Ingest at the priority of the ingest that found the URL.
  class ArtworkJob < ApplicationJob
    queue_as :artwork
    queue_with_priority Podcast::INGEST_PRIORITIES.fetch(:normal)
    limits_concurrency to: 1, key: ->(podcast_id) { podcast_id }, duration: 2.minutes

    MAX_BYTES = 15.megabytes
    TIMEOUT = 20 # seconds, for the whole fetch
    MAX_SIDE = MediaKit::MAX_IMAGE_SIDE
    TYPES = { jpegload_buffer: [ "image/jpeg", "jpg" ], pngload_buffer: [ "image/png", "png" ],
              webpload_buffer: [ "image/webp", "webp" ] }.freeze

    def perform(podcast_id)
      podcast = Podcast.find_by(id: podcast_id)
      return if podcast.nil? || podcast.removed?

      url = Show.http_url(podcast.artwork_url)
      return if url.nil? || current?(podcast, url)

      image = image_for(url)
      return unless image&.visible?

      podcast.artwork_image = image
      podcast.indexable = podcast.meets_index_rule?
      podcast.save!
    end

    private

    def current?(podcast, url)
      image = podcast.artwork_image
      image.present? && image.source_url == url && podcast.artwork_stored?
    end

    # The stored Image for the picture at url (one already stored with the same bytes, or a new one), or nil when it
    # can't be fetched, isn't a picture we take, or is suppressed.
    def image_for(url)
      bytes = ShareImages::Artwork.fetch_bytes(url, max_bytes: MAX_BYTES, timeout: TIMEOUT)
      return nil if bytes.blank?

      sha256 = Digest::SHA256.hexdigest(bytes)
      return nil if Suppression.image?(sha256)

      image = Image.find_by(sha256: sha256)
      return image if image&.file&.attached?

      store(image || Image.new(sha256: sha256), bytes, url)
    end

    def store(image, bytes, url)
      header = header(bytes)
      return nil unless header

      content_type, extension = TYPES.fetch(header[:loader])
      image.assign_attributes(source_url: url, width: header[:width], height: header[:height], content_type: content_type)
      image.file.attach(io: StringIO.new(bytes), filename: "artwork-#{image.sha256.first(12)}.#{extension}",
                        content_type: content_type)
      image.save!
      image
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Another podcast's job stored the same file a moment ago.
      Image.find_by(sha256: image.sha256)
    end

    # The loader and size, read from the header only (no pixels decoded), for a JPEG, PNG or WebP no larger than
    # MAX_SIDE on a side; nil for anything else, an SVG included.
    def header(bytes)
      loader = ShareImages::Artwork::LOADERS.find { |magic, _| bytes.match?(magic) }&.last
      return nil unless loader

      image = Vips::Image.public_send(loader, bytes)
      return nil unless [ image.width, image.height ].max.between?(1, MAX_SIDE)

      { loader: loader, width: image.width, height: image.height }
    rescue Vips::Error
      nil
    end
  end
end
