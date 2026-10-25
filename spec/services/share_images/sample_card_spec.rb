require "rails_helper"

RSpec.describe ShareImages::SampleCard do
  let(:owner) { User.find_or_create_by!(email: User::SAMPLES_EMAIL) }
  let(:show) { create(:show, user: owner, title: "The Founder's Ledger", artwork_url: "https://cdn.example.com/art.jpg") }
  let(:tags) do
    [ "Personal finance", "Startups", "startups", "Stoicism", "Index funds" ].map { |name| { "id" => name, "name" => name } }
  end
  let(:report) do
    create(:report, show: show, kind: "agent", status: "done", sample_slug: "sample-one", spend_bucket: "sample",
                    audience: { "tags" => tags })
  end

  before { create_list(:sponsor_match, 2, report: report) }

  def card = described_class.new(Samples.find!("sample-one"))

  # Each <text>'s words; a title's lines (tspans) joined with a space.
  def texts(svg)
    Nokogiri::XML(svg) { |config| config.strict }.css("text").map do |node|
      node.css("tspan").any? ? node.css("tspan").map(&:text).join(" ") : node.text
    end
  end

  it "shows the title, the Sample report label, the brand match count and the top three different taste tags" do
    shown = texts(card.layout.svg)

    expect(shown).to include("Sample report", "The Founder's Ledger", "Not affiliated with the show.", "2",
                             "brand matches, each with its reason", "Personal finance", "Startups", "Stoicism")
    expect(shown).not_to include("Index funds")
    expect(shown.join(" ")).not_to match(/[\u2013\u2014]/) # no dashes in copy
  end

  it "says one brand match, and leaves the count out when there are none" do
    report.sponsor_matches.last.destroy!
    expect(texts(card.layout.svg)).to include("brand match, with its reason")

    report.sponsor_matches.destroy_all
    expect(texts(card.layout.svg).join(" ")).not_to include("brand match")
  end

  it "draws a 1200x630 PNG without fetching the show's artwork" do
    image = card.draw

    expect(image.complete).to be(true)
    expect(Vips::Image.new_from_buffer(image.png, "").then { |png| [ png.width, png.height ] }).to eq([ 1200, 630 ])
    expect(a_request(:get, /.*/)).not_to have_been_made
  end

  it "has a short version of its cache key for the og:image URL" do
    expect(card.version).to match(/\A\h{12}\z/)
    expect(card.version).to eq(card.version)
  end

  it "has a cache key that changes with the report, its show and its matches" do
    keys = [ card.cache_key ]
    travel(1.minute) { report.update!(summary: "New summary") }
    keys << card.cache_key
    travel(2.minutes) { show.update!(title: "The Founder's Ledger, renamed") }
    keys << card.cache_key
    create(:sponsor_match, report: report)
    keys << card.cache_key

    expect(keys.uniq.size).to eq(4)
  end
end
