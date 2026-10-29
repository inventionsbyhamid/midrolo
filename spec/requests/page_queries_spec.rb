require "rails_helper"

# Release check for N+1 queries on the busiest public pages: each page is loaded with a little data, then with several
# times as much (shows, episodes, sponsors, people, results), and must run the same number of queries both times.
# Also the HTTP caching a visitor gets: a validator (ETag) and no public caching of HTML.
RSpec.describe "Page queries" do
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  # The SQL statements a block runs, schema and transaction bookkeeping aside.
  def queries
    statements = []
    callback = lambda do |*, payload|
      next if payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached] || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)

      statements << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  # The queries for path once with the data grow adds once, then after grow adds `times` more; equal counts mean no
  # per-row query. Each count follows a visit that warms what's cached (category counts, similar shows' ids).
  def expect_flat(path, times: 4, &grow)
    grow.call(1)
    Rails.cache.clear
    get path
    expect(response).to have_http_status(:ok)
    small = queries { get path }

    grow.call(times)
    Rails.cache.clear
    get path
    large = queries { get path }
    puts "QUERIES #{path}: #{small.size} -> #{large.size}" if ENV["QUERY_COUNTS"]
    expect(response).to have_http_status(:ok)
    extra = large - small
    expect(large.size).to eq(small.size), "#{path}: #{small.size} queries, then #{large.size} with more data:\n#{extra.uniq.first(5).join("\n")}"
  end

  let(:podcast) do
    create(:podcast, :indexable, :with_artwork, title: "Darknet Diaries", author: "Jack Rhysider", categories: [ "Technology" ],
                                                description: "True stories from the dark side of the internet.")
  end

  def sponsored_episode(show = podcast, brand: create(:brand))
    episode = create(:episode, podcast: show, published_at: rand(1..80).days.ago, duration_seconds: 3_000)
    create(:sponsor_mention, episode: episode, brand: brand, promo_code: "CODE#{episode.id}")
    episode
  end

  def similar_show = create(:podcast, :indexable, :with_artwork, categories: [ "Technology" ])

  describe "the podcast page" do
    let(:owner) { create(:show, podcast: podcast) }

    before do
      create(:media_kit, :published, show: owner, open_months: [ 1.month.from_now.strftime("%Y-%m") ])
      podcast.reload.update!(open_to_sponsors: true)
      create(:stat_reading, podcast: podcast, metric: "listeners_30d", value: 2_140, source: "spotify", trust: "verified")
    end

    def grow(count)
      count.times do
        sponsored_episode
        create(:podcast_person, podcast: podcast, image: create(:image, :with_file))
        similar_show
      end
      podcast.touch
    end

    it "runs as many queries for a show with many episodes, sponsors, people and similar shows as for a small one" do
      expect_flat("/podcasts/#{podcast.slug}") { |count| grow(count) }
    end

    it "does the same for a signed-in brand member (Save, Request a spot)" do
      user = create(:user)
      create(:brand_member, user: user, brand: create(:brand))
      sign_in user

      expect_flat("/podcasts/#{podcast.slug}") { |count| grow(count) }
    end
  end

  it "runs a flat number of queries on an episode page with many sponsors and people" do
    episode = sponsored_episode
    expect_flat("/podcasts/#{podcast.slug}/episodes/#{episode.slug}") do |count|
      count.times do
        create(:sponsor_mention, episode: episode, brand: create(:brand))
        create(:podcast_person, podcast: podcast, image: create(:image, :with_file))
      end
    end
  end

  it "runs a flat number of queries on the directory as it fills" do
    expect_flat("/podcasts") { |count| count.times { sponsored_episode(similar_show) } }
  end

  it "runs a flat number of queries on a category page as it fills" do
    expect_flat("/podcasts/category/technology") { |count| count.times { sponsored_episode(similar_show) } }
  end

  it "runs a flat number of queries on a brand page with many sponsored shows" do
    brand = create(:brand, name: "ThreatLocker")
    sponsored_episode(brand: brand)
    expect_flat("/brands/#{brand.slug}") do |count|
      count.times do
        sponsored_episode(similar_show, brand: brand)
        similar_show
      end
    end
  end

  it "runs a flat number of queries on a brand's fit results" do
    user = create(:user)
    brand = create(:brand_member, user: user, brand: create(:brand)).brand
    search = create(:fit_search, user: user, brand: brand, status: "done", summary: "One.\nTwo.\nThree.", finished_at: Time.current)
    sign_in user

    expect_flat("/brand/searches/#{search.public_id}") do |count|
      count.times do
        show = similar_show
        sponsored_episode(show)
        create(:fit_result, fit_search: search, podcast: show, score: 80, price_fit: "within", reasons: [ "A reason." ],
                            proof: { "brands" => [ { "brand" => "Trade Coffee", "relation" => "competitor", "episodes" => 2 } ] })
      end
    end
  end

  describe "HTTP caching for visitors" do
    it "gives catalog pages a validator that answers a repeat with 304, and keeps them out of shared caches" do
      episode = sponsored_episode
      brand = episode.sponsor_mentions.first.brand

      [ "/podcasts/#{podcast.slug}", "/podcasts/#{podcast.slug}/episodes/#{episode.slug}", "/brands/#{brand.slug}" ].each do |path|
        get path
        expect(response.headers["ETag"]).to be_present, path
        expect(response.headers["Cache-Control"]).not_to include("public"), path

        get path, headers: { "If-None-Match" => response.headers["ETag"] }
        expect(response).to have_http_status(:not_modified), path
      end
    end
  end
end
