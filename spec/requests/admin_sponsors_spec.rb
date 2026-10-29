require "rails_helper"

RSpec.describe "Admin sponsor detection panel" do
  around do |example|
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")
    example.run
  ensure
    ENV["ADMIN_USERNAME"], ENV["ADMIN_PASSWORD"] = saved
  end

  it "shows what sponsor detection found and what waits for a scan" do
    mention = create(:sponsor_mention, brand: create(:brand, name: "Helix Sleep"), detected_by: "llm", confidence: 0.92,
                                       evidence: "Go to helixsleep.com/tim and use code TIM.")
    mention.podcast.update!(title: "The Tinkerer Hour")
    create(:episode)
    sign_in create(:user, admin: true)

    get "/admin"

    expect(response).to have_http_status(:ok)
    panel = Nokogiri::HTML(response.body).css("section.card").find { |card| card.at_css(".card-title")&.text == "Sponsor detection" }
    expect(panel).to be_present
    text = panel.text.squish
    expect(text).to include("1 Sponsor reads", "1 checked by the model", "1 Brands", "1 Shows with sponsors")
    expect(text).to include("2 Episodes waiting for a scan", "Today, catalog")
    expect(text).to include("Helix Sleep", "The Tinkerer Hour", "Model 92%", "Go to helixsleep.com/tim and use code TIM.")
  end
end
