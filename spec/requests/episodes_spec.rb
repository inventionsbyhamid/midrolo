require "rails_helper"

RSpec.describe "Episode pages" do
  let(:podcast) { create(:podcast, :indexable, title: "Darknet Diaries") }
  let(:episode) do
    create(:episode, podcast: podcast, title: "Ricky", description: "A story about a pen tester.\n\nPlus a second paragraph.",
                     published_at: Time.zone.local(2026, 10, 1, 9), duration_seconds: 2_520, season: 2, number: 14,
                     link: "https://darknetdiaries.com/episode/ricky", enclosure_url: "https://cdn.example.com/ricky.mp3")
  end

  def doc = Nokogiri::HTML(response.body)
  def robots = doc.css("meta[name='robots']").map { |meta| meta["content"] }

  it "shows the notes, the sponsors with codes and evidence, and links to the audio; indexed when a sponsor was found" do
    brand = create(:brand, name: "ThreatLocker")
    create(:sponsor_mention, episode: episode, brand: brand, promo_code: "DARKNET", offer: "Free trial for 30 days",
                             evidence: "This episode is sponsored by ThreatLocker.", url: "https://threatlocker.com/darknet")

    get podcast_episode_path(podcast, episode)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Ricky", "Darknet Diaries", "Oct 1, 2026", "Season 2, episode 14", "42 min",
                                     "A story about a pen tester.", "ThreatLocker", "Code DARKNET", "Free trial for 30 days",
                                     "https://darknetdiaries.com/episode/ricky", "https://cdn.example.com/ricky.mp3")
    expect(doc.at_css("a.mention-brand")["href"]).to eq("/brands/#{brand.slug}")
    expect(robots).to be_empty
    episode_ld = JSON.parse(doc.at_css("script[type='application/ld+json']").text)["@graph"].first
    expect(episode_ld).to include("@type" => "PodcastEpisode", "name" => "Ricky", "datePublished" => "2026-10-01",
                                  "duration" => "PT42M", "episodeNumber" => 14)
    expect(episode_ld["partOfSeries"]["name"]).to eq("Darknet Diaries")
  end

  it "noindexes an episode without a sponsor read, or on a podcast that isn't indexable" do
    get podcast_episode_path(podcast, episode)
    expect(robots).to eq([ "noindex, follow" ])
    expect(response.body).to include("No sponsor reads found in this episode")
  end

  it "links the episodes either side" do
    older = create(:episode, podcast: podcast, title: "Older One", published_at: episode.published_at - 7.days)
    newer = create(:episode, podcast: podcast, title: "Newer One", published_at: episode.published_at + 7.days)

    get podcast_episode_path(podcast, episode)

    expect(doc.at_css("a[rel='prev']")["href"]).to eq(podcast_episode_path(podcast, older))
    expect(doc.at_css("a[rel='next']")["href"]).to eq(podcast_episode_path(podcast, newer))
  end

  it "301s an earlier podcast slug to the same episode, and 404s an unknown episode" do
    old = podcast.slug
    episode
    podcast.update!(title: "Darknet Diaries Renamed")

    get "/podcasts/#{old}/episodes/#{episode.slug}"
    expect(response).to redirect_to("/podcasts/#{podcast.reload.slug}/episodes/#{episode.slug}")
    expect(response).to have_http_status(:moved_permanently)

    get "/podcasts/#{podcast.slug}/episodes/nope-123456"
    expect(response).to have_http_status(:not_found)
  end

  it "answers 410 once the podcast is removed" do
    episode
    podcast.remove!
    get podcast_episode_path(podcast, episode)
    expect(response).to have_http_status(:gone)
  end

  it "answers a visitor's repeat request with 304" do
    get podcast_episode_path(podcast, episode)
    get podcast_episode_path(podcast, episode), headers: { "If-None-Match" => response.headers["ETag"] }
    expect(response).to have_http_status(:not_modified)
  end
end
