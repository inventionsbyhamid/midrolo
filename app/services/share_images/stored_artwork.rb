module ShareImages
  # A catalog podcast's artwork for a share image, read from Active Storage (the Image Catalog::ArtworkJob stored), never
  # from the artwork URL: a request draws only from what is stored (R98). The square webp variant is read once it has
  # been made, else the original while it is small; a picture that is too large, missing or unreadable gives nil, and
  # the card draws the mark in its place.
  module StoredArtwork
    VARIANT = :card # 320px, the most a card draws (the 240px artwork square)
    # The original stands in for a variant not made yet only up to this size.
    ORIGINAL_LIMIT = Artwork::MAX_BYTES
    # What a share image reads from storage, preloaded: the attachment, the blob and its variants' records and blobs.
    PRELOAD = { artwork_image: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }.freeze

    module_function

    # The Image with the podcast's artwork, when it is stored and not taken down; nil otherwise.
    def image(podcast)
      image = podcast.artwork_image
      image if image&.visible? && image.file.attached?
    end

    def stored?(podcast) = image(podcast).present?

    # For a card's cache key: the stored file's key, so a new picture is a new card.
    def state(podcast) = image(podcast)&.file&.blob&.key || "none"

    # An RGBA Vips::Image, size x size with rounded corners, or nil.
    def read(podcast, size:, radius: Layout::ARTWORK_RADIUS)
      image = image(podcast)
      return nil unless image

      bytes = variant_bytes(image) || original_bytes(image)
      png = bytes && Artwork.picture(bytes, size, radius: radius)
      png && Vips::Image.pngload_buffer(png)
    rescue ActiveStorage::FileNotFoundError, Vips::Error => e
      Rails.logger.info("[ShareImages::StoredArtwork] podcast #{podcast.id}: #{e.class}: #{e.message}")
      nil
    end

    def variant_bytes(image)
      stored = image.file.variant(VARIANT).image
      stored.download if stored&.attached?
    end

    def original_bytes(image)
      blob = image.file.blob
      blob.download if blob.byte_size <= ORIGINAL_LIMIT
    end
  end
end
