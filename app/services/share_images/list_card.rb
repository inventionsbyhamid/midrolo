module ShareImages
  # The share image of a page that lists podcasts (the directory, a category, a brand's page): its title and a line
  # under it, then a strip of artwork tiles from the shows it lists first, read from storage (StoredArtwork). Shows
  # without stored artwork are skipped; with none at all the card has no strip. The Midrolo logo sits top right, as on
  # every card.
  #
  # The key holds the title, the line and each tiled show's id, updated_at and stored file, so the card changes when the
  # list's leaders do. Building it reads only the podcasts the page already loaded (their artwork preloaded).
  class ListCard < Card
    # podcasts: the list's shows in page order (more than the strip holds is fine).
    def initialize(label:, title:, subline:, podcasts:, seed:, alt: nil)
      @label = label
      @title = title
      @subline = subline
      @tiled = podcasts.select { |podcast| StoredArtwork.stored?(podcast) }.first(Layout::STRIP_LIMIT)
      @seed = seed
      @alt = alt || title
    end

    # The directory: the first page of the plain listing (PodcastDirectory, newest episode first).
    def self.directory(podcasts = PodcastDirectory.new.podcasts)
      new(label: "Podcasts", title: "Find podcasts to sponsor",
          subline: "Independent shows with their sponsors, rates and numbers, each with its source",
          podcasts: podcasts, seed: "directory", alt: "Find podcasts to sponsor on #{APP_NAME}")
    end

    # A category page: the first page of its plain listing; count is how many listed shows it has.
    def self.category(name, count:, podcasts: PodcastDirectory.new({}, category: name).podcasts)
      shows = "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{count == 1 ? 'show' : 'shows'}"
      new(label: "Category", title: "#{name} podcasts to sponsor",
          subline: "#{shows} with their sponsors, rates and numbers, each with its source",
          podcasts: podcasts, seed: "category-#{name}", alt: "#{name} podcasts to sponsor on #{APP_NAME}")
    end

    # A brand's page: the listed shows it sponsors, most recently sponsored first (BrandsController's order and cap).
    def self.brand(brand, podcasts: brand_podcasts(brand))
      count = podcasts.size
      new(label: "Sponsor", title: brand.name,
          subline: count == 1 ? "Sponsors 1 podcast, found in its show notes" : "Sponsors #{count} podcasts, found in their show notes",
          podcasts: podcasts, seed: "brand-#{brand.public_id}", alt: "Podcasts #{brand.name} sponsors, on #{APP_NAME}")
    end

    def self.brand_podcasts(brand)
      ids = SponsorMention.where(brand_id: brand.id).joins(:podcast).merge(Podcast.listed).group(:podcast_id)
                          .order(Arel.sql("MAX(sponsor_mentions.published_at) DESC NULLS LAST"), :podcast_id)
                          .limit(BrandsController::SHOW_LIMIT).pluck(:podcast_id)
      Podcast.for_cards.where(id: ids).in_order_of(:id, ids).to_a
    end

    attr_reader :alt

    def empty? = @tiled.empty?

    # The tiles' artwork is read from storage, its variants' records loaded in one go.
    def draw
      stored = Podcast.includes(StoredArtwork::PRELOAD).where(id: @tiled.map(&:id)).index_by(&:id)
      pictures = Layout.strip_slots(@tiled.size).zip(@tiled).map do |(x, y, size), podcast|
        [ StoredArtwork.read(stored.fetch(podcast.id, podcast), size: size, radius: Layout::STRIP_RADIUS), x, y ]
      end
      states = pictures.map { |picture, _, _| picture ? :image : :fallback }
      png = Renderer.png(layout(strip: states).svg, overlays: pictures.select(&:first))
      Image.new(png: png, complete: states.all?(:image))
    end

    def layout(artwork: nil, strip: Array.new(@tiled.size, :image)) = Layout.new(**fields, artwork: artwork, strip: strip)

    private

    def key_parts
      [ "list", Digest::SHA256.hexdigest(fields.to_json).first(16),
        *@tiled.map { |podcast| "#{podcast.cache_key_with_version}-#{StoredArtwork.state(podcast).first(12)}" } ]
    end

    def fields = { label: @label, title: @title, subline: @subline, seed: @seed }
  end
end
