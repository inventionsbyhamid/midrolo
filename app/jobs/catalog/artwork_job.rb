module Catalog
  # Stub (lane L1 fills it): fetches the podcast's artwork_url through ShareImages::Artwork's hardened download, stores
  # it as an Image (found by sha256) with its variants, and points podcasts.artwork_image_id at it.
  class ArtworkJob < ApplicationJob
    queue_as :artwork
    queue_with_priority Podcast::INGEST_PRIORITIES.fetch(:normal)

    def perform(podcast_id); end
  end
end
