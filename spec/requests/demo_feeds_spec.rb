require "rails_helper"

RSpec.describe "Demo show feed" do
  it "is a 404 until demo:setup runs" do
    get demo_feed_path
    expect(response).to have_http_status(:not_found)
  end

  it "serves the demo show as RSS that the feed reader parses, never indexed" do
    create(:user, admin: true)
    Claims::DemoSetup.call

    get demo_feed_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/xml")
    expect(response.headers["X-Robots-Tag"]).to include("noindex")
    doc = Nokogiri::XML(response.body).tap(&:remove_namespaces!)
    expect(doc.at_xpath("//channel/title").text).to eq("Midrolo Demo Show")
    expect(doc.at_xpath("//channel/guid").text).to eq(Podcast::DEMO_GUID)
    expect(doc.xpath("//item").size).to eq(6)
    expect(doc.at_xpath("//item/title").text).to eq("Pricing your first midroll")
    expect(Shows::OwnerEmail.for(doc)).to be_nil
  end
end
