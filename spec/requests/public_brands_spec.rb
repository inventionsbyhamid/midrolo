require "rails_helper"

RSpec.describe "Public brand pages" do
  let(:brand) { create(:brand, name: "ThreatLocker", domain: "threatlocker.com") }
  let(:podcast) { create(:podcast, :indexable, title: "Darknet Diaries", categories: [ "Technology" ]) }

  def doc = Nokogiri::HTML(response.body)
  def robots = doc.css("meta[name='robots']").map { |meta| meta["content"] }

  def mention(on:, at:, code: nil)
    create(:sponsor_mention, episode: create(:episode, podcast: on, published_at: at), brand: brand, published_at: at, promo_code: code)
  end

  it "lists the shows the brand sponsored with counts, dates and codes, then shows like them" do
    mention(on: podcast, at: Time.zone.local(2026, 1, 5), code: "DARKNET")
    mention(on: podcast, at: Time.zone.local(2026, 9, 5))
    create(:podcast, :active, title: "Hard Fork", categories: [ "Technology" ])

    get "/brands/#{brand.slug}"

    expect(response).to have_http_status(:ok)
    expect(doc.at_css("h1").text).to eq("Podcasts ThreatLocker sponsors")
    expect(doc.text.squish).to include("ThreatLocker sponsored 2 episodes across 1 podcast", "2 episodes", "Jan 2026 to Sep 2026", "Code DARKNET")
    expect(response.body).to include("Shows like the ones ThreatLocker sponsors", "Hard Fork", "threatlocker.com")
    expect(robots).to be_empty
  end

  it "404s a brand with no sponsor reads, or with reads only on removed shows" do
    get "/brands/#{brand.slug}"
    expect(response).to have_http_status(:not_found)

    mention(on: podcast, at: 1.week.ago)
    podcast.remove!
    get "/brands/#{brand.slug}"
    expect(response).to have_http_status(:not_found)

    get "/brands/no-such-brand"
    expect(response).to have_http_status(:not_found)
  end

  it "noindexes a brand whose shows aren't indexable" do
    podcast.update!(indexable: false)
    mention(on: podcast, at: 1.week.ago)
    get "/brands/#{brand.slug}"
    expect(robots).to eq([ "noindex, follow" ])
  end

  it "shows the brand's latest fit search to its signed-in members only" do
    mention(on: podcast, at: 1.week.ago)
    member = create(:user)
    create(:brand_member, brand: brand, user: member)
    search = create(:fit_search, brand: brand, user: member, query: "Endpoint security buyers", status: "done", finished_at: 1.day.ago)
    create(:fit_result, fit_search: search, podcast: create(:podcast, :active, title: "Risky Business"), score: 91)

    get "/brands/#{brand.slug}"
    expect(response.body).not_to include("Endpoint security buyers")
    expect(response.body).to include("Is this your brand?")

    sign_in create(:user)
    get "/brands/#{brand.slug}"
    expect(response.body).not_to include("Endpoint security buyers")

    sign_in member
    get "/brands/#{brand.slug}"
    expect(response.body).to include("Your latest fit search", "Endpoint security buyers", "Risky Business", "91")
  end
end
