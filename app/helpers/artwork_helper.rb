# Podcast artwork for every page (T0, build spec section 4).
module ArtworkHelper
  ARTWORK_CLASSES = "flex-none rounded-lg object-cover".freeze
  INITIALS_CLASSES = "flex flex-none items-center justify-center rounded-lg bg-plum-soft font-bold text-plum".freeze

  # The podcast's stored artwork at size (a square webp variant, Image::VARIANTS, through a rails_storage_proxy URL so
  # Cloudflare caches it); until it's stored, or once it's taken down, an initials tile. A feed's artwork URL is never
  # hotlinked: anyone can add a feed, and its host would see every visitor (code review L3, spec section 3).
  # class: sizes the element ("size-16"); other html options go on the tag. alt is "{title} podcast artwork" unless
  # given ("" where it would only repeat a name read next to it). podcast may also be a Show (its podcast) or a
  # Podcasts::ShowInfo (a directory search result, which has no stored artwork).
  def podcast_artwork_tag(podcast, size: :thumb, **html)
    podcast = podcast.podcast if podcast.is_a?(Show)
    css = html.delete(:class)
    alt = html.key?(:alt) ? html.delete(:alt) : "#{podcast.title} podcast artwork"
    variant = podcast.artwork_variant(size) if podcast.respond_to?(:artwork_variant)
    if variant
      side = Image::VARIANTS.fetch(size.to_sym)
      image_tag rails_storage_proxy_path(variant), alt: alt, width: side, height: side, loading: "lazy",
                                                   class: class_names(css, ARTWORK_CLASSES), **html
    else
      tag.span(Podcast.initials_for(podcast.title), class: class_names(css, INITIALS_CLASSES), "aria-hidden": "true", **html)
    end
  end
end
