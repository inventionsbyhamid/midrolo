# Fetches a show's artwork for its kit's share image (ShareImages::Artwork: SafeUrl on every hop, a byte cap and one
# deadline for the whole fetch) and stores it (ShareImages::ArtworkStore), so the image route never touches the
# network (R98). Queued when a kit is published, when a public kit's show changes its artwork URL, and, at most every
# ten minutes per URL, when a share image finds none stored. It runs on its own queue with one thread
# (config/queue.yml), so a slow artwork host never holds up reports or mail.
class FetchShareArtworkJob < ApplicationJob
  queue_as :artwork

  def perform(show_id)
    show = Show.find_by(id: show_id)
    url = Show.http_url(show&.artwork_url)
    return unless url && show.public_kit?
    return if ShareImages::ArtworkStore.stored?(url)

    png = ShareImages::Artwork.fetch(url, size: ShareImages::Layout::ARTWORK[:size])
    ShareImages::ArtworkStore.write(url, png) if png
  end
end
