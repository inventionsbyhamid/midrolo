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
