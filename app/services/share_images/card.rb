module ShareImages
  # A share image for one page: what it shows (fields, for Layout), the show's artwork when it has an artwork column,
  # and a cache key that changes whenever any of that does. SampleCard and KitCard fill it in. Drawing reads only what
  # is stored (ArtworkStore); it never fetches (R98).
  class Card
    # Bump when the drawing changes, so cached cards are drawn again.
    VERSION = 2
    # complete is false when the show has artwork that isn't stored yet and the mark stands in: worth drawing again soon.
    Image = Data.define(:png, :complete)

    def draw
      picture = ArtworkStore.read(artwork_url) if artwork_url
      place = picture ? :image : (:fallback if artwork?)
      png = Renderer.png(layout(artwork: place).svg, artwork: picture, at: Layout::ARTWORK.values_at(:x, :y))
      Image.new(png: png, complete: picture.present? || artwork_url.nil?)
    end

    def layout(artwork: nil) = Layout.new(**fields, artwork: artwork)

    def cache_key = @cache_key ||= [ "share_images", "v#{VERSION}", *key_parts ].join("/")

    # Short, for the og:image URL (?v=): a link preview sees a new URL whenever the card changes.
    def version = Digest::SHA256.hexdigest(cache_key).first(12)

    # Whether the card has an artwork column, and where its picture comes from (nil: the mark stands in).
    def artwork? = false
    def artwork_url = nil

    private

    def key_parts = raise(NotImplementedError)
    def fields = raise(NotImplementedError)

    # A record's part of the key: its id and updated_at, or "none".
    def version_of(record) = record ? record.cache_key_with_version : "none"
  end
end
