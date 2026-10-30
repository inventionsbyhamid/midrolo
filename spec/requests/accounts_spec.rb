require "rails_helper"

RSpec.describe "Account" do
  let(:user) { create(:user, name: "Ada Lovelace") }

  it "requires sign-in" do
    get "/account"
    expect(response).to redirect_to("/users/sign_in")
  end

  it "renders plan, usage, upgrade and delete sections" do
    sign_in user
    get "/account"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Your plan", "Free", "Usage", "Upgrade", "Delete account", "Sign out", user.email, "AL")
  end

  # R151: everyone gets the Pro trial, so there is no judge code to enter.
  it "has no judge code form or route" do
    sign_in user
    get "/account"
    expect(response.body).not_to include("Judge code")

    post "/account/judge_code", params: { code: "anything" }
    expect(response).to have_http_status(:not_found)
    expect(user.reload.judge).to be false
  end

  describe "plan and usage" do
    def card(title)
      Nokogiri::HTML(response.body).css(".card").find { |node| node.at_css("h2")&.text&.squish == title }
    end

    # Each usage item's label and words, as the page shows them.
    def usage = card("Your plan").css(".usage-item").to_h { |item| [ item.at_css(".usage-label").text, item.at_css(".usage-count").text.squish ] }

    # A kind's usage bar as its segments' states (on, busy, off), or nil when it has none.
    def bar(kind)
      card("Your plan").at_css(".usage-item[data-kind='#{kind}'] .usage-bar")&.css(".usage-seg")&.map { |seg| seg["class"][/usage-seg-(\w+)/, 1] }
    end

    let(:show) { create(:show, user: user) }

    it "shows the free plan and this month's usage, with no bar for what Free leaves out" do
      create(:report, show: show, kind: "snapshot", status: "done")
      sign_in user
      get "/account"

      expect(card("Your plan").at_css(".badge").text.squish).to eq("Free")
      expect(card("Your plan").text.squish).to include("You're on the Free plan.")
      expect(card("Your plan").at_css("a[href='#{pricing_path}']").text).to eq("See plans")
      expect(usage).to eq("Full reports" => "Not on the Free plan", "Snapshots" => "1 of 1 used this month",
                          "Pitches" => "Not on the Free plan")
      expect(card("Your plan").at_css(".usage-item[data-kind='snapshot'] .usage-count strong").text).to eq("1 of 1")
      expect(card("Your plan").css(".usage-item-off").map { |item| item["data-kind"] }).to eq(%w[agent pitch])
      expect([ bar(:agent), bar(:snapshot), bar(:pitch) ]).to eq([ nil, %w[on], nil ])
      expect(card("Your plan").at_css(".usage-bar")["aria-hidden"]).to eq("true") # the words say it already
      expect(card("Your plan").at_css("ul[aria-labelledby='usage_heading']")).to be_present
      expect(card("Your plan").at_css("#usage_heading").text).to eq("Usage")
    end

    it "shows a subscriber's plan and this billing period's done work only, a segment per report" do
      create(:subscription, user: user, plan: "creator", current_period_start: 3.days.ago)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid", created_at: 1.day.ago)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid", created_at: 5.days.ago)
      create(:report, show: show, kind: "agent", status: "failed", spend_bucket: "paid")
      sign_in user
      get "/account"

      expect(card("Your plan").text.squish).to include("Creator", "You're on the Creator plan.")
      expect(usage).to eq("Full reports" => "1 of 4 used this billing period", "Snapshots" => "0 of 4 used this billing period",
                          "Pitches" => "0 of 40 used this billing period")
      expect(bar(:agent)).to eq(%w[on off off off])
      expect(bar(:pitch)).to eq(%w[off] * PlansHelper::USAGE_SEGMENTS) # 40 pitches scale to the bar's 20 segments
      expect(card("Your plan").at_css("a[href='#{pricing_path}']")).to be_nil
    end

    it "counts work in progress apart from done work, as the upgrade prompt does" do
      create(:subscription, user: user, plan: "creator")
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid")
      create(:report, show: create(:show, user: user), kind: "agent", status: "running", started_at: 1.minute.ago)
      sign_in user
      get "/account"

      expect(usage["Full reports"]).to eq("1 of 4 used this billing period, 1 in progress")
      expect(bar(:agent)).to eq(%w[on busy off off])
    end

    it "gives the sprint's length from plans.yml" do
      create(:subscription, user: user, plan: "sprint", current_period_end: 29.days.from_now)
      allow(Entitlements).to receive(:limits).and_wrap_original do |original, key|
        key.to_sym == :sprint ? original.call(key).merge(duration_days: 14) : original.call(key)
      end
      sign_in user
      get "/account"

      expect(card("Your plan").text.squish).to include("You're on the Sprint plan: Pro features for 14 days.")
    end

    it "shows judge access with its reports in total and unlimited pitches, never a huge number or a bar" do
      user.update!(judge: true)
      create(:report, show: show, kind: "agent", status: "done", spend_bucket: "judge", created_at: 2.months.ago)
      sign_in user
      get "/account"

      expect(card("Your plan").text.squish)
        .to include("Judge access", "Judge access is on: Pro features with 3 full reports and unlimited pitches.")
      expect(usage).to eq("Full reports" => "1 of 3 used", "Snapshots" => "0 of 12 used this month", "Pitches" => "Unlimited")
      expect([ bar(:agent), bar(:snapshot)&.size, bar(:pitch) ]).to eq([ %w[on off off], 12, nil ])
      expect(response.body).not_to include("Infinity", "∞")
    end

    it "shows the promo" do
      AppSettings.set(:promo_pro_until, 1.week.from_now.to_date.to_s)
      sign_in user
      get "/account"

      expect(card("Your plan").at_css(".badge").text.squish).to eq("Pro trial")
      expect(card("Your plan").text.squish)
        .to include("Free Pro through #{1.week.from_now.strftime('%b %-d')}: up to 3 shows, each with a Snapshot and a " \
                    "full report. After that, you're on the Free plan.")
      expect(Nokogiri::HTML(response.body).at_css("main").text.downcase).not_to include("hackathon")
      expect(usage).to eq("Full reports" => "0 of 3 used", "Snapshots" => "0 of 3 used this month",
                          "Pitches" => "0 of 60 used this month")
    end
  end

  describe "billing (R66)" do
    def card(title)
      Nokogiri::HTML(response.body).css(".card").find { |node| node.at_css("h2")&.text&.squish == title }
    end

    def forms_to(path, title = "Upgrade") = card(title).css("form[action='#{path}']")

    def tile(plan) = card("Upgrade").at_css(".upgrade-tile[data-plan='#{plan}']")

    # A tile's price keys by interval, from the plan buttons' forms.
    def tile_keys(plan)
      tile(plan).css(".upgrade-tile-action").to_h { |action| [ action["data-interval"], action.at_css("input[name=price_key]")["value"] ] }
    end

    around { |example| travel_to(Time.zone.local(2026, 10, 25, 12)) { example.run } }

    it "offers the waitlist for every price in waitlist mode, with no checkout" do
      with_billing_env do
        sign_in user
        get "/account"
      end

      expect(card("Upgrade").css("p.upgrade-note").map { |note| note.text.squish }).to eq([ PlansHelper::WAITLIST_DETAIL ])
      expect(forms_to("/waitlist_entries").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(forms_to("/waitlist_entries").map { |form| form.at_css("[type=submit]")["value"] }.uniq)
        .to eq([ "Join the waitlist" ])
      expect(forms_to("/waitlist_entries").css("[type=submit]").map { |button| button["class"] }.uniq)
        .to eq([ "btn btn-secondary btn-sm" ]) # three tiles, no wall of primaries (review C-1)
      expect(forms_to("/waitlist_entries").css("input[name=email]")).to be_empty # signed in: the account's email
      expect(forms_to("/checkouts")).to be_empty
      expect(card("Upgrade").text).not_to include("Test mode")
    end

    it "shows a compact tile per plan: its prices by interval, three highlights and a button per price" do
      with_billing_env do
        sign_in user
        get "/account"
      end

      tiles = card("Upgrade").css(".upgrade-tile")
      expect(tiles.map { |node| node.at_css("h3").text }).to eq(%w[Creator Pro Sprint])
      expect(tiles.map { |node| node["aria-labelledby"] }).to eq(%w[upgrade_creator_name upgrade_pro_name upgrade_sprint_name])
      prices = tiles.to_h { |node| [ node["data-plan"], node.css(".upgrade-tile-price").to_h { |price| [ price["data-interval"], price.text.squish ] } ] }
      expect(prices).to eq("creator" => { "monthly" => "$19/month", "yearly" => "$190/year" },
                           "pro" => { "monthly" => "$49/month", "yearly" => "$490/year" },
                           "sprint" => { "once" => "$49 once" })
      expect(tile(:creator).css(".upgrade-tile-facts li").map(&:text))
        .to eq([ "1 show", "4 full reports and 40 pitch packs a month", "Every match, with its evidence" ])
      expect(tile(:pro).css(".upgrade-tile-facts li").map(&:text))
        .to eq([ "3 shows", "12 full reports and 150 pitch packs a month", "Deeper scan: 12 similar shows, not 8" ])
      expect(tile(:sprint).css(".upgrade-tile-facts li").map(&:text))
        .to eq([ "30 days of Pro", "One payment, no renewal", "Good for a new season's launch" ])
      expect([ tile_keys(:creator), tile_keys(:pro), tile_keys(:sprint) ])
        .to eq([ { "monthly" => "creator_monthly", "yearly" => "creator_yearly" },
                 { "monthly" => "pro_monthly", "yearly" => "pro_yearly" }, { "once" => "sprint" } ])
      expect(tiles.select { |node| node["class"].include?("upgrade-tile-featured") }.map { |node| node["data-plan"] })
        .to eq([ "creator" ])
      expect(card("Upgrade").at_css(".card-header a[href='#{pricing_path}']").text).to eq("Compare all plans")
    end

    it "switches the tiles between monthly and yearly with two radios, as /pricing does" do
      sign_in user
      get "/account"

      switch = card("Upgrade").at_css("fieldset.interval-switch")
      expect(switch.at_css("legend").text).to eq("Billing period")
      radios = switch.css("input[type=radio]")
      expect(radios.map { |radio| [ radio["id"], radio["name"], radio["value"], radio.key?("checked") ] })
        .to eq([ [ "upgrade_interval_monthly", "upgrade_interval", "monthly", true ],
                 [ "upgrade_interval_yearly", "upgrade_interval", "yearly", false ] ])
      expect(radios.map { |radio| radio.parent.name }).to eq(%w[label label]) # the label is the control you click
      expect(switch.css("label").map { |label| label.text.squish }).to eq([ "Monthly", "Yearly 2 months free" ])
      expect(card("Upgrade")["class"].split).to include("upgrade") # the :has() rules in account.css key on it
    end

    it "says which plans the user is on the waitlist for, by the account's email" do
      WaitlistEntry.join(email: user.email.upcase, price_key: "sprint")
      with_billing_env do
        sign_in user
        get "/account"
      end

      expect(tile(:sprint).at_css(".upgrade-tile-action").text.squish).to eq("On the waitlist")
      expect(tile(:sprint).at_css("form")).to be_nil
      expect(forms_to("/waitlist_entries").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly])
    end

    it "also offers a judge a test checkout, with the test-card note" do
      user.update!(judge: true)
      with_billing_env do
        sign_in user
        get "/account"
      end

      expect(forms_to("/waitlist_entries").size).to eq(5)
      expect(forms_to("/checkouts").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(forms_to("/checkouts").map { |form| form.at_css("[type=submit]").text.squish }.uniq)
        .to eq([ "Try checkout in test mode" ])
      expect(card("Upgrade").text).to include(BillingHelper::TEST_NOTE)
    end

    it "offers checkout to everyone in test mode" do
      with_billing_env("BILLING_MODE" => "test") do
        sign_in user
        get "/account"
      end

      expect(forms_to("/checkouts").map { |form| form.at_css("input[name=price_key]")["value"] })
        .to eq(%w[creator_monthly creator_yearly pro_monthly pro_yearly sprint])
      expect(forms_to("/checkouts").map { |form| form.at_css("[type=submit]").text.squish }.uniq)
        .to eq([ "Choose Creator", "Choose Pro", "Choose Sprint" ])
      expect(forms_to("/waitlist_entries")).to be_empty
      expect(card("Upgrade").at_css(".upgrade-note")).to be_nil
      expect(card("Upgrade").text).to include(BillingHelper::TEST_NOTE)
    end

    it "shows a subscriber the renewal date and Manage billing, and no tiles, in test and live modes" do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1",
                            current_period_end: Time.zone.local(2026, 11, 24, 12))
      with_billing_env("BILLING_MODE" => "test") do
        sign_in user
        get "/account"
      end

      expect(card("Your plan").text.squish).to include("Renews on Nov 24, 2026.")
      expect(forms_to("/billing_portal", "Your plan").at_css("[type=submit]").text.squish).to eq("Manage billing")
      expect(card("Upgrade")).to be_nil
      expect(Nokogiri::HTML(response.body).css(".upgrade-tile, form[action='/checkouts'], form[action='/waitlist_entries']"))
        .to be_empty
    end

    it "shows Manage billing in any mode, the waitlist included, when there is a customer id (R73)" do
      create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1")
      with_billing_env do
        sign_in user
        get "/account"
      end
      expect(forms_to("/billing_portal", "Your plan").at_css("[type=submit]").text.squish).to eq("Manage billing")
      expect(card("Upgrade")).to be_nil

      other = create(:user)
      create(:subscription, user: other, provider: "fake", provider_customer_id: nil)
      with_billing_env("BILLING_MODE" => "test") do
        sign_in other
        get "/account"
      end
      expect(forms_to("/billing_portal", "Your plan")).to be_empty
      expect(card("Your plan").at_css(".plan-summary-actions").text.squish)
        .to eq("Your plan is active. Billing management opens with paid plans.")
      expect(card("Upgrade")).to be_nil
    end

    it "says when a plan ends instead of renewing" do
      create(:subscription, user: user, status: "canceled", current_period_end: Time.zone.local(2026, 11, 2, 9))
      sign_in user
      get "/account"
      expect(card("Your plan").text.squish).to include("Ends on Nov 2, 2026. It won't renew.")

      user.subscriptions.sole.update!(status: "active", cancel_at_period_end: true)
      get "/account"
      expect(card("Your plan").text.squish).to include("Ends on Nov 2, 2026. It won't renew.")
    end

    it "gives a sprint's end and a failed payment's warning" do
      create(:subscription, user: user, plan: "sprint", current_period_end: Time.zone.local(2026, 11, 20, 12))
      sign_in user
      get "/account"
      expect(card("Your plan").text.squish).to include("Your Sprint ends on Nov 20, 2026.")

      user.subscriptions.sole.update!(plan: "creator", price_key: "creator_monthly", status: "past_due")
      get "/account"
      expect(card("Your plan").text.squish).to include("Your last payment failed. Update your card in Manage billing to keep your plan.")
    end
  end

  it "renders the avatar when there is one" do
    sign_in create(:user, avatar_url: "https://example.com/a.png")
    get "/account"
    expect(response.body).to include("https://example.com/a.png")
  end

  describe "DELETE /account" do
    it "destroys the user and signs out" do
      sign_in user

      expect { delete "/account" }.to change(User, :count).by(-1)

      expect(response).to redirect_to("/")
      get "/account"
      expect(response).to redirect_to("/users/sign_in")
    end

    it "removes the user's shows" do
      sign_in user
      create(:show, user: user)
      other = create(:show)

      expect { delete "/account" }.to change(Show, :count).by(-1)
      expect(Show.exists?(other.id)).to be true
    end

    # R132: deleting the account would leave the provider charging a plan nobody can use.
    describe "while a plan renews" do
      let(:refusal) { "Cancel your plan in Manage billing first, then delete your account." }

      def delete_card
        Nokogiri::HTML(response.body).css(".card").find { |node| node.at_css("h2")&.text&.squish == "Delete account" }
      end

      it "refuses, keeping the account, and points to Manage billing" do
        create(:subscription, user: user, provider: "fake", provider_customer_id: "fake_cus_1", cancel_at_period_end: false)
        sign_in user

        expect { delete "/account" }.not_to change(User, :count)

        expect(response).to redirect_to("/account")
        expect(flash[:alert]).to eq(refusal)
        follow_redirect!
        expect(delete_card.text.squish).to include(refusal)
        expect(delete_card.at_css("form[action='/billing_portal'] [type=submit]").text.squish).to eq("Manage billing")
        expect(delete_card.at_css("form[action='/account']")).to be_nil
      end

      it "refuses while a payment is past due, since the provider still tries to renew it" do
        create(:subscription, user: user, status: "past_due")
        sign_in user

        expect { delete "/account" }.not_to change(User, :count)
        expect(flash[:alert]).to eq(refusal)
      end

      it "deletes once the plan is cancelled at period end, has ended, or never renews (a Sprint)" do
        [ { cancel_at_period_end: true }, { status: "canceled" }, { plan: "sprint", current_period_end: 20.days.from_now } ]
          .each do |attributes|
          owner = create(:user)
          create(:subscription, user: owner, **attributes)
          sign_in owner
          get "/account"
          expect(delete_card.at_css("form[action='/account']")).to be_present
          expect(delete_card.text).not_to include(refusal)

          expect { delete "/account" }.to change(User, :count).by(-1)
          expect(response).to redirect_to("/")
        end
      end
    end

    # R129: the privacy page promises deletion, whatever the account holds. Spend rows stay for the budget totals,
    # with no owner.
    it "deletes an account that holds every kind of record and keeps its spend rows ownerless" do
      show = create(:show, user: user)
      snapshot = create(:report, show: show, kind: "snapshot", status: "done")
      agent = create(:report, show: show, kind: "agent", status: "done", spend_bucket: "paid")
      create(:agent_step, report: agent)
      match = create(:sponsor_match, report: agent, status: "pitched")
      create(:sponsor_match, report: snapshot, status: "saved")
      pitch = Pitch.create!(sponsor_match: match, status: "done")
      Llm::Budget.record!(user: user, bucket: :paid, model: "claude-opus-5-5", tokens: { input: 1000 }, report: agent)
      Llm::Budget.record!(user: user, bucket: :paid, model: "claude-opus-5-5", tokens: { input: 500 }, pitch: pitch)
      create(:subscription, user: user, cancel_at_period_end: true)
      WaitlistEntry.join(email: user.email, price_key: "pro_monthly", user: user)
      verified = create(:show, user: user)
      ShowVerification.create!(show: verified, kind: "email", sent_to: "host@example.com", expires_at: 30.minutes.from_now)
      kit = create(:media_kit, :published, show: verified)
      kit.cover.attach(io: file_fixture("cover.png").open, filename: "cover.png")
      kit.host_photo.attach(io: file_fixture("host.jpg").open, filename: "host.jpg")
      others = create(:show)
      create(:report, show: others)
      spent_before = Llm::Budget.usage

      sign_in user
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { delete "/account" }

      expect(response).to redirect_to("/")
      expect(flash[:notice]).to eq("Your account and data were deleted.")
      expect(User.exists?(user.id)).to be false
      expect(Show.where(user_id: user.id)).to be_empty
      expect(Report.where(id: [ snapshot.id, agent.id ])).to be_empty
      expect(AgentStep.count).to eq(0)
      expect(SponsorMatch.count).to eq(0)
      expect(Pitch.count).to eq(0)
      expect(Subscription.count).to eq(0)
      expect(WaitlistEntry.count).to eq(0)
      expect(ShowVerification.count).to eq(0)
      expect(MediaKit.count).to eq(0)
      expect(ActiveStorage::Attachment.count).to eq(0)
      expect(ActiveStorage::Blob.count).to eq(0)
      expect(SpendEntry.count).to eq(2)
      expect(SpendEntry.pluck(:user_id, :report_id)).to all(eq([ nil, nil ]))
      expect(Llm::Budget.usage).to eq(spent_before)
      expect(Report.where(show: others).count).to eq(1)
    end
  end
end
