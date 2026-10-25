require "rails_helper"

# The Content Security Policy (R10, config/initializers/content_security_policy.rb), enforced: scripts and styles from
# this site, jsDelivr (MapLibre) and Google Fonts only, inline ones only with the page's nonce, and the map's style and
# tiles from OpenFreeMap. spec/system/content_security_policy_spec.rb loads the pages in a browser.
RSpec.describe "Content Security Policy" do
  let(:browser) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" }

  def policy
    header = response.headers["Content-Security-Policy"]
    expect(header).to be_present
    header.split(";").to_h { |directive| directive.strip.split(/\s+/).then { |name, *sources| [ name, sources ] } }
  end

  def nonce
    value = policy.fetch("script-src").find { |source| source.start_with?("'nonce-") }.delete_prefix("'nonce-").delete_suffix("'")
    value.tap { expect(value.length).to be >= 16 }
  end

  it "enforces a policy without unsafe-inline or unsafe-eval" do
    get "/"
    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_nil

    expect(policy).to include(
      "default-src" => [ "'self'" ], "base-uri" => [ "'self'" ], "object-src" => [ "'none'" ],
      "frame-ancestors" => [ "'self'" ], "font-src" => [ "'self'", "https://fonts.gstatic.com" ],
      "img-src" => [ "'self'", "https:", "data:", "blob:" ], "worker-src" => [ "'self'", "blob:", "https://cdn.jsdelivr.net" ],
      "connect-src" => [ "'self'", "https://tiles.openfreemap.org" ]
    )
    expect(policy["script-src"]).to eq([ "'self'", "https://cdn.jsdelivr.net", "'nonce-#{nonce}'" ])
    expect(policy["style-src"]).to eq([ "'self'", "https://fonts.googleapis.com", "https://cdn.jsdelivr.net", "'nonce-#{nonce}'" ])
    expect(response.headers["Content-Security-Policy"]).not_to include("unsafe")
  end

  it "gives every inline script the page's nonce, and Turbo the same one for the scripts and styles it adds" do
    get "/"
    doc = Nokogiri::HTML(response.body)

    inline = doc.css("script:not([src])")
    expect(inline).not_to be_empty # the importmap and the module that loads the app
    expect(inline.map { |script| script["nonce"] }.uniq).to eq([ nonce ])
    expect(doc.at_css("meta[name='csp-nonce']")["content"]).to eq(nonce)
  end

  # Production checks CSRF, so a visitor's first page leaves a session (its token) behind; Rails stores the token as
  # the response ends, after the page's nonce was chosen.
  it "keeps one nonce across a visitor's pages once there is a session, so Turbo's visits match the first policy" do
    ActionController::Base.allow_forgery_protection = true
    get "/"
    get "/pricing"
    first = nonce
    get "/about"
    expect(nonce).to eq(first)

    reset! # another visitor
    get "/"
    get "/pricing"
    expect(nonce).not_to eq(first)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  it "gives a page without a session yet a nonce of its own, never an empty one that would block every script" do
    get "/"
    expect(Nokogiri::HTML(response.body).at_css("meta[name='csp-nonce']")["content"]).to eq(nonce)
  end

  it "allows the map style's host when MAP_STYLE_URL points somewhere else" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAP_STYLE_URL").and_return("https://maps.example.com/styles/light.json")
    get "/"
    expect(policy["connect-src"]).to eq([ "'self'", "https://tiles.openfreemap.org", "https://maps.example.com" ])
  end

  it "renders the age leans without inline style attributes, which the policy would block" do
    show = create(:show)
    create(:media_kit, :published, show: show)
    create(:report, show: show, status: "done", audience: { "brands" => [], "tags" => [] },
                    demographics: { "age" => { "25_to_29" => 0.3, "30_to_34" => -0.2, "35_to_44" => 0.0 } })
    get public_kit_path(show.slug), headers: { "User-Agent" => browser }

    doc = Nokogiri::HTML(response.body)
    expect(doc.css(".age-bar")).not_to be_empty
    expect(doc.css("body [style]")).to be_empty
    expect(doc.css(".age-bar-fill").map { |fill| fill["data-segments"] }).to eq(%w[6 4 0]) # of 10, against a scale of 0.5
  end

  # The static pages in public/ carry their own inline <style>, and hold nothing a visitor wrote.
  it "sends no policy with a static page the app renders: too many requests, or an old browser", :rate_limits do
    61.times { get "/pricing" }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Content-Security-Policy"]).to be_nil

    old_chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.93 Safari/537.36"
    get "/users/sign_in", headers: { "User-Agent" => old_chrome }, env: { "REMOTE_ADDR" => "198.51.100.77" }
    expect(response).to have_http_status(:not_acceptable)
    expect(response.headers["Content-Security-Policy"]).to be_nil
  end
end
