require "rails_helper"

# Podcaster or brand (reviews G-1, G-2, G-4): a new account picks its side after the first sign in, the nav's switch
# moves between the sides and remembers the choice, each side has its own links, and one link is marked at a time.
RSpec.describe "Sides" do
  let(:user) { create(:user, name: "Nina New") }

  def header = Nokogiri::HTML(response.body).at_css("header.site-header")
  def nav_links = header.css("nav[aria-label='Main'] a").to_h { |link| [ link.text.squish, link["href"] ] }
  def current_links = header.css("nav[aria-label='Main'] a[aria-current]").map { |link| [ link.text.squish, link["aria-current"] ] }

  it "needs sign in" do
    get welcome_path
    expect(response).to redirect_to("/users/sign_in")
  end

  describe "the first sign in's choice" do
    before { sign_in user }

    it "offers both sides as one button each" do
      get welcome_path

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("h1").text).to eq("How will you use Midrolo?")
      roles = page.css("form[action='/side']").map { |form| form.at_css("input[name=role]")["value"] }
      expect(roles).to eq(%w[podcaster brand])
      expect(page.css("form[action='/side'] button.role-choice").map { |b| b.at_css(".role-choice-title").text })
        .to eq([ "I run a podcast", "I'm a brand" ])
    end

    it "sends a brand without a brand yet to brand onboarding, and remembers the side" do
      patch side_path, params: { role: "brand" }

      expect(response).to redirect_to(brand_start_path)
      expect(user.reload.last_role).to eq("brand")
    end

    it "sends a podcaster to their shows" do
      patch side_path, params: { role: "podcaster" }

      expect(response).to redirect_to(shows_path)
      expect(user.reload.last_role).to eq("podcaster")
    end

    it "ignores a side that doesn't exist" do
      patch side_path, params: { role: "admin" }

      expect(response).to redirect_to(welcome_path)
      expect(user.reload.last_role).to be_nil
    end
  end

  describe "where sign in lands" do
    def home_for(user)
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      controller.send(:side_home_for, user)
    end

    it "skips the choice for an account with shows or a brand already" do
      create(:show, user: user)
      expect(home_for(user)).to eq("/shows")
      expect(home_for(create(:brand_member).user)).to eq("/shows")
      expect(home_for(create(:user))).to eq("/welcome")
      expect(home_for(create(:user, last_role: "brand"))).to eq("/brand")
    end
  end

  describe "the nav" do
    let!(:member) { create(:brand_member, user: user) }

    before { sign_in user }

    it "switches a brand member to the brand side and back, with each side's own links" do
      patch side_path, params: { role: "brand" }
      expect(response).to redirect_to(ApplicationController::BRAND_HOME)

      get podcasts_path
      expect(nav_links.keys).to eq([ "Dashboard", "Find podcasts", "Saved", "Inbox", "Podcasts", "Account" ])
      expect(header.at_css(".side-switch [aria-current=true]").text).to eq("Brand")

      patch side_path, params: { role: "podcaster" }
      get podcasts_path
      expect(nav_links.keys).to eq([ "Podcasts", "Your shows", "Inbox", "Account" ])
      expect(header.at_css(".side-switch [aria-current=true]").text).to eq("Podcaster")
    end

    it "marks one link at a time on the brand side (review G-4)" do
      get brand_root_path
      expect(current_links).to eq([ [ "Dashboard", "page" ] ])

      get brand_inbox_path
      expect(current_links).to eq([ [ "Inbox", "page" ] ])

      search = create(:fit_search, user: user, brand: member.brand, status: "done")
      get brand_search_path(search)
      expect(current_links).to eq([ [ "Find podcasts", "true" ] ])

      get new_brand_verification_path
      expect(current_links).to eq([ [ "Dashboard", "true" ] ])
    end
  end
end
