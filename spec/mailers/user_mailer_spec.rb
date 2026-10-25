require "rails_helper"

# The lifecycle emails (Task 20): welcome after the first sign in, report ready when a full report finishes while its
# owner is away, and runs resumed for the notify list (R81). Each has one next action and no dashes (the copy rules).
RSpec.describe UserMailer do
  include ActiveJob::TestHelper

  let(:user) { create(:user, name: "Ada Lovelace", email: "ada@example.com") }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger") }

  def text(mail) = mail.text_part.body.to_s
  def html(mail) = Nokogiri::HTML(mail.html_part.body.to_s)
  def dash = /[—–]/

  # The mail's one call to action: the link styled as a button.
  def button(mail) = html(mail).at_css("a[data-mail-button]")

  it "starts no text email with a blank line: a leading line of ERB code trims its newline" do
    Dir[Rails.root.join("app/views/*_mailer/*.text.erb")].each do |path|
      first = File.readlines(path).first.to_s.strip
      code_only = first.match?(/\A<%[^=#].*%>\z/)
      expect(code_only && !first.end_with?("-%>")).to be(false), "#{path} starts with a blank line"
    end
  end

  describe "#welcome" do
    let(:mail) { described_class.welcome(user) }

    it "greets the new user by first name and points to adding a show" do
      expect(mail.to).to eq([ "ada@example.com" ])
      expect(mail.subject).to eq("Welcome to Midrolo")
      expect(text(mail)).to include("Hi Ada,", "sponsors your audience already loves", "Add your show", "free Snapshot",
                                    "http://example.com/shows/new")
      expect(button(mail).text.squish).to eq("Add your show")
      expect(button(mail)["href"]).to eq("http://example.com/shows/new")
      expect(text(mail) + mail.html_part.body.to_s).not_to match(dash)
    end

    it "sends nothing to an account without an email address" do
      user.update_columns(email: nil)
      expect(described_class.welcome(user).message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  describe "sending the welcome mail", type: :request do
    before do
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] = mock_google_auth
    end

    after { OmniAuth.config.mock_auth[:google_oauth2] = nil }

    it "sends it once: on the first sign in, never on a later one" do
      expect { get "/users/auth/google_oauth2/callback" }.to have_enqueued_mail(described_class, :welcome).once
      expect(response).to redirect_to("/shows")
      delete "/users/sign_out"

      expect { get "/users/auth/google_oauth2/callback" }.not_to have_enqueued_mail(described_class, :welcome)
    end
  end

  describe "#report_ready" do
    let(:report) { create(:report, show: show, kind: "agent", status: "done", finished_at: 3.minutes.ago) }
    let(:mail) { described_class.report_ready(report) }

    before do
      create(:sponsor_match, report: report, name: "Fieldnote Coffee", fit_score: 91, position: 2)
      create(:sponsor_match, report: report, name: "Ramp", fit_score: 84, position: 1)
      create(:sponsor_match, report: report, name: "Notion", fit_score: 78, position: 3)
      create(:sponsor_match, report: report, name: "Away", fit_score: 60, position: 4)
    end

    it "says the report is ready, names the best fits and links to it" do
      expect(mail.to).to eq([ "ada@example.com" ])
      expect(mail.subject).to eq("Your sponsor report for The Founder's Ledger is ready")
      expect(text(mail)).to include("4 sponsor matches", "Fieldnote Coffee, Ramp and Notion")
      expect(text(mail)).not_to include("Away")
      expect(button(mail).text.squish).to eq("Open your report")
      expect(text(mail)).to start_with("Your full report") # no blank first line
      expect(button(mail)["href"]).to eq("http://example.com/shows/#{show.id}/reports/#{report.id}")
      expect(text(mail) + mail.html_part.body.to_s).not_to match(dash)
    end
  end

  describe "#report_needs_input" do
    let(:report) { create(:report, show: show, kind: "agent", status: "needs_input", finished_at: 3.minutes.ago) }
    let(:mail) { described_class.report_needs_input(report) }

    it "asks for the one missing thing and links to where to give it (R113)" do
      expect(mail.to).to eq([ "ada@example.com" ])
      expect(mail.subject).to eq("Your report needs one more thing")
      expect(text(mail)).to include("The Founder's Ledger", "2 or 3 shows your listeners also love")
      expect(button(mail).text.squish).to eq("Add comparable shows")
      expect(button(mail)["href"]).to eq("http://example.com/shows/#{show.id}/reports/#{report.id}#report_seeds")
      expect(text(mail)).not_to start_with("\n")
      expect(text(mail) + mail.html_part.body.to_s).not_to match(dash)
    end
  end

  describe ReportMailJob do
    let(:report) { create(:report, show: show, kind: "agent", status: "done", finished_at: 2.minutes.ago) }
    let(:needs_input) do
      create(:report, show: create(:show, user: user), kind: "agent", status: "needs_input", finished_at: 2.minutes.ago)
    end

    def subjects = ActionMailer::Base.deliveries.map(&:subject)

    it "mails the owner when the report finished and nobody opened it since" do
      expect { described_class.perform_now(report.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)
      expect(ActionMailer::Base.deliveries.last.subject).to include("is ready")
    end

    it "mails the owner of a full report that needs input (R113)" do
      described_class.perform_now(needs_input.id)

      expect(subjects).to eq([ "Your report needs one more thing" ])
    end

    it "claims each mail before sending it, so a job that runs twice sends it once (R113)" do
      2.times { described_class.perform_now(report.id) }
      2.times { described_class.perform_now(needs_input.id) }

      expect(subjects).to eq([ "Your sponsor report for The Founder's Ledger is ready", "Your report needs one more thing" ])
      expect(report.reload.ready_mailed_at).to be_present
      expect(needs_input.reload.needs_input_mailed_at).to be_present
    end

    it "isn't sent if the report was viewed after finishing, whatever its outcome" do
      report.update!(viewed_at: report.finished_at + 5.seconds)
      needs_input.update!(viewed_at: needs_input.finished_at + 5.seconds)

      expect do
        described_class.perform_now(report.id)
        described_class.perform_now(needs_input.id)
      end.not_to(change { ActionMailer::Base.deliveries.size })
    end

    it "is still sent when the only view came before the report finished" do
      report.update!(viewed_at: report.finished_at - 1.minute)

      expect { described_class.perform_now(report.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)
    end

    it "sends nothing for a Snapshot, a failed report, a sample or a deleted report" do
      snapshot = create(:report, show: show, kind: "snapshot", status: "done", finished_at: 2.minutes.ago)
      failed = create(:report, show: create(:show, user: user), kind: "agent", status: "failed", finished_at: 2.minutes.ago)
      owner = User.create!(email: User::SAMPLES_EMAIL)
      sample = create(:report, show: create(:show, user: owner), kind: "agent", status: "done", finished_at: 2.minutes.ago)

      expect do
        [ snapshot, failed, sample ].each { |r| described_class.perform_now(r.id) }
        described_class.perform_now(0)
      end.not_to(change { ActionMailer::Base.deliveries.size })
    end
  end

  describe "scheduling the report mail" do
    let(:report) { create(:report, show: show, kind: "agent", status: "queued", spend_bucket: "paid") }

    before do
      allow(Research::Run).to receive(:call) { |r| r.save_section!(:summary, "Done.") }
    end

    it "queues it 2 minutes after a full report finishes" do
      freeze_time do
        expect { GenerateReportJob.perform_now(report.id) }
          .to have_enqueued_job(ReportMailJob).with(report.id).at(2.minutes.from_now)
      end
    end

    it "queues it 2 minutes after a full report ends needing input (R113)" do
      allow(Research::Run).to receive(:call) { |r| r.mark_needs_input! }

      freeze_time do
        expect { GenerateReportJob.perform_now(report.id) }
          .to have_enqueued_job(ReportMailJob).with(report.id).at(2.minutes.from_now)
      end
    end

    it "queues nothing for a Snapshot or a report that failed" do
      snapshot = create(:report, show: create(:show, user: user), kind: "snapshot", status: "queued")
      expect { BuildSnapshotJob.perform_now(snapshot.id) }.not_to have_enqueued_job(ReportMailJob)

      allow(Research::Run).to receive(:call).and_raise(Taste::Unavailable, "503")
      allow(Rails.error).to receive(:report)
      expect { GenerateReportJob.perform_now(report.id) }.not_to have_enqueued_job(ReportMailJob)
    end
  end

  describe "#runs_resumed" do
    let(:entry) { WaitlistEntry.join(email: "ada@example.com", price_key: Billing::NOTIFY_KEY, user: user) }
    let(:mail) { described_class.runs_resumed(entry) }

    it "tells the list new reports are back, with a way in" do
      expect(mail.to).to eq([ "ada@example.com" ])
      expect(mail.subject).to eq("New reports are back on Midrolo")
      expect(text(mail)).to include("New reports are back")
      expect(button(mail).text.squish).to eq("Go to my shows")
      expect(button(mail)["href"]).to eq("http://example.com/shows")
      expect(text(mail) + mail.html_part.body.to_s).not_to match(dash)
    end
  end

  describe RunsResumedMailJob do
    let!(:first) { WaitlistEntry.join(email: "ada@example.com", price_key: Billing::NOTIFY_KEY, user: user) }
    let!(:second) { WaitlistEntry.join(email: "grace@example.com", price_key: Billing::NOTIFY_KEY) }
    let!(:founding) { WaitlistEntry.join(email: "linus@example.com", price_key: "creator_monthly") }

    it "mails each notify entry once, however often it runs, and never the founding member list" do
      perform_enqueued_jobs do
        described_class.perform_now
        described_class.perform_now
      end

      expect(ActionMailer::Base.deliveries.map(&:to).flatten).to contain_exactly("ada@example.com", "grace@example.com")
      expect([ first.reload, second.reload ].map(&:notified_at)).to all(be_present)
      expect(founding.reload.notified_at).to be_nil
    end

    it "waits for the next resume when runs were paused again before it ran" do
      AppSettings.pause_runs!("Again")

      expect { described_class.perform_now }.not_to have_enqueued_mail(UserMailer, :runs_resumed)
      expect(first.reload.notified_at).to be_nil
    end

    it "puts a notified entry back on the list when its owner asks again on the next pause" do
      first.update!(notified_at: 1.day.ago)

      expect(WaitlistEntry.join(email: "ada@example.com", price_key: Billing::NOTIFY_KEY, user: user).notified_at).to be_nil
      expect(WaitlistEntry.join(email: "linus@example.com", price_key: "creator_monthly").notified_at).to be_nil
    end
  end
end
