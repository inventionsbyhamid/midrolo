require "rails_helper"

RSpec.describe PodcastPagesHelper do
  around { |example| travel_to(Time.zone.local(2026, 10, 30, 12)) { example.run } }

  it "says how long ago, briefly" do
    expect([ 30.seconds.ago, 12.minutes.ago, 3.hours.ago, 9.days.ago, 4.months.ago, 3.years.ago, nil ].map { |time| helper.pages_ago(time) })
      .to eq([ "just now", "12 min ago", "3h ago", "9 days ago", "4 months ago", "3 years ago", nil ])
  end

  it "puts cadence, rhythm, duration and episode numbers in words" do
    podcast = build(:podcast, cadence_days: 14, last_published_at: 9.days.ago, first_published_at: Time.zone.local(2017, 9, 3))
    expect(helper.pages_rhythm(podcast)).to eq("New episode every 2 weeks, latest 9 days ago, since Sep 2017")
    expect([ 1, 7, 30, 21, 10, 0 ].map { |days| helper.pages_cadence(build(:podcast, cadence_days: days)) })
      .to eq([ "Daily", "Weekly", "Monthly", "Every 3 weeks", "Every 10 days", nil ])
    expect(helper.pages_rhythm(build(:podcast, cadence_days: 1))).to eq("New episodes daily")
    expect([ 4_320, 2_520, 45, 0 ].map { |seconds| helper.pages_duration(seconds) }).to eq([ "1 h 12 min", "42 min", "45 s", nil ])
    expect(helper.pages_episode_number(build(:episode, season: 2, number: 14))).to eq("Season 2, episode 14")
    expect(helper.pages_episode_number(build(:episode, number: 3))).to eq("Episode 3")
    expect(helper.pages_episode_number(build(:episode, episode_type: "trailer"))).to eq("Trailer")
    expect(helper.pages_month("2026-11")).to eq("Nov 2026")
    expect(helper.pages_month("nope")).to be_nil
    expect(helper.pages_language("en-US")).to eq("English")
  end

  it "titles a verified show by its number and others by what buyers search for, never with a dash" do
    verified = build(:podcast, :claimed, title: "Darknet Diaries", downloads_per_episode: 4_200, downloads_trust: "verified")
    expect(helper.pages_title(verified)).to eq("Darknet Diaries: 4.2K plays per episode, verified")
    expect(helper.pages_title(build(:podcast, title: "Syntax"))).to eq("Syntax podcast sponsorship: rates, sponsors, audience")
  end

  it "titles a show whose owner chose ranges by its band, and an unclaimed one by nothing (code review M3, L8)" do
    banded = build(:podcast, :claimed, title: "Darknet Diaries", downloads_per_episode: 4_200, downloads_trust: "verified",
                                       downloads_bands_only: true)
    expect(helper.pages_title(banded)).to eq("Darknet Diaries: 2,500 to 5,000 plays per episode, verified")

    unclaimed = build(:podcast, title: "Darknet Diaries", downloads_per_episode: 4_200, downloads_trust: "verified")
    expect(helper.pages_title(unclaimed)).to eq("Darknet Diaries podcast sponsorship: rates, sponsors, audience")
  end

  describe "the downloads figure in structured data" do
    def property(**attributes) = helper.pages_downloads_property(build(:podcast, :claimed, **attributes).public_downloads)

    it "names verified numbers as plays read from the platforms, and the show's own as downloads (code review L2)" do
      expect(property(downloads_per_episode: 4_200, downloads_trust: "verified"))
        .to include("name" => "Plays per episode", "value" => 4_200, "description" => PodcastPagesHelper::VERIFIED_PLAYS)
      expect(property(downloads_per_episode: 900, downloads_trust: "provided"))
        .to include("name" => "Downloads per episode", "value" => 900, "description" => "Downloads per episode, provided by the show")
      expect(PodcastPagesHelper::VERIFIED_PLAYS).not_to include("measuring service")
    end

    it "gives the band as a range, never the figure, when the owner chose ranges (code review M3)" do
      banded = property(downloads_per_episode: 4_200, downloads_trust: "verified", downloads_bands_only: true)
      expect(banded).to include("minValue" => 2_500, "maxValue" => 4_999)
      expect(banded).not_to have_key("value")
      expect(property(downloads_per_episode: 40_000, downloads_trust: "provided", downloads_bands_only: true))
        .to include("minValue" => 10_000).and(satisfy { |p| !p.key?("maxValue") })
    end

    it "leaves an unclaimed podcast's figure out" do
      unclaimed = build(:podcast, downloads_per_episode: 4_200, downloads_trust: "verified")
      expect(helper.pages_downloads_property(unclaimed.public_downloads)).to be_nil
    end
  end

  it "writes a fact sentence for the meta description, cut to fit" do
    podcast = build(:podcast, title: "Syntax", author: "Wes and Scott", cadence_days: 3, episode_count: 800,
                              min_price_cents: 50_000, description: "Tasty treats for web developers. " * 10)
    description = helper.pages_description(podcast, sponsors: 4)
    expect(description).to start_with("Syntax by Wes and Scott. Every 3 days. 800 episodes. 4 sponsors in the last 90 days. Rate card from $500.")
    expect(description.length).to be <= PodcastPagesHelper::DESCRIPTION_LIMIT
  end

  it "renders a slot, or its fallback when the slot renders nothing yet" do
    allow(helper).to receive(:render).with("podcasts/numbers", podcast: :p).and_return("  \n")
    expect(helper.pages_slot("podcasts/numbers", podcast: :p) { "fallback" }).to eq("fallback")
    allow(helper).to receive(:render).with("podcasts/numbers", podcast: :p).and_return("<p>42</p>".html_safe)
    expect(helper.pages_slot("podcasts/numbers", podcast: :p) { "fallback" }).to eq("<p>42</p>")
    expect(helper.pages_optional_slot("brands/no_such_partial", brand: nil) { "fallback" }).to eq("fallback")
  end
end
