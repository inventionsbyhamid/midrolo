# Claiming and the listing (lane L4): the claim box and Rates section on the podcast page, the claim pages, the
# listing editor and the verification steps. Every helper starts with listing_ (build spec section 10).
module ListingHelper
  # Where a downloads figure came from, by StatReading#source, as the rate card's note names it.
  READING_SOURCES = {
    "platforms" => "Spotify and Apple plays per episode, verified",
    "provided" => "downloads per episode, provided by the show",
    "op3" => "downloads per episode from OP3"
  }.freeze

  # The podcast's public page (lane L3's /podcasts/:slug).
  def listing_podcast_path(podcast, anchor: nil) = podcast_path(podcast, anchor: anchor)

  def listing_podcast_url(podcast, anchor: nil) = podcast_url(podcast, anchor: anchor)

  # "Nov 2026" for "2026-11".
  def listing_month_label(month)
    Date.strptime(month.to_s, "%Y-%m").strftime("%b %Y")
  rescue Date::Error
    month.to_s
  end

  # The downloads figure the rate card suggestion used, and where it came from, as one line:
  # "1,800 downloads per episode, provided by the show (Oct 29)". bands: true gives the range instead of the figure.
  # nil without a figure.
  def listing_downloads_basis(basis, bands: false)
    return nil unless basis

    figure = bands ? Podcast.listing_band(basis.value) : number_with_delimiter(basis.value)
    source = listing_reading_source(basis.reading)
    line = "#{figure} #{source}"
    line += ", demo numbers" if basis.demo?
    line += " (#{l(basis.reading.captured_at.to_date, format: :short)})" if basis.reading&.captured_at
    line
  end

  # The figure alone, for the podcast page's Rates note, whose trust badge names the source and date:
  # "2,140 Spotify and Apple plays per episode", "1,000 to 2,500 downloads per episode".
  def listing_basis_figure(basis, bands: false)
    figure = bands ? Podcast.listing_band(basis.value) : number_with_delimiter(basis.value)
    unit = basis.reading&.source == Podcast::Stats::PLAYS_SOURCE ? "Spotify and Apple plays" : "downloads"
    "#{figure} #{unit} per episode"
  end

  # "downloads per episode, provided by the show" for a reading's source; a figure typed into the workspace has none.
  def listing_reading_source(reading)
    return "downloads per episode you entered" unless reading

    READING_SOURCES.fetch(reading.source) { "downloads per episode from #{reading.source.humanize}" }
  end

  # The Demo show badge, for the fictional show demo:setup makes.
  def listing_demo_badge(podcast)
    ui_badge("Demo show", tone: :warning) if podcast.demo?
  end

  # What a listing has before it's published (review PO-7), from what's saved: [{ ok:, text: }] for open to sponsors,
  # the open months still ahead and the rates.
  def listing_readiness(kit)
    months = kit.open_months & Podcast.listing_months
    [
      { ok: kit.open_to_sponsors?, text: kit.open_to_sponsors? ? "Open to sponsors" : "Not marked open to sponsors yet" },
      { ok: months.any?, text: months.any? ? "Open in #{Copy.and_list(months.map { |month| listing_month_label(month).split.first })}" : "No open months picked yet" },
      { ok: true, text: kit.rate_card_overrides.any? ? "Your own rates" : "Midrolo's suggested rates (you can set your own)" }
    ]
  end

  # The owner email as the claim page may show it: masked, never in full.
  def listing_masked_email(address) = Shows::OwnerEmail.mask(address)
end
