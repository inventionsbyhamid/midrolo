require "rails_helper"

# The public pages (Task 19, R78): the landing page, pricing, the legal pages and about, with their SEO tags, plus
# robots.txt. The sitemaps are spec/requests/sitemaps_spec.rb's.
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
    pages = { "/" => "Midrolo: where independent podcasts get sponsored", "/pricing" => "Pricing | Midrolo",
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

  describe "GET / (R78, lane L9)" do
    def header = page.at_css("header.site-header")
    def nav_links = header.css("nav[aria-label='Main'] a").to_h { |link| [ link.text.squish, link["href"] ] }

    it "shows a visitor the two sides, with Podcasts, For brands, Pricing and Sign in in the header" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(page.at_css("h1").text.squish).to eq("Where independent podcasts get sponsored")
      expect(nav_links).to eq("Podcasts" => "/podcasts", "For brands" => "/#for-brands", "Pricing" => "/pricing",
                              "Sign in" => "/users/sign_in")
      expect(header.text).not_to include("Your shows", "Inbox", "Sign out")
      actions = page.css("#hero .hero-actions a").to_h { |link| [ link.text.squish, link["href"] ] }
      expect(actions).to eq("Find podcasts your customers love" => "/brand/searches/new",
                            "Get your show sponsored" => "#for-podcasters")
    end

    it "gives a signed-in person their own links: Podcasts, Your shows, Inbox and Account, and Sign out" do
      sign_in create(:user)
      get "/"

      expect(response).to have_http_status(:ok)
      expect(nav_links).to eq("Podcasts" => "/podcasts", "Your shows" => "/shows", "Inbox" => "/inbox", "Account" => "/account")
      expect(header.at_css("form[action='/users/sign_out'] button").text.squish).to eq("Sign out")
      expect(header.text).not_to include("Sign in", "Pipeline")
    end

    it "gives a brand's member the switch to the brand side and counts the unread conversations on Inbox" do
      user = create(:user)
      member = create(:brand_member, user: user)
      create(:conversation, brand: member.brand, started_by: user)
      sign_in user
      get "/"

      expect(nav_links.keys).to eq([ "Podcasts", "Your shows", "Inbox 1 1 unread", "Account" ])
      expect(header.at_css("nav[aria-label='Main'] .side-switch form[action='/side'] button").text).to eq("Brand")
      inbox = header.at_css("nav[aria-label='Main'] a[href='/inbox']")
      expect(inbox.at_css(".nav-count").text).to eq("1")
      expect(inbox.at_css(".nav-count")["aria-hidden"]).to eq("true")
      expect(inbox.at_css(".sr-only").text).to eq("1 unread")
      expect(header.at_css("button[aria-haspopup='dialog']").text.squish).to eq("Menu 1 1 unread")
    end

    it "keeps Pipeline in the podcaster's workspace nav" do
      sign_in create(:user)
      get "/account"

      expect(nav_links.keys).to eq([ "Podcasts", "Your shows", "Pipeline", "Inbox", "Account" ])
      expect(header.at_css("nav[aria-label='Main'] a[href='/account'][aria-current='page']")).to be_present
    end

    it "says Creator Lab closes on November 1 until it has, then that it closed, and links to the free listing" do
      travel_to(Date.new(2026, 10, 30)) { get "/" }
      news = page.at_css("#hero a.hero-news")
      expect(news["href"]).to eq("#creator-lab")
      expect(news.text.squish).to eq("Audacy Creator Lab (formerly Podcorn) closes November 1. List your show free.")
      creator_lab = page.at_css("#creator-lab")
      expect(creator_lab.at_css("h2").text.squish).to eq("Coming from Creator Lab?")
      expect(creator_lab.text.squish).to include("closes November 1. List your show free.", "No commission on any deal")
      expect(creator_lab.text.squish).to include("We are not affiliated with Audacy, Creator Lab or Podcorn.")
      expect(creator_lab.at_xpath(".//a[normalize-space()='Find your show']")["href"]).to eq("/podcasts")

      travel_to(Date.new(2026, 11, 1)) { get "/" }
      expect(page.at_css("#hero a.hero-news").text.squish).to start_with("Audacy Creator Lab (formerly Podcorn) closed November 1.")
    end

    it "leaves How Midrolo works out while its video isn't set, and names nothing from YouTube" do
      get "/"

      expect(page.at_css("#how-it-works")).to be_nil
      expect(response.body).not_to match(%r{youtube(?:-nocookie)?\.com|youtu\.be|ytimg\.com})
    end

    # The real video's id starts with a dash.
    it "shows How Midrolo works right after the hero once its video is set: a poster and play link, no player yet" do
      AppSettings.set(:explainer_video_id, "-UXzujILAoI")
      get "/"

      section = page.at_css("#hero + section#how-it-works")
      expect(section.at_css("h2").text.squish).to eq("How Midrolo works")
      expect(section.at_css(".section-lead").text.squish).to eq("A 2 minute tour for brands and podcasters.")
      video = section.at_css(".video[data-controller='youtube']")
      expect(video["data-youtube-src-value"]).to eq("https://www.youtube-nocookie.com/embed/-UXzujILAoI?autoplay=1&rel=0&playsinline=1")
      expect(video["data-youtube-title-value"]).to eq("How Midrolo works")
      expect(video["data-youtube-label-value"]).to eq("Watch how it works, 2 min video") # the play button's, once made

      # The link to YouTube for a visitor without JavaScript, which youtube_controller makes the play button.
      play = video.at_css("a.video-play[data-youtube-target='play']")
      expect(play["href"]).to eq("https://www.youtube.com/watch?v=-UXzujILAoI")
      expect(play["aria-label"]).to eq("Watch how it works on YouTube, 2 min video")
      poster = play.at_css("img.video-poster") # the video's own title card, served from here
      expect(poster["src"]).to match(%r{\A/assets/explainer/poster-\h+\.jpg\z})
      expect(poster.to_h.slice("alt", "width", "height")).to eq("alt" => "", "width" => "1280", "height" => "720")
      expect(play.at_css(".video-caption").text.squish).to eq("Watch how it works 2 min")

      expect(section.at_css("iframe")).to be_nil
      loads = page.css("[src], link[href]").map { |node| node["src"] || node["href"] }
      expect(loads.grep(%r{youtube(?:-nocookie)?\.com|youtu\.be|ytimg\.com})).to be_empty
      expect(response.body).not_to include("ytimg.com") # not even YouTube's thumbnail
    end

    it "shows the proof strip with the product's own badges, and the catalog's counts once there's a directory" do
      get "/"

      proof = page.at_css("#proof")
      expect(proof.css("h3").map { |h| h.text.squish })
        .to eq([ "Verified Spotify and Apple numbers", "Sponsor history with evidence", "Matched by audience taste" ])
      expect(proof.text.squish).to include("Verified with Spotify for Creators", "From the feed", "Taste data from Qloo")
      expect(proof.text.squish).not_to match(/\d/) # no number until the catalog has one to give
      expect(proof.at_css(".proof-facts")).to be_nil

      stub_const("PagesController::CATALOG_FACTS_FROM", 2)
      episode = create(:episode, podcast: create(:podcast, :active))
      create(:podcast, :active)
      create(:sponsor_mention, episode: episode)
      get "/"
      expect(page.at_css("#proof .proof-facts").text.squish)
        .to eq("In the directory now: 2 podcasts, 1 sponsor read and 1 brand, read from the shows' own feeds.")
    end

    it "shows real shows from the directory on the brand side, open to sponsors first, never the demo show" do
      get "/"
      expect(page.at_css("#for-brands .side-shot")).to be_nil

      create(:podcast, :indexable, title: "Older Show", last_published_at: 30.days.ago)
      create(:podcast, :indexable, title: "Open Show", open_to_sponsors: true, last_published_at: 90.days.ago)
      create(:podcast, :active, title: "Thin Show") # not indexable
      create(:podcast, :indexable, title: "Demo", podcast_guid: Podcast::DEMO_GUID)
      get "/"

      cards = page.css("#for-brands .side-shot .dir-card-title").map { |title| title.text.squish }
      expect(cards).to eq([ "Open Show", "Older Show" ])
      expect(page.at_css("#for-brands .side-shot a[href='/podcasts/open-show']")).to be_present
      steps = page.css("#for-brands .side-step h3").map { |h| h.text.squish }
      expect(steps).to eq([ "Name your brand", "See who fits, and why", "Request a spot" ])
    end

    it "lets a podcaster search for their show, and shows the demo show's listing once demo:setup has run" do
      get "/"

      podcasters = page.at_css("#for-podcasters")
      search = podcasters.at_css("form[role='search']")
      expect(search["action"]).to eq("/podcasts")
      expect(search["method"]).to eq("get")
      expect(search.at_css("input[name='q']")).to be_present
      expect(podcasters.css(".side-step h3").map { |h| h.text.squish })
        .to eq([ "Claim your page", "Invite Midrolo to your stats", "Answer brand requests" ])
      expect(podcasters.at_xpath(".//a[normalize-space()='Get a free Snapshot']")["href"]).to eq("/start")
      expect(podcasters.at_css(".side-shot")).to be_nil
      expect(page.at_css("#explore").text).not_to include("demo show")

      create(:user, admin: true)
      demo = Claims::DemoSetup.call
      get "/"

      listing = page.at_css("#for-podcasters .side-shot")
      expect(listing.text.squish).to include("Midrolo Demo Show", "Demo show", "Midroll", "Open to sponsors")
      expect(listing.at_css("a[href='/podcasts/#{demo.slug}#rates']")).to be_present
      expect(page.at_css("#explore a[href='/podcasts/#{demo.slug}']").text.squish).to include("Open the demo show", "Demo")
    end

    it "links to the directory and a sample report to look around, and the blog only once a post is out" do
      get "/"

      explore = page.at_css("#explore")
      expect(explore.at_css("a[href='/podcasts']").text.squish).to start_with("Browse podcasts")
      expect(explore.at_css("a[href='/samples']").text.squish).to start_with("Read a sample report")
      expect(explore.at_css("a[href='/blog']")).to be_nil

      create_sample(Samples.slugs[0])
      get "/"
      expect(page.at_css("#explore a[href='/samples/#{Samples.slugs[0]}']")).to be_present
    end

    it "keeps the hero's match card an illustration until a sample is done, never inventing brands or numbers" do
      get "/"

      hero = page.at_css("#hero").text
      expect(hero).to include("An illustration of a match list", "Coffee roaster", "Notes app", "Budgeting app")
      expect(hero).not_to match(/Fieldnote|Ledgerly|Northwind|Affinity \d/) # no invented brands or numbers (R89)
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

    it "compares the old way with both sides of Midrolo, then answers the questions both sides ask" do
      get "/"

      expect(page.css("#old-way tbody th").map { |th| th.text.squish })
        .to eq([ "Finding shows", "Trusting the numbers", "Proving fit", "Pricing a spot", "Booking" ])
      faq = page.at_css("#faq").text.squish
      expect(faq).to include("Is listing my show free?", "How do verified numbers work?", "Can brands contact me directly?")
      expect(faq).to include("Where does the data come from?", "Is this my real audience?", "Can I remove my show's page?")
      expect(faq).to include("modeled from Qloo taste data, not measured", "Analytics access only", "Analyst role")
      # UX review L-1: the report and plan questions stay on /pricing.
      expect(faq).not_to include("What's a proxy profile?", "Can I cancel?")
      get "/pricing"
      expect(page.at_css(".faq").text.squish).to include("What's a proxy profile?", "Can I cancel?", "Is listing my show free?")
    end

    it "shows what each side pays above the podcaster plans, from the limits the code enforces" do
      get "/pricing"

      sides = page.at_css(".sides")
      expect(sides.css(".plan-name").map { |name| name.text.squish }).to eq([ "Listing your show", "For brands" ])
      brands = sides.css(".sides-card").last.text.squish
      expect(brands).to include("Free during the trial",
                                "#{User::Brands::DAILY_SEARCHES[:unverified]} fit searches a day, " \
                                "#{User::Brands::DAILY_SEARCHES[:verified]} with a verified work email",
                                "#{User::Brands::DAILY_REQUESTS[:unverified]} requests a day")
      expect(sides.css(".sides-card").first.text.squish).to include("Free forever", "No commission on any deal")
    end

    # R97: short headline, one line subhead, short bullets. The FAQ may run long, but stays collapsed.
    it "keeps every section skimmable, as the copy rules size it", :aggregate_failures do
      words = ->(node) { node.text.split.size }
      get "/"

      expect(words.(page.at_css(".hero-lead"))).to be <= 15
      expect(words.(page.at_css(".hero-news"))).to be <= 14
      page.css("#proof .proof-item > p:last-child").each { |line| expect(words.(line)).to be <= 10, line.text.squish }
      page.css(".side .section-lead").each { |lead| expect(words.(lead)).to be <= 16, lead.text.squish }
      page.css(".side-step p").each { |step| expect(words.(step)).to be <= 10, step.text.squish }
      page.css("#quotes blockquote").each { |quote| expect(words.(quote)).to be <= 12, quote.text.squish }
      expect(page.css("#old-way tbody tr").size).to eq(5)
      page.css("#old-way th, #old-way td").each { |cell| expect(words.(cell)).to be <= 6, cell.text.squish }
      page.css("#creator-lab li").each { |point| expect(words.(point)).to be <= 8, point.text.squish }
      expect(page.css("#samples p.section-lead")).to be_empty
      page.css("#pricing .plan-features").each { |list| expect(list.css("li").size).to be <= 5 }
      expect(page.css("#faq details").size).to be >= 6
      expect(page.css("#faq details[open]")).to be_empty
      closing = page.at_css(".closing")
      expect(closing.css("p")).to be_empty
      expect(closing.css("a").map { |a| a.text.squish }).to eq([ "Find podcasts your customers love", "Get your show sponsored" ])
    end
  end

  describe "GET /start (Get my free Snapshot)" do
    it "sends a visitor to sign in and remembers to come back to adding a show" do
      get "/start"
      expect(response).to redirect_to("/users/sign_in")
      expect(session["user_return_to"]).to eq("/shows/new")
    end

    it "sends a signed-in user straight to adding a show" do
      sign_in create(:user)
      get "/start"
      expect(response).to redirect_to("/shows/new")
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
      expect(waitlist_forms.map { |form| form.at_css("input[type='submit']")["value"] }.uniq).to eq([ "Join the waitlist" ])
      expect(waitlist_forms.map { |form| form.at_css("input[type='email']")["placeholder"] }.uniq).to eq([ "Your email" ])
      expect(page.at_css(".pricing-note").text.squish)
        .to eq("Paid plans aren't on sale yet. Join the waitlist and we'll email you when they open.")
      expect(page.at_xpath("//main//a[normalize-space()='Get my free Snapshot']")).to be_present
      expect(page.css("[data-plan='sprint'] .plan-features li").map { |li| li.text.squish })
        .to eq([ "30 days of Pro", "One payment, no renewal", "Good for a new season's launch" ])
    end

    it "leads with the promo while it runs, in words a user reads", :aggregate_failures do
      travel_to(Time.zone.local(2026, 10, 30, 12)) do
        AppSettings.set(:promo_pro_until, "2026-11-06")
        get "/pricing"
      end

      pricing = page.at_css(".pricing")
      expect(pricing.element_children.first["class"]).to eq("pricing-promo")
      expect(pricing.at_css(".pricing-promo").text.squish).to eq(
        "Free Pro through Nov 6. Every account gets Pro features for up to 3 shows, each with a Snapshot and a full " \
        "report, while the trial budget lasts."
      )
      expect(page.css(".pricing-promo").size).to eq(1)
      expect(page.at_css("main").text.downcase).not_to include("hackathon")
    end

    it "shows a signed-in user the plans they're already on the waitlist for, and the rest as buttons" do
      user = create(:user)
      WaitlistEntry.join(email: user.email, price_key: "pro_monthly", user: user)
      sign_in user
      get "/pricing"

      expect(page.at_css("[data-plan='pro'] [data-interval='monthly'] .waitlist-joined").text.squish).to eq("On the waitlist")
      expect(page.at_css("[data-plan='pro'] [data-interval='monthly'] form")).to be_nil
      expect(waitlist_forms.map { |form| form.at_css("input[name='price_key']")["value"] })
        .to match_array(Billing.prices.map(&:key) - [ "pro_monthly" ])
      expect(waitlist_forms.css("input[type='email']")).to be_empty
    end

    # UX review L-1: the landing says pricing in one line and links the full page, where the plan buttons are.
    it "says pricing in one line on the landing page, with the plans on /pricing" do
      get "/"

      expect(page.at_css("#pricing").text.squish).to include("Free to list your show. Free for brands during the trial.")
      expect(page.at_css("#pricing a[href='/pricing']").text.squish).to eq("See pricing")
      expect(waitlist_forms).to be_empty
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

      expect(page.at_css(".flash-notice").text.squish).to eq("You're on the Sprint waitlist. We'll email you when paid plans open.")
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

    it "says the home page video loads YouTube only when played" do
      get "/privacy"

      expect(page.at_css("main").text.squish).to include("The home page video loads YouTube's privacy-enhanced player " \
                                                         "only when you press play, and YouTube's privacy policy applies " \
                                                         "from then on.")
    end

    it "names the plans as plans.yml does" do
      sprint = Entitlements.limits(:sprint)[:name]

      [ "/terms", "/pricing" ].each do |path| # the landing leaves plan questions to /pricing (UX review L-1)
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
    it "credits Podcast Index and links Privacy, Terms, Contact and the source code" do
      get "/"

      footer = page.at_css("footer")
      expect(footer.at_xpath(".//a[normalize-space()='Podcast data from Podcast Index']")["href"]).to eq("https://podcastindex.org")
      expect(footer.at_xpath(".//a[normalize-space()='Privacy']")["href"]).to eq("/privacy")
      expect(footer.at_xpath(".//a[normalize-space()='Terms']")["href"]).to eq("/terms")
      expect(footer.at_xpath(".//a[normalize-space()='Contact']")["href"]).to eq("mailto:hello@midrolo.com")
      expect(footer.at_xpath(".//a[normalize-space()='Source code']")["href"]).to eq("https://github.com/inventionsbyhamid/midrolo")
      expect(footer.text).to include("Built for the Qloo Agentic Hackathon", "Where independent podcasts get sponsored.")
      links = footer.css("nav[aria-label='Footer'] a").to_h { |link| [ link.text.squish, link["href"] ] }
      expect(links).to include("Podcasts" => "/podcasts", "For brands" => "/#for-brands", "Sample reports" => "/samples",
                               "Pricing" => "/pricing", "Data sources" => "/data-sources")
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
      host! "midrolo.example.net"
      https!
      get "/robots.txt"

      expect(response.body).to match(%r{^Sitemap: https://midrolo\.example\.net/sitemap\.xml$})
      expect(response.body).not_to include("midrolo.com/")
    end

    it "isn't shadowed by a static file" do
      expect(Rails.root.join("public/robots.txt")).not_to exist
    end
  end
end
