require "rails_helper"

# The public pages (Task 19, R78): the landing page, pricing, the legal pages and about, with their SEO tags, plus
# robots.txt and the sitemap.
RSpec.describe "Public pages" do
  around { |example| with_billing_env { example.run } }

  def page = Nokogiri::HTML(response.body)
  def meta(attribute, name) = page.at_css("meta[#{attribute}='#{name}']")&.[]("content")

  # A done sample report under the samples owner, at slug.
  def create_sample(slug, title: "The Founder's Ledger")
    owner = User.find_or_create_by!(email: User::SAMPLES_EMAIL)
    show = create(:show, user: owner, title: title)
    create(:report, show: show, kind: "agent", status: "done", sample_slug: slug, spend_bucket: "sample")
  end

  describe "SEO tags" do
    pages = { "/" => "Midrolo: find sponsors who already love your listeners", "/pricing" => "Pricing | Midrolo",
              "/privacy" => "Privacy | Midrolo", "/terms" => "Terms | Midrolo", "/about" => "About | Midrolo",
              "/samples" => "Sample sponsor reports | Midrolo", "/users/sign_in" => "Sign in | Midrolo" }

    pages.each do |path, title|
      it "gives #{path} its title and every share tag once, with absolute URLs" do
        get path, params: { utm_source: "newsletter" }

        expect(response).to have_http_status(:ok)
        expect(page.at_css("title").text).to eq(title)
        expect(meta("name", "description")).to be_present
        expect_share_tags(page, url: "http://www.example.com#{path}", image: %r{\Ahttp://www\.example\.com/assets/og-\h+\.png\z})
        expect(meta("property", "og:title")).to eq(title.delete_suffix(" | Midrolo"))
      end
    end

    it "keeps signed-in pages out of search results and gives them no share image" do
      sign_in create(:user, :subscribed) # the pipeline is on paid plans

      [ "/shows/new", "/account", "/pipeline" ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect_private_tags(page)
      end
    end

    it "gives every public page its own title and description" do
      titles = pages.keys.map { |path| get(path) && page.at_css("title").text }
      descriptions = pages.keys.map { |path| get(path) && meta("name", "description") }

      expect(titles.uniq.size).to eq(pages.size)
      expect(descriptions.uniq.size).to eq(pages.size)
    end
  end

  describe "brand" do
    it "shows the logo in the header and footer, linked home" do
      get "/"

      [ "header.site-header", "footer" ].each do |region|
        link = page.at_css("#{region} a[aria-label='Midrolo home']")
        expect(link["href"]).to eq("/")
        expect(link.at_css("img.brand-logo")["src"]).to match(%r{/assets/brand/logo-\h+\.svg\z})
      end
    end

    it "links the favicon set, the web manifest and a theme color for light and dark" do
      get "/"

      expect(page.at_css("link[rel='icon'][type='image/svg+xml']")["href"]).to eq("/icon.svg")
      expect(page.at_css("link[rel='icon'][sizes='32x32']")["href"]).to eq("/favicon.ico")
      expect(page.at_css("link[rel='apple-touch-icon']")["href"]).to eq("/apple-touch-icon.png")
      expect(page.at_css("link[rel='manifest']")["href"]).to eq("/site.webmanifest")
      themes = page.css("meta[name='theme-color']").to_h { |meta| [ meta["media"], meta["content"] ] }
      expect(themes).to eq("(prefers-color-scheme: light)" => "#f6f2f4", "(prefers-color-scheme: dark)" => "#22132b")
    end

    it "serves the web manifest as application/manifest+json" do
      get "/site.webmanifest"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/manifest+json")
      expect(JSON.parse(response.body)["name"]).to eq("Midrolo")
    end
  end

  describe "GET / (R78)" do
    it "shows the landing page to a visitor, with Sign in in the header" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(page.at_css("h1").text.squish).to eq("Find sponsors who already love your listeners")
      header = page.at_css("header.site-header")
      expect(header.at_xpath(".//a[normalize-space()='Sign in']")["href"]).to eq("/users/sign_in")
      expect(header.text).not_to include("Go to my shows")
      expect(page.at_xpath("//main//a[normalize-space()='Get my free Snapshot']")["href"]).to eq("/users/sign_in")
    end

    it "shows the landing page to a signed-in user too, with Go to my shows instead of Sign in" do
      sign_in create(:user)
      get "/"

      expect(response).to have_http_status(:ok)
      header = page.at_css("header.site-header")
      expect(header.at_xpath(".//a[normalize-space()='Go to my shows']")["href"]).to eq("/shows")
      expect(header.text).not_to include("Sign in")
      expect(page.at_xpath("//main//a[normalize-space()='Get my free Snapshot']")["href"]).to eq("/shows/new")
    end

    it "sends See a sample report to /samples until a sample is done, then to the first done sample" do
      get "/"
      expect(page.at_xpath("//main//a[normalize-space()='See a sample report']")["href"]).to eq("/samples")
      hero = page.at_css("#hero").text
      expect(hero).to include("An illustration of a match list", "Coffee roaster", "Notes app", "Budgeting app")
      expect(hero).not_to match(/Fieldnote|Ledgerly|Northwind|Affinity \d/) # no invented brands or numbers (R89)

      create_sample(Samples.slugs[1], title: "Index Fund Mornings")
      create_sample(Samples.slugs[0])
      get "/"
      expect(page.at_xpath("//main//a[normalize-space()='See a sample report']")["href"]).to eq("/samples/#{Samples.slugs[0]}")
    end

    it "previews the first sample's top matches in the hero" do
      report = create_sample(Samples.slugs[0])
      create(:sponsor_match, report: report, name: "Fieldnote Coffee", position: 1, fit_score: 91)
      create(:sponsor_match, report: report, name: "Ledgerly", position: 2, fit_score: 84)
      get "/"

      hero = page.at_css("#hero")
      expect(hero.text).to include("The Founder's Ledger", "Fieldnote Coffee", "Ledgerly")
      expect(hero.at_css("a[href='/samples/#{Samples.slugs[0]}']")).to be_present
    end

    it "labels the podcaster quotes as paraphrased, never as named testimonials (R70)" do
      get "/"

      quotes = page.at_css("#quotes")
      expect(quotes.at_css("h2").text.squish).to eq("What podcasters say, paraphrased from r/podcasting in 2026")
      expect(quotes.css("blockquote").size).to eq(3)
      expect(quotes.css("cite")).to be_empty
      expect(quotes.at_css(".quotes-coda").text.squish)
        .to eq("Only 39% of podcasters make money from their show. 48% of the rest say their audience is too small. " \
               "RSS.com podcaster survey")
    end

    it "explains how it works, what makes it different and the old way, then the FAQ" do
      get "/"

      expect(page.at_css("#how-it-works").css("ol > li").size).to eq(3)
      expect(page.at_css("#different").text).to include("Qloo taste data", "Proven sponsors", "Honest labels")
      expect(page.at_css("#different").text.squish).to include("modeled from Qloo taste data, not measured")
      expect(page.at_css("#old-way").text).to include("The old way", APP_NAME)
      faq = page.at_css("#faq").text.squish
      expect(faq).to include("Where does the data come from?", "Is this my real audience?", "What's a proxy profile?")
      expect(faq).to include("modeled from Qloo taste data, not measured")
    end

    it "says it in plain words" do
      get "/"

      expect(page.at_css(".hero-lead").text.squish).to include("Qloo taste data", "brands your audience will likely love")
      expect(page.at_css("#different").text.squish).to include("Brands people like your listeners love more than most.")
      expect(page.at_css("main").text).not_to include("over-index")
      expect(page.at_css("#how-it-works").text.squish).to include("In a few minutes")
    end

    # R97: short headline, one line subhead, short bullets. The FAQ may run long, but stays collapsed.
    it "keeps every section skimmable, as the copy rules size it", :aggregate_failures do
      words = ->(node) { node.text.split.size }
      get "/"

      expect(words.(page.at_css(".hero-lead"))).to be <= 15
      expect(page.css("#hero .hero-actions a").map { |a| a.text.squish }).to eq([ "Get my free Snapshot", "See a sample report" ])
      expect(page.css("#hero p").map { |p| p["class"] }).not_to include("hero-note")
      page.css("#quotes blockquote").each { |quote| expect(words.(quote)).to be <= 12, quote.text.squish }
      page.css("#how-it-works li p").each { |step| expect(words.(step)).to be <= 10, step.text.squish }
      expect(page.css("#different dd").size).to eq(3)
      page.css("#different dd").each { |point| expect(words.(point)).to be <= 12, point.text.squish }
      expect(page.css("#old-way tbody tr").size).to eq(4)
      page.css("#old-way th, #old-way td").each { |cell| expect(words.(cell)).to be <= 6, cell.text.squish }
      expect(page.css("#samples p.section-lead")).to be_empty
      page.css("#pricing .plan-features").each { |list| expect(list.css("li").size).to be <= 5 }
      expect(page.css("#faq details").size).to be >= 8
      expect(page.css("#faq details[open]")).to be_empty
      closing = page.at_css(".closing")
      expect(closing.css("p")).to be_empty
      expect(closing.css("a").map { |a| a.text.squish }).to eq([ "Get my free Snapshot", "See a sample report" ])
    end
  end

  describe "pricing" do
    def waitlist_forms = page.css("form[action='/waitlist_entries']")

    it "shows every price from plans.yml, with waitlist buttons in waitlist mode" do
      get "/pricing"

      text = page.at_css("main").text.squish
      Billing.prices.each { |price| expect(text).to include("$#{price.usd}") }
      expect(waitlist_forms.map { |form| form.at_css("input[name='price_key']")["value"] })
        .to match_array(Billing.prices.map(&:key))
      expect(waitlist_forms.map { |form| form.at_css("input[type='submit']")["value"] }.uniq)
        .to eq([ "Join the founding member waitlist" ])
      expect(page.at_xpath("//main//a[normalize-space()='Get my free Snapshot']")).to be_present
    end

    it "reuses the same plan buttons on the landing page" do
      get "/"

      expect(page.at_css("#pricing")).to be_present
      expect(waitlist_forms.size).to eq(Billing.prices.size)
    end

    it "asks a visitor to sign in to subscribe in test mode" do
      allow(Billing).to receive(:mode).and_return(:test)
      get "/pricing"

      expect(waitlist_forms).to be_empty
      expect(page.xpath("//main//a[normalize-space()='Sign in to subscribe']").size).to eq(Billing.prices.size)
    end

    it "confirms a waitlist join back on the pricing page" do
      post "/waitlist_entries", params: { email: "grace@example.com", price_key: "sprint" },
                                headers: { "HTTP_REFERER" => "http://www.example.com/pricing" }
      follow_redirect!

      expect(page.at_css(".flash-notice").text).to include("founding member list")
    end
  end

  describe "legal pages" do
    %w[/privacy /terms].each do |path|
      it "#{path} is dated and gives the contact email" do
        get path

        text = page.at_css("main").text.squish
        expect(text).to include("Last updated: October 2026", "hello@midrolo.com")
        expect(page.at_css("main a[href='mailto:hello@midrolo.com']")).to be_present
      end
    end

    it "names every processor and what happens to your data" do
      get "/privacy"

      text = page.at_css("main").text.squish
      expect(text).to include("Google", "Qloo", "Podcast Index", "OpenRouter", "Cloudflare R2", "Resend", "Dodo")
      expect(text).to include("only ones that don't store or train on what we send")
      expect(text).to include("We don't sell your data")
      expect(text).to include("the map library from jsDelivr", "Cloudflare provides our DNS")
    end

    it "names the plans as plans.yml does" do
      sprint = Entitlements.limits(:sprint)[:name]

      [ "/terms", "/" ].each do |path|
        get path
        expect(page.at_css("main").text.squish).to include("The #{sprint} plan is a single payment and never renews.")
        expect(response.body).not_to include("Sponsor Sprint")
      end
    end

    it "links them from the sign-in card" do
      get "/users/sign_in"

      card = page.at_css("main .card").text.squish
      expect(card).to include("By signing in you agree to our Terms and Privacy policy.")
      expect(page.at_css("main .card a[href='/terms']")).to be_present
      expect(page.at_css("main .card a[href='/privacy']")).to be_present
    end
  end

  describe "footer" do
    it "credits Podcast Index and links Privacy, Terms and Contact" do
      get "/"

      footer = page.at_css("footer")
      expect(footer.at_xpath(".//a[normalize-space()='Podcast data from Podcast Index']")["href"]).to eq("https://podcastindex.org")
      expect(footer.at_xpath(".//a[normalize-space()='Privacy']")["href"]).to eq("/privacy")
      expect(footer.at_xpath(".//a[normalize-space()='Terms']")["href"]).to eq("/terms")
      expect(footer.at_xpath(".//a[normalize-space()='Contact']")["href"]).to eq("mailto:hello@midrolo.com")
      expect(footer.text).to include("Built for the Qloo Agentic Hackathon")
    end
  end

  describe "GET /robots.txt (R88)" do
    it "lets crawlers into the public pages, keeps them out of private ones and points to this host's sitemap" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
      robots = response.body
      expect(robots).to start_with("User-agent: *\nAllow: /\n")
      %w[/admin /account /shows /pipeline].each { |path| expect(robots).to match(/^Disallow: #{path}$/) }
      expect(robots).not_to match(%r{^Disallow: /k\b})
      expect(robots).to match(%r{^Sitemap: http://www\.example\.com/sitemap\.xml$})
    end

    it "names the sitemap on whichever host served it, never a hard-coded domain" do
      host! "midrolo.dijmo.com"
      https!
      get "/robots.txt"

      expect(response.body).to match(%r{^Sitemap: https://midrolo\.dijmo\.com/sitemap\.xml$})
      expect(response.body).not_to include("midrolo.com/")
    end

    it "isn't shadowed by a static file" do
      expect(Rails.root.join("public/robots.txt")).not_to exist
    end
  end

  describe "GET /sitemap.xml" do
    def locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").map(&:text)

    it "lists the public pages, the done samples and the published kits only" do
      create_sample(Samples.slugs[0])
      unfinished = create_sample(Samples.slugs[1], title: "Index Fund Mornings")
      unfinished.update!(status: "failed")
      published = create(:show, title: "Published Show")
      create(:media_kit, :published, show: published)
      published.verify!(via: "admin")
      unpublished = create(:show, title: "Unpublished Show")
      create(:media_kit, show: unpublished)
      unpublished.verify!(via: "admin")
      unverified = create(:show, title: "Unverified Show", slug: "unverified-show")
      create(:media_kit, show: unverified, published_at: Time.current)

      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/xml")
      expect(locs).to eq((%w[/ /pricing /samples /about /privacy /terms] + [ "/samples/#{Samples.slugs[0]}", "/k/#{published.slug}" ])
                           .map { |path| "http://www.example.com#{path}" })
    end
  end
end
