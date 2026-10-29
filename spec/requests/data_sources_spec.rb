require "rails_helper"

RSpec.describe "Data sources and your rights" do
  it "says where the facts come from and how to take a page down, and the footer links to it" do
    get "/data-sources"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Data sources and your rights", "Where the facts come from", "What we never show",
                                     "Remove a podcast", "Cloudflare may keep serving a cached copy")

    get "/"
    expect(Nokogiri::HTML(response.body).css("footer a").map { |link| link["href"] }).to include("/data-sources")
  end
end

# The copy rules (R97, spec section 2) on the catalog's rendered pages: no em or en dash, none of the hyphens the rules
# call unneeded, and no "affinity" jargon, in the text, the share tags and the labels.
RSpec.describe "Catalog copy" do
  def readable(html)
    doc = Nokogiri::HTML(html)
    doc.css("script, style").each(&:remove)
    shared = doc.css("meta[name='description'], meta[property^='og:'], meta[name^='twitter:']").map { |meta| meta["content"] }
    labels = doc.css("[alt], [title], [aria-label], [placeholder]").flat_map { |node| %w[alt title aria-label placeholder].map { |name| node[name] } }
    [ *doc.xpath("//text()").map(&:text), *shared, *labels ].compact.map(&:squish).compact_blank
  end

  it "keeps dashes, unneeded hyphens and jargon off every catalog page" do
    podcast = create(:podcast, :indexable, title: "Darknet Diaries", author: "Jack Rhysider", cadence_days: 7, episode_count: 3,
                                           description: "True stories.", min_price_cents: 20_000, open_to_sponsors: true)
    episode = create(:episode, podcast: podcast, title: "Ricky", description: "A story.")
    brand = create(:brand, name: "ThreatLocker")
    create(:sponsor_mention, episode: episode, brand: brand, promo_code: "DARKNET")
    pending_show = create(:podcast, status: "pending", title: "Fresh Show")
    paths = [ "/podcasts", "/podcasts?q=darknet", "/podcasts/#{podcast.slug}", "/podcasts/#{pending_show.slug}",
              "/podcasts/#{podcast.slug}/episodes/#{episode.slug}", "/podcasts/category/business", "/brands/#{brand.slug}",
              "/podcasts/#{podcast.slug}/remove", "/data-sources" ]
    allow(Catalog::LazyAdd).to receive(:call).and_return(Catalog::LazyAdd::Result.new(found: [], added: [ pending_show ]))

    paths.each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
      lines = readable(response.body)
      offenders = lines.grep(/[—–]|\baffinit|\b(?:sign-in|signed-in|mid-roll|pre-roll|post-roll|follow-up|per-episode)\b/i)
      expect(offenders).to be_empty, "#{path}: #{offenders.uniq.join(' | ')}"
    end
  end
end
