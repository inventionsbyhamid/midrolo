module ShareImages
  # A share image for one page: what it shows (fields, for Layout), the show's artwork when it has an artwork column,
  # and a cache key that changes whenever any of that does. SampleCard and KitCard fill it in.
  class Card
    # Bump when the drawing changes, so cached cards are drawn again.
    VERSION = 1
    # complete is false when the artwork couldn't be fetched and the mark stands in: worth drawing again soon.
    Image = Data.define(:png, :complete)

    def draw
      picture = Artwork.fetch(artwork_url, size: Layout::ARTWORK[:size]) if artwork_url
      place = picture ? :image : (:fallback if artwork?)
      png = Renderer.png(layout(artwork: place).svg, artwork: picture, at: Layout::ARTWORK.values_at(:x, :y))
      Image.new(png: png, complete: picture.present? || artwork_url.nil?)
    end

    def layout(artwork: nil) = Layout.new(**fields, artwork: artwork)

    def cache_key = [ "share_images", "v#{VERSION}", *key_parts ].join("/")

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
