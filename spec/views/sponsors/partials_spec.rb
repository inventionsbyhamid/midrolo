require "rails_helper"

RSpec.describe "Sponsor history partials", type: :view do
  let(:podcast) { create(:podcast, :active, title: "Signal Lost") }
  let(:notion) { create(:brand, name: "Notion", domain: "notion.so") }

  before { view.extend(SponsorsHelper, UiHelper, ArtworkHelper) }

  def read(brand, at:, show: podcast, **fields)
    episode = create(:episode, podcast: show, title: "Night #{at.to_date}", published_at: at)
    create(:sponsor_mention, episode: episode, podcast: show, brand: brand, published_at: at, **fields)
  end

  describe "podcasts/_sponsors" do
    it "lists each brand with when it was seen, its codes and offer, and the read with its episode" do
      read(notion, at: Time.zone.parse("2026-08-03"), promo_code: "SIGNAL", offer: "free for a month",
                   evidence: "This episode is brought to you by Notion. Go to notion.so/signal.")
      read(notion, at: Time.zone.parse("2026-10-01"), evidence: "Thanks to our sponsors: Notion.")
      read(create(:brand, name: "Ramp", domain: "ramp.com"), at: Time.zone.parse("2026-09-12"))

      render partial: "podcasts/sponsors", locals: { podcast: podcast }
      page = Capybara.string(rendered)

      expect(page).to have_text("2 brands found in this show's episode notes")
      items = page.all("li")
      expect(items.map { |li| li.find("h3").text.squish }).to eq([ "Notion notion.so", "Ramp ramp.com" ])
      expect(items.first).to have_text("2 episodes, Aug 2026 to Oct 2026")
      expect(items.first).to have_css(".badge", text: "Code SIGNAL")
      expect(items.first).to have_text("Free for a month")
      expect(items.first).to have_css("blockquote", text: "Thanks to our sponsors: Notion.")
      episode = Episode.find_by!(title: "Night 2026-10-01")
      expect(items.first).to have_link("Night 2026-10-01", href: %r{/podcasts/#{podcast.slug}/episodes/#{episode.slug}\z})
      expect(items.first).to have_link("Notion", href: %r{/brands/#{notion.slug}\z})
      expect(items.last).to have_text("1 episode, Sep 12, 2026")
      expect(rendered).not_to match(/[—–]/)
    end

    it "folds brands past the first eight under Show more" do
      9.times { |i| read(create(:brand, name: "Brand #{i}"), at: (i + 1).days.ago) }

      render partial: "podcasts/sponsors", locals: { podcast: podcast }

      expect(Capybara.string(rendered)).to have_css("details summary", text: "Show 1 more brand")
    end

    it "renders nothing without sponsor reads, so the page's empty state shows" do
      render partial: "podcasts/sponsors", locals: { podcast: podcast }
      expect(rendered.strip).to eq("")
    end
  end

  describe "brands/_sponsored_shows" do
    it "lists the shows the brand sponsored, the most recent first, with artwork and the read" do
      other = create(:podcast, :active, :with_artwork, title: "Hard Reset")
      read(notion, at: 40.days.ago, evidence: "Sponsored by Notion.")
      read(notion, at: 2.days.ago, show: other, promo_code: "RESET", evidence: "Thanks to our sponsors: Notion.")

      render partial: "brands/sponsored_shows", locals: { brand: notion }
      page = Capybara.string(rendered)

      expect(page).to have_text("2 shows where we found Notion in the episode notes")
      expect(page.all("li h3").map(&:text).map(&:squish)).to eq([ "Hard Reset", "Signal Lost" ])
      expect(page.all("li").first).to have_link("Hard Reset", href: %r{/podcasts/#{other.slug}\z})
      expect(page.all("li").first).to have_css(".badge", text: "Code RESET")
      expect(page.all("li").first).to have_css("blockquote", text: "Thanks to our sponsors: Notion.")
      expect(page.all("li").first).to have_css("img")
    end

    it "takes rows the page already has, and renders nothing for a brand with none" do
      render partial: "brands/sponsored_shows", locals: { brand: notion, rows: [] }
      expect(rendered.strip).to eq("")
    end
  end
end
