require "rails_helper"

RSpec.describe "Category pages" do
  def doc = Nokogiri::HTML(response.body)
  def robots = doc.css("meta[name='robots']").map { |meta| meta["content"] }

  before do
    create(:podcast, :indexable, title: "Darknet Diaries", categories: [ "Technology" ], open_to_sponsors: true)
    create(:podcast, :indexable, title: "Syntax", categories: [ "Technology", "Business" ])
    create(:podcast, :indexable, title: "Hard Fork", categories: [ "Technology" ])
    create(:podcast, :indexable, title: "Serial", categories: [ "True Crime" ])
  end

  it "lists the category's podcasts with a title buyers search for, indexed once it has enough shows" do
    get "/podcasts/category/technology"

    expect(response).to have_http_status(:ok)
    expect(doc.at_css("h1").text).to eq("Technology podcasts to sponsor")
    expect(doc.css(".dir-card-link").map(&:text)).to contain_exactly("Darknet Diaries", "Syntax", "Hard Fork")
    expect(response.body).not_to include("Serial")
    expect(robots).to be_empty
    list = JSON.parse(doc.at_css("script[type='application/ld+json']").text)["@graph"].first
    expect(list["itemListElement"].size).to eq(3)
  end

  it "noindexes a thin category and a filtered one" do
    get "/podcasts/category/true-crime"
    expect(response).to have_http_status(:ok)
    expect(robots).to eq([ "noindex, follow" ])

    get "/podcasts/category/technology?open=1"
    expect(doc.css(".dir-card-link").map(&:text)).to eq([ "Darknet Diaries" ])
    expect(robots).to eq([ "noindex, follow" ])
  end

  it "301s a name to its slug and 404s a category no listed show has" do
    get "/podcasts/category/Technology"
    expect(response).to redirect_to("/podcasts/category/technology")
    expect(response).to have_http_status(:moved_permanently)

    get "/podcasts/category/knitting"
    expect(response).to have_http_status(:not_found)
  end
end
