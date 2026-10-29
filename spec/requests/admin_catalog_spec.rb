require "rails_helper"

# The catalog panel on /admin (lane L1): counts by status and the latest feed errors.
RSpec.describe "Admin catalog panel" do
  let(:admin) { create(:user, admin: true, email: "ops@example.com") }
  let(:basic_auth) { { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("ops-user", "correct horse") } }

  around do |example|
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    ENV["ADMIN_USERNAME"] = "ops-user"
    ENV["ADMIN_PASSWORD"] = "correct horse"
    example.run
  ensure
    { "ADMIN_USERNAME" => saved[0], "ADMIN_PASSWORD" => saved[1] }.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it "shows the catalog's counts and its latest feed errors" do
    create(:podcast, :indexable, qloo_entity_id: "Q-1")
    create(:podcast, status: "failed", title: "Broken Feed Show", last_error: "feed_redirect_loop", fetch_failures: 3,
                     feed_checked_at: 1.hour.ago, next_fetch_at: 2.days.from_now)
    create(:podcast, title: "Odd Status Show", last_error: "feed_http_418", feed_checked_at: 2.hours.ago)
    create(:episode)

    sign_in admin
    get "/admin", headers: basic_auth

    expect(response).to have_http_status(:ok)
    panel = Nokogiri::HTML(response.body).css("section").find { |section| section.at_css(".card-title")&.text == "Catalog" }
    expect(panel).to be_present
    text = panel.text.squish
    expect(text).to include("Podcasts 4", "Indexable 1", "Linked to Qloo 1", "Episodes 1")
    expect(text).to include("Broken Feed Show", "Feed redirects in a loop", "Feed answered HTTP 418")
  end

  it "shows the paced seed's progress, and links the admin's other queues" do
    freeze_time
    Catalog::SeedProgress.update!("chain" => "abc", "status" => "running", "target" => 1000, "interval" => 540,
                                  "pages" => 12, "matched" => 300, "added" => 250, "missed" => 200, "linked" => 340,
                                  "finish_by" => 5.hours.from_now.iso8601, "next_run_at" => 5.minutes.from_now.iso8601)
    create(:removal_request, podcast: create(:podcast))

    sign_in admin
    get "/admin", headers: basic_auth

    panel = Nokogiri::HTML(response.body).css("section").find { |section| section.at_css(".card-title")&.text == "Catalog" }
    text = panel.text.squish
    expect(text).to include("Paced seed", "Running", "about every 9 minutes", "Pages read 12", "Linked so far 340 of 1,000",
                            "New podcasts 250")
    nav = Nokogiri::HTML(response.body).at_css("nav[aria-label='Admin']")
    expect(nav.css("a").to_h { |link| [ link.text.squish, link["href"] ] })
      .to include("Removal requests (1)" => "/admin/removal_requests", "Stats connections" => "/admin/stat_connections",
                  "Service sessions" => "/admin/service_sessions")

    Catalog::SeedProgress.update!(Catalog::SeedProgress.current.data.merge("status" => "finished", "stopped" => "exhausted",
                                                                           "last_run_at" => Time.current.iso8601))
    get "/admin", headers: basic_auth
    expect(response.body).to include("Qloo had no more podcasts in these genres")
  end

  it "says when there are no feed errors" do
    sign_in admin
    get "/admin", headers: basic_auth
    expect(response.body).to include("No feed errors.")
  end

  it "is not found for anyone else" do
    sign_in create(:user)
    get "/admin", headers: basic_auth
    expect(response).to have_http_status(:not_found)
  end
end
