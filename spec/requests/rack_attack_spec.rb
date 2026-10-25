require "rails_helper"

# Rack::Attack (config/initializers/rack_attack.rb, R69). It is off in every other spec; :rack_attack turns it on over
# an empty store (spec/support/rack_attack.rb). Each example runs at a fixed time inside its windows, so no burst
# straddles a window boundary.
RSpec.describe "Rate limits", :rack_attack do
  let(:user) { create(:user) }
  let(:message) { "Too many requests — try again in a few minutes." }
  let(:turbo_stream) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  # 1,230 seconds into the hour and 30 into the minute.
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

  describe "every request, per IP: 60 a minute" do
    it "answers the 61st with the friendly page, then lets the IP back in the next minute" do
      60.times do
        get "/pricing"
        expect(response).to have_http_status(:redirect)
      end
      get "/pricing"
      expect_friendly_page(retry_after: 30)

      get "/pricing", env: from("203.0.113.9")
      expect(response).to have_http_status(:redirect)

      travel 1.minute
      get "/pricing"
      expect(response).to have_http_status(:redirect)
    end

    it "counts a signed-in user's requests by IP too" do
      sign_in user
      60.times { get "/pricing" }
      get "/account"
      expect(response).to have_http_status(:too_many_requests)
    end

    it "keys on the proxy's X-Forwarded-For, never on a Forwarded header the client sent (R83)" do
      behind_proxy = from("172.18.0.5")
      60.times do |n|
        get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.1", "Forwarded" => "for=203.0.113.#{n}" }, env: behind_proxy
        expect(response).to have_http_status(:redirect)
      end
      get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.1", "Forwarded" => "for=203.0.113.250" }, env: behind_proxy
      expect(response).to have_http_status(:too_many_requests)

      get "/pricing", headers: { "X-Forwarded-For" => "198.51.100.2" }, env: behind_proxy
      expect(response).to have_http_status(:redirect)
    end

    it "never counts or blocks assets, the health check, Action Cable, Active Storage or webhooks" do
      60.times { get "/pricing" }

      get "/up"
      expect(response).to have_http_status(:ok)
      get "/assets/application-missing.css"
      expect(response).not_to have_http_status(:too_many_requests)
      get "/cable"
      expect(response).not_to have_http_status(:too_many_requests)
      get "/rails/active_storage/blobs/redirect/missing/file.png"
      expect(response).not_to have_http_status(:too_many_requests)
      post "/webhooks/nobody"
      expect(response).to have_http_status(:not_found)

      get "/pricing"
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "report creates: 10 an hour per user" do
    let(:show) { create(:show, user: user) }

    before { sign_in user }

    it "answers the 11th with the friendly page, and Retry-After at the end of the hour" do
      10.times do
        post show_reports_path(show), params: { kind: "snapshot" }
        expect(response.location).to match(%r{/shows/#{show.id}/reports/\d+\z})
      end
      post show_reports_path(show), params: { kind: "snapshot" }
      expect_friendly_page(retry_after: 3600 - 1230)
    end

    it "answers a Turbo Stream request with a stream that replaces the flash" do
      10.times do
        post show_reports_path(show), params: { kind: "snapshot" }, headers: turbo_stream
        expect(response.location).to match(%r{/reports/\d+\z})
      end
      post show_reports_path(show), params: { kind: "snapshot" }, headers: turbo_stream

      expect(response).to have_http_status(:too_many_requests)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.headers["Retry-After"]).to eq("2370")
      stream = Nokogiri::HTML.fragment(response.body).at_css("turbo-stream")
      expect(stream.attributes.transform_values(&:value)).to eq("action" => "replace", "target" => "flash")
      flash = Nokogiri::HTML.fragment(stream.at_css("template").inner_html)
      expect(flash.at_css("#flash [role='alert']").text.squish).to eq(message)
    end

    it "counts each signed-in user apart on one IP, and falls back to the IP when signed out" do
      other = create(:user)
      11.times { post show_reports_path(show), params: { kind: "snapshot" } }
      expect(response).to have_http_status(:too_many_requests)

      sign_in other
      post show_reports_path(create(:show, user: other)), params: { kind: "snapshot" }
      expect(response.location).to match(%r{/reports/\d+\z})

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
  end

  describe "pitch creates: 30 an hour per user" do
    # A judge has unlimited pitches; after the first, each create shows the pitch still being written.
    let(:user) { create(:user, judge: true) }
    let(:match) { create(:sponsor_match, report: create(:report, show: create(:show, user: user), kind: "agent", status: "done")) }

    before { sign_in user }

    it "answers the 31st with a 429" do
      30.times do
        post sponsor_match_pitch_path(match), headers: turbo_stream
        expect(response).to have_http_status(:ok)
      end
      post sponsor_match_pitch_path(match), headers: turbo_stream
      expect(response).to have_http_status(:too_many_requests)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end
  end

  describe "show searches: 20 a minute per user" do
    before { sign_in user }

    it "answers the 21st inside the results frame, then lets the user search again the next minute" do
      frame = { "Turbo-Frame" => "search_results" }
      20.times do
        get search_shows_path(q: "money"), headers: frame
        expect(response).to have_http_status(:ok)
      end
      get search_shows_path(q: "money"), headers: frame

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("30")
      frame_node = Nokogiri::HTML.fragment(response.body).at_css("turbo-frame#search_results")
      expect(frame_node.at_css("[role='alert']").text.squish).to eq(message)

      travel 1.minute
      get search_shows_path(q: "money"), headers: frame
      expect(response).to have_http_status(:ok)
    end
  end

  describe "verification code sends: 5 an hour per show" do
    let(:show) { create(:show, user: user) }

    before { sign_in user }

    it "answers the 6th email send for a show with a 429, without touching another show or feed tokens" do
      5.times do
        post show_verification_path(show), params: { kind: "email" }
        expect(response).to have_http_status(:see_other)
      end
      post show_verification_path(show), params: { kind: "email" }
      expect_friendly_page(retry_after: 2370)

      post show_verification_path(show), params: { kind: "feed_token" }
      expect(response).to have_http_status(:see_other)
      post show_verification_path(create(:show, user: user)), params: { kind: "email" }
      expect(response).to have_http_status(:see_other)
    end
  end

  describe "other spellings of a throttled path, which reach the same action (R83)" do
    before { sign_in user }

    it "counts report creates with a format, doubled slashes or a trailing slash" do
      show = create(:show, user: user)
      requests = [ [ :post, "/shows/#{show.id}/reports.html" ], [ :post, "/shows//#{show.id}//reports" ],
                   [ :post, "/shows/#{show.id}/reports/" ] ]
      expect_all_counted(requests, limit: 10, params: { kind: "snapshot" })
    end

    it "counts pitch creates the same way" do
      judge = create(:user, judge: true)
      sign_in judge
      match = create(:sponsor_match, report: create(:report, show: create(:show, user: judge), kind: "agent", status: "done"))
      requests = [ [ :post, "/sponsor_matches/#{match.id}/pitch.html" ], [ :post, "/sponsor_matches//#{match.id}//pitch" ],
                   [ :post, "/sponsor_matches/#{match.id}/pitch/" ] ]
      expect_all_counted(requests, limit: 30, headers: turbo_stream)
    end

    it "counts show searches sent as HEAD as well as GET" do
      requests = [ [ :head, "/shows/search?q=money" ], [ :get, "/shows/search.html?q=money" ],
                   [ :get, "/shows//search?q=money" ], [ :head, "/shows/search/?q=money" ] ]
      expect_all_counted(requests, limit: 20)
    end

    it "counts verification code sends the same way, however the show's id is spelled" do
      show = create(:show, user: user)
      encoded_id = show.id.to_s.chars.map { |digit| format("%%%02X", digit.ord) }.join
      requests = [ [ :post, "/shows/#{show.id}/verification.html" ], [ :post, "/shows//#{show.id}/verification" ],
                   [ :post, "/shows/0#{show.id}/verification/" ], [ :post, "/shows/#{encoded_id}/verification" ] ]
      expect_all_counted(requests, limit: 5, params: { kind: "email" })
    end

    it "counts judge code attempts per IP the same way" do
      requests = [ [ :post, "/account/judge_code.html" ], [ :post, "/account//judge_code" ], [ :post, "/account/judge_code/" ] ]
      5.times do |n|
        sign_in create(:user)
        post requests[n % 3].last, params: { code: "guess" }
        expect(response).to redirect_to(account_path)
      end
      requests.each do |_method, path|
        sign_in create(:user)
        post path, params: { code: "guess" }
        expect(response).to have_http_status(:too_many_requests), "expected POST #{path} to be throttled"
      end
    end
  end

  describe "judge code attempts: 5 an hour per user and 5 an hour per IP" do
    it "stops a user after 5 tries, whatever IP they come from" do
      sign_in user
      5.times do |n|
        post judge_code_account_path, params: { code: "guess-#{n}" }, env: from("192.0.2.#{n + 1}")
        expect(response).to redirect_to(account_path)
      end
      post judge_code_account_path, params: { code: "guess" }, env: from("192.0.2.99")
      expect(response).to have_http_status(:too_many_requests)
    end

    it "stops an IP after 5 tries, whoever is signed in" do
      5.times do
        sign_in create(:user)
        post judge_code_account_path, params: { code: "guess" }, env: from("198.51.100.7")
        expect(response).to redirect_to(account_path)
      end
      sign_in create(:user)
      post judge_code_account_path, params: { code: "guess" }, env: from("198.51.100.7")
      expect(response).to have_http_status(:too_many_requests)

      post judge_code_account_path, params: { code: "guess" }, env: from("198.51.100.8")
      expect(response).to redirect_to(account_path)
    end
  end
end
