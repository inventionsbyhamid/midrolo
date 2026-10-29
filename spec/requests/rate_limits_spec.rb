require "rails_helper"

# The app's rate limits (R69, R84): Rails' rate_limit on the controllers, counted in RATE_LIMIT_STORE. They're off in
# every other spec; :rate_limits turns them on over an empty store (spec/support/rate_limits.rb). Each example runs at
# a fixed time, so no burst straddles a window. A 429's Retry-After is the limit's whole window.
RSpec.describe "Rate limits", :rate_limits do
  let(:user) { create(:user) }
  let(:message) { ThrottledResponse::MESSAGE }
  let(:turbo_stream) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  before { travel_to Time.utc(2026, 10, 25, 10, 20, 30) }

  def from(ip) = { "REMOTE_ADDR" => ip }

  # Sends limit requests spread over requests ([method, path] pairs), each reaching its action as the signed-in user,
  # then one more of each pair: every one of those is throttled.
  def expect_all_counted(requests, limit:, **options)
    limit.times do |n|
      method, path = requests[n % requests.size]
      public_send(method, path, **options)
      expect(response.status).to be_between(200, 399), "#{method.upcase} #{path} answered #{response.status}"
      expect(response.location.to_s).not_to include("/users/sign_in")
    end
    requests.each do |method, path|
      public_send(method, path, **options)
      expect(response).to have_http_status(:too_many_requests), "expected #{method.upcase} #{path} to be throttled"
    end
  end

  def expect_friendly_page(retry_after:)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.media_type).to eq("text/html")
    expect(response.headers["Retry-After"]).to eq(retry_after.to_s)
    expect(Nokogiri::HTML(response.body).at_css("h1").text).to eq("Too many requests")
    expect(response.body).to include("Wait a few minutes")
  end

  def expect_flash_stream(retry_after:)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.headers["Retry-After"]).to eq(retry_after.to_s)
    stream = Nokogiri::HTML.fragment(response.body).at_css("turbo-stream")
    expect(stream.attributes.transform_values(&:value)).to eq("action" => "replace", "target" => "flash")
    flash = Nokogiri::HTML.fragment(stream.at_css("template").inner_html)
    expect(flash.at_css("#flash [role='alert']").text.squish).to eq(message)
  end

  describe "every request, per IP: 60 a minute" do
    it "answers the 61st with the friendly page, then lets the IP back in the next minute" do
      60.times do
        get "/pricing"
        expect(response).to have_http_status(:ok)
      end
      get "/pricing"
      expect_friendly_page(retry_after: 60)

      get "/pricing", env: from("203.0.113.9")
      expect(response).to have_http_status(:ok)

      travel 1.minute
      get "/pricing"
      expect(response).to have_http_status(:ok)
    end

    it "counts every controller in one bucket, signed in or not" do
      30.times { get "/pricing" }
      sign_in user
      29.times { get "/account" }
      get "/about"
      expect(response).to have_http_status(:ok)

      get "/account"
      expect(response).to have_http_status(:too_many_requests)
      get "/shows/search?q=money", headers: { "Turbo-Frame" => "search_results" }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "keys on the proxy's X-Forwarded-For, never on a Forwarded header the client sent (R83)" do
      behind_proxy = from("172.18.0.5")
      60.times do |n|
        get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.1", "Forwarded" => "for=203.0.113.#{n}" }, env: behind_proxy
        expect(response).to have_http_status(:ok)
      end
      get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.1", "Forwarded" => "for=203.0.113.250" }, env: behind_proxy
      expect(response).to have_http_status(:too_many_requests)

      get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.2" }, env: behind_proxy
      expect(response).to have_http_status(:ok)
    end

    # Rails::HealthController, Active Storage's controllers and Action Cable don't inherit ApplicationController;
    # WebhooksController opts out, since providers retry.
    it "never counts or blocks the health check, Active Storage, Action Cable or webhooks" do
      61.times do
        post "/webhooks/nobody"
        expect(response).to have_http_status(:not_found)
      end
      59.times { get "/pricing" }
      expect_uncounted_paths_open

      get "/pricing"
      expect(response).to have_http_status(:ok)
      get "/pricing"
      expect(response).to have_http_status(:too_many_requests)
      expect_uncounted_paths_open
    end

    def expect_uncounted_paths_open
      get "/up"
      expect(response).to have_http_status(:ok)
      get "/rails/active_storage/blobs/redirect/missing/file.png"
      expect(response).not_to have_http_status(:too_many_requests)
      get "/cable"
      expect(response).not_to have_http_status(:too_many_requests)
      post "/webhooks/nobody"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "search engine crawlers, confirmed by DNS" do
    let(:googlebot) { { "User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" } }
    let(:crawler) { from("66.249.66.1") }
    let(:dns) { instance_double(Resolv::DNS, "timeouts=": nil) }

    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(Resolv::DNS).to receive(:open) { |&block| block.call(dns) }
      allow(dns).to receive(:getname) do |ip|
        { "66.249.66.1" => "crawl-66-249-66-1.googlebot.com", "203.0.113.66" => "crawl-203-0-113-66.googlebot.com" }
          .fetch(ip) { raise Resolv::ResolvError, "no name for #{ip}" }
      end
      allow(dns).to receive(:getaddresses) do |name|
        { "crawl-66-249-66-1.googlebot.com" => [ Resolv::IPv4.create("66.249.66.1") ] }.fetch(name, [])
      end
    end

    it "lets a verified crawler read pages past the global limit, looking it up once and only past the limit" do
      60.times { get "/pricing", headers: googlebot, env: crawler }
      expect(Resolv::DNS).not_to have_received(:open)

      podcast = create(:podcast, :indexable)
      [ "/pricing", "/podcasts", "/podcasts/#{podcast.slug}", "/sitemap.xml" ].each do |path|
        get path, headers: googlebot, env: crawler
        expect(response).to have_http_status(:ok), path
      end
      head "/about", headers: googlebot, env: crawler
      expect(response).to have_http_status(:ok)
      expect(dns).to have_received(:getname).once
    end

    it "still refuses its writes and its directory searches past their limits" do
      show = create(:show)
      60.times { get "/pricing", headers: googlebot, env: crawler }
      post show_reports_path(show), params: { kind: "snapshot" }, headers: googlebot, env: crawler
      expect_friendly_page(retry_after: 60)

      travel 1.minute
      20.times do
        get "/podcasts", params: { q: "money" }, headers: googlebot, env: crawler
        expect(response).to have_http_status(:ok)
      end
      get "/podcasts", params: { q: "money" }, headers: googlebot, env: crawler
      expect(response).to have_http_status(:too_many_requests)
    end

    it "never spares a user agent alone: a browser, or a crawler's name from an address DNS doesn't confirm" do
      { from("198.51.100.66") => googlebot, from("203.0.113.66") => googlebot, crawler => { "User-Agent" => "curl/8.7.1" } }
        .each do |env, headers|
          60.times { get "/pricing", headers: headers, env: env }
          get "/pricing", headers: headers, env: env
          expect(response).to have_http_status(:too_many_requests), "#{env['REMOTE_ADDR']} #{headers['User-Agent']}"
        end
      expect(dns).to have_received(:getname).twice # once per address that claimed to be Googlebot
    end
  end

  describe "report starts: 10 an hour per user" do
    let(:show) { create(:show, user: user) }

    before { sign_in user }

    it "answers the 11th with the friendly page and Retry-After of the hour" do
      10.times do
        post show_reports_path(show), params: { kind: "snapshot" }
        expect(response.location).to match(%r{/shows/#{show.public_id}/reports/\h{16}\z})
      end
      post show_reports_path(show), params: { kind: "snapshot" }
      expect_friendly_page(retry_after: 3600)
    end

    it "answers a Turbo Stream request with a stream that replaces the flash" do
      10.times do
        post show_reports_path(show), params: { kind: "snapshot" }, headers: turbo_stream
        expect(response.location).to match(%r{/reports/\h{16}\z})
      end
      post show_reports_path(show), params: { kind: "snapshot" }, headers: turbo_stream
      expect_flash_stream(retry_after: 3600)
    end

    it "counts each signed-in user apart on one IP, and falls back to the IP when signed out" do
      other = create(:user)
      11.times { post show_reports_path(show), params: { kind: "snapshot" } }
      expect(response).to have_http_status(:too_many_requests)

      sign_in other
      post show_reports_path(create(:show, user: other)), params: { kind: "snapshot" }
      expect(response.location).to match(%r{/reports/\h{16}\z})

      sign_out other
      10.times do
        post show_reports_path(show), params: { kind: "snapshot" }, env: from("198.51.100.20")
        expect(response).to redirect_to("/users/sign_in")
      end
      post show_reports_path(show), params: { kind: "snapshot" }, env: from("198.51.100.20")
      expect(response).to have_http_status(:too_many_requests)
      post show_reports_path(show), params: { kind: "snapshot" }, env: from("198.51.100.21")
      expect(response).to redirect_to("/users/sign_in")
    end

    it "counts re-runs from the needs-input form in the same bucket, and never a plain save" do
      rerun = { show: { hints: { comparable_shows: [ "Acquired" ] } }, rerun: "snapshot" }
      5.times { post show_reports_path(show), params: { kind: "snapshot" } }
      5.times do
        patch show_path(show), params: rerun
        expect(response.location).to match(%r{/shows/#{show.public_id}/reports/\h{16}\z})
      end

      patch show_path(show), params: rerun
      expect_friendly_page(retry_after: 3600)
      post show_reports_path(show), params: { kind: "snapshot" }
      expect(response).to have_http_status(:too_many_requests)

      patch show_path(show), params: { show: { downloads_per_episode: "2500" } }
      expect(response).to redirect_to(show_path(show))
    end

    it "counts the path however it is spelled: a format, doubled slashes or a trailing slash" do
      requests = [ [ :post, "/shows/#{show.public_id}/reports.html" ], [ :post, "/shows//#{show.public_id}//reports" ],
                   [ :post, "/shows/#{show.public_id}/reports/" ] ]
      expect_all_counted(requests, limit: 10, params: { kind: "snapshot" })
    end
  end

  describe "pitch creates: 30 an hour per user" do
    # A judge has unlimited pitches; after the first, each create shows the pitch still being written.
    let(:user) { create(:user, judge: true) }
    let(:match) { judge_match(user) }

    before { sign_in user }

    def judge_match(judge)
      create(:sponsor_match, report: create(:report, show: create(:show, user: judge), kind: "agent", status: "done"))
    end

    it "answers the 31st with a stream that replaces the flash, and counts each user apart" do
      30.times do
        post sponsor_match_pitch_path(match), headers: turbo_stream
        expect(response).to have_http_status(:ok)
      end
      post sponsor_match_pitch_path(match), headers: turbo_stream
      expect_flash_stream(retry_after: 3600)

      other = create(:user, judge: true)
      sign_in other
      post sponsor_match_pitch_path(judge_match(other)), headers: turbo_stream
      expect(response).to have_http_status(:ok)
    end

    it "counts a signed-out client by IP" do
      match
      sign_out user
      30.times do
        post sponsor_match_pitch_path(match), env: from("198.51.100.40")
        expect(response).to redirect_to("/users/sign_in")
      end
      post sponsor_match_pitch_path(match), env: from("198.51.100.40")
      expect_friendly_page(retry_after: 3600)

      post sponsor_match_pitch_path(match), env: from("198.51.100.41")
      expect(response).to redirect_to("/users/sign_in")
    end

    it "counts the path however it is spelled" do
      requests = [ [ :post, "/sponsor_matches/#{match.public_id}/pitch.html" ], [ :post, "/sponsor_matches//#{match.public_id}//pitch" ],
                   [ :post, "/sponsor_matches/#{match.public_id}/pitch/" ] ]
      expect_all_counted(requests, limit: 30, headers: turbo_stream)
    end
  end

  describe "show searches: 20 a minute per user, or per IP when signed out" do
    let(:frame) { { "Turbo-Frame" => "search_results" } }

    before { sign_in user }

    it "answers the 21st inside the results frame, then lets the user search again the next minute" do
      20.times do
        get search_shows_path(q: "money"), headers: frame
        expect(response).to have_http_status(:ok)
      end
      get search_shows_path(q: "money"), headers: frame

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("60")
      frame_node = Nokogiri::HTML.fragment(response.body).at_css("turbo-frame#search_results")
      expect(frame_node.at_css("[role='alert']").text.squish).to eq(message)

      travel 1.minute
      get search_shows_path(q: "money"), headers: frame
      expect(response).to have_http_status(:ok)
    end

    it "counts each signed-in user apart on one IP, and falls back to the IP when signed out" do
      21.times { get search_shows_path(q: "money"), headers: frame }
      expect(response).to have_http_status(:too_many_requests)

      other = create(:user)
      sign_in other
      get search_shows_path(q: "money"), headers: frame
      expect(response).to have_http_status(:ok)

      sign_out other
      20.times do
        get search_shows_path(q: "money"), env: from("198.51.100.30")
        expect(response).to redirect_to("/users/sign_in")
      end
      get search_shows_path(q: "money"), env: from("198.51.100.30")
      expect(response).to have_http_status(:too_many_requests)
      get search_shows_path(q: "money"), env: from("198.51.100.31")
      expect(response).to redirect_to("/users/sign_in")
    end

    it "counts the path however it is spelled, and HEAD as well as GET" do
      requests = [ [ :head, "/shows/search?q=money" ], [ :get, "/shows/search.html?q=money" ],
                   [ :get, "/shows//search?q=money" ], [ :head, "/shows/search/?q=money" ] ]
      expect_all_counted(requests, limit: 20)
    end
  end

  describe "verification code sends: 5 an hour per show" do
    let(:show) { create(:show, user: user) }

    before { sign_in user }

    it "answers the 6th email send for a show with the friendly page, without touching another show or feed tokens" do
      5.times do
        post show_verification_path(show), params: { kind: "email" }
        expect(response).to have_http_status(:see_other)
      end
      post show_verification_path(show), params: { kind: "email" }
      expect_friendly_page(retry_after: 3600)

      post show_verification_path(show), params: { kind: "feed_token" }
      expect(response).to have_http_status(:see_other)
      post show_verification_path(create(:show, user: user)), params: { kind: "email" }
      expect(response).to have_http_status(:see_other)
    end

    it "never counts another user's sends for the show, which find no show" do
      show
      sign_in create(:user)
      get account_path # keeps the sign in: the session cookie isn't written on a response that raised
      6.times do
        post show_verification_path(show), params: { kind: "email" }
        expect(response).to have_http_status(:not_found)
      end

      sign_in user
      5.times do
        post show_verification_path(show), params: { kind: "email" }
        expect(response).to have_http_status(:see_other)
      end
      post show_verification_path(show), params: { kind: "email" }
      expect_friendly_page(retry_after: 3600)
    end

    it "caps one user at 10 email sends a day across all their shows (R143)" do
      shows = create_list(:show, 11, user: user)
      shows.first(10).each do |each_show|
        post show_verification_path(each_show), params: { kind: "email" }
        expect(response).to have_http_status(:see_other)
        travel 7.minutes # past the 10 a minute tries limit
      end
      post show_verification_path(shows.last), params: { kind: "email" }
      expect_friendly_page(retry_after: 86_400)

      sign_in create(:user)
      get account_path
      post show_verification_path(create(:show, user: User.last)), params: { kind: "email" }
      expect(response).to have_http_status(:see_other)
    end

    it "counts the path however it is spelled, and however a character of the show's public id is spelled" do
      # Percent-encode one character of the public id: the router decodes it, so it is the same show.
      public_id = show.public_id
      encoded_id = format("%%%02X", public_id[0].ord) + public_id[1..]
      requests = [ [ :post, "/shows/#{show.public_id}/verification.html" ], [ :post, "/shows//#{show.public_id}/verification" ],
                   [ :post, "/shows/#{public_id}/verification/" ], [ :post, "/shows/#{encoded_id}/verification" ] ]
      expect_all_counted(requests, limit: 5, params: { kind: "email" })
    end

    it "keeps the 10 tries a minute per user on create and update" do
      10.times do
        patch show_verification_path(show), params: { code: "000000" }
        expect(response).to redirect_to(new_show_verification_path(show))
        expect(flash[:alert]).to be_nil
      end
      patch show_verification_path(show), params: { code: "000000" }
      expect(response).to redirect_to(new_show_verification_path(show))
      expect(flash[:alert]).to eq("Too many tries. Wait a minute, then try again.")
    end
  end
end

# Every other spec: RATE_LIMIT_STORE counts nowhere (config/initializers/rate_limit_store.rb), so however many requests
# an example makes from one IP, none is refused.
RSpec.describe "Rate limits outside :rate_limits examples" do
  it "never answers 429, even past the global limit of 60 a minute" do
    61.times do
      get "/pricing"
      expect(response).to have_http_status(:ok)
    end
  end
end
