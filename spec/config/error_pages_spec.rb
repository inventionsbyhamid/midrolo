require "rails_helper"

# The static error pages (public/*.html) Rails serves for 400, 404, 422 and 500 (and 429 from the rate limits): the
# site's look, the favicon set, and a way on, home or to the podcast directory.
RSpec.describe "Static error pages" do
  %w[400 404 422 429 500].each do |code|
    it "gives #{code} the favicon set and links home and to the directory" do
      page = Nokogiri::HTML(Rails.root.join("public/#{code}.html").read)

      expect(page.css("link[rel='icon']").map { |link| link["href"] }).to include("/favicon.ico", "/icon.svg")
      expect(page.at_css("link[rel='apple-touch-icon']")["href"]).to eq("/apple-touch-icon.png")
      expect(page.at_css("meta[name='robots']")["content"]).to eq("noindex, nofollow")
      expect(page.css("main a").map { |link| link["href"] }).to eq([ "/", "/podcasts" ])
      expect(page.css("h1").size).to eq(1)
      expect(page.text).not_to match(/[–—]/)
    end
  end
end
