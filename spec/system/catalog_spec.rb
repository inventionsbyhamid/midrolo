require "rails_helper"

# The catalog's main flow (lane L1), end to end on the demo providers: seed from Qloo (the Fake taste catalog, made-up
# shows), match each to its feed in the demo directory, ingest the feeds, and see it all on the admin panel.
RSpec.describe "Catalog", type: :system do
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  let(:admin) { create(:user, admin: true, email: "ops@example.com") }

  around do |example|
    saved = ENV.values_at("ADMIN_USERNAME", "ADMIN_PASSWORD")
    ENV["ADMIN_USERNAME"] = "ops-user"
    ENV["ADMIN_PASSWORD"] = "correct horse"
    example.run
  ensure
    { "ADMIN_USERNAME" => saved[0], "ADMIN_PASSWORD" => saved[1] }.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  before { Podcasts::Directory.reset! }

  it "seeds, ingests and reports the catalog on the admin dashboard" do
    result = Catalog::SeedFromQloo.call(target: 3, sleeper: ->(_seconds) { })
    expect(result.linked).to eq(3)
    perform_enqueued_jobs(only: Catalog::IngestPodcastJob)
    expect(Podcast.pluck(:status)).to all(eq("active"))

    login_as(admin, scope: :user)
    page.driver.basic_authorize("ops-user", "correct horse")
    visit "/admin"

    within(:xpath, "//section[.//*[contains(@class, 'card-title')][normalize-space()='Catalog']]") do
      expect(page).to have_text("Linked to Qloo\n3").or have_text("Linked to Qloo 3")
      expect(page).to have_text("No feed errors.")
      expect(page).to have_css(".badge", text: "Active")
    end
  end
end
