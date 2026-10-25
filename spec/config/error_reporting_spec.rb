require "rails_helper"

# config/initializers/error_reporting.rb: errors reported through Rails.error email the admin (AdminMailer.error), at
# most once per error class every 10 minutes, with ids and code locations only: no secrets, no user's data.
RSpec.describe ErrorReporting::AdminMailSubscriber do
  include ActiveJob::TestHelper

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:subscriber) { described_class.new(cache: cache) }

  def report(error, handled: true, severity: :warning, context: {}, source: "application")
    subscriber.report(error, handled: handled, severity: severity, context: context, source: source)
  end

  def raised(error)
    raise error
  rescue StandardError => e
    e
  end

  it "isn't subscribed in test, so specs never email anyone" do
    subscribers = Rails.error.instance_variable_get(:@subscribers)
    expect(subscribers.grep(described_class)).to be_empty
  end

  it "mails the admin about a reported error, through a job" do
    expect { report(raised(ArgumentError.new("bad seeds")), context: { report_id: 42 }) }
      .to have_enqueued_mail(AdminMailer, :error).once
  end

  it "mails once per error class every 10 minutes" do
    freeze_time do
      expect do
        3.times { report(raised(ArgumentError.new("one"))) }
        report(raised(KeyError.new("two")))
      end.to have_enqueued_mail(AdminMailer, :error).twice

      travel 11.minutes
      expect { report(raised(ArgumentError.new("again"))) }.to have_enqueued_mail(AdminMailer, :error).once
    end
  end

  it "sends nothing when it can't count (a cache that's down), rather than a mail per error" do
    allow(cache).to receive(:increment).and_return(nil)

    expect { report(raised(ArgumentError.new("x"))) }.not_to have_enqueued_mail(AdminMailer, :error)
  end

  it "never raises out of the reporter, whatever goes wrong" do
    allow(cache).to receive(:increment).and_raise(RuntimeError, "cache gone")
    allow(Rails.logger).to receive(:error)

    expect { report(raised(ArgumentError.new("x"))) }.not_to raise_error
  end

  it "doesn't come back to itself when its own work reports an error, as Solid Cache does when it is down" do
    calls = 0
    allow(cache).to receive(:increment) do
      calls += 1
      Rails.error.report(RuntimeError.new("cache down #{calls}"), handled: true) # Solid Cache's failsafe does this
      nil
    end
    Rails.error.subscribe(subscriber)

    Rails.error.report(raised(ArgumentError.new("x")), handled: true)

    expect(calls).to eq(1)
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  it "skips info notices" do
    expect { report(raised(ArgumentError.new("x")), severity: :info) }.not_to have_enqueued_mail(AdminMailer, :error)
  end

  describe "what the mail says" do
    let(:admin) { create(:user, admin: true, email: "ops@example.com") }
    let(:user) { create(:user, email: "ada@example.com", name: "Ada Lovelace") }

    around do |example|
      saved = ENV.values_at("DODO_API_KEY", "JUDGE_CODE")
      ENV["DODO_API_KEY"] = "sk_test_not_a_real_key_1234567890"
      ENV["JUDGE_CODE"] = "judge-door-0451"
      example.run
    ensure
      { "DODO_API_KEY" => saved[0], "JUDGE_CODE" => saved[1] }.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end

    before { admin }

    it "carries the class, ids and app code lines, never an email address, a name or a secret" do
      error = RuntimeError.new("Dodo said no for ada@example.com with sk_test_not_a_real_key_1234567890, code judge-door-0451")
      error.set_backtrace([ "/usr/local/bundle/gems/dodo-1.0/lib/dodo.rb:9:in 'call'",
                            Rails.root.join("app/services/billing/sync.rb:42:in 'apply'").to_s ])
      controller = ReportsController.new.tap { |c| c.action_name = "show" }
      context = { report_id: 42, user: user, email: "ada@example.com", while: "marking failed", params: { name: "Ada" },
                  controller: controller, note: "Ada Lovelace asked" }

      perform_enqueued_jobs { report(error, handled: false, severity: :error, context: context) }

      mail = ActionMailer::Base.deliveries.sole
      body = mail.body.to_s
      expect(mail.to).to eq([ "ops@example.com" ])
      expect(mail.subject).to eq("[Midrolo] RuntimeError")
      expect(body).to include("RuntimeError", "report_id: 42", "while: marking failed", "user: User #{user.id}",
                              "controller: ReportsController#show", "unhandled", "app/services/billing/sync.rb:42")
      expect(body).not_to include("ada@example.com", "Ada", "sk_test_not_a_real_key_1234567890", "gems/dodo", "judge-door-0451")
      expect(body).to include("[email]", "[secret]")
    end

    it "goes to ADMIN_EMAIL when it is set, instead of the admin accounts" do
      ENV["ADMIN_EMAIL"] = "alerts@example.com"
      perform_enqueued_jobs { report(raised(ArgumentError.new("x"))) }

      expect(ActionMailer::Base.deliveries.sole.to).to eq([ "alerts@example.com" ])
    ensure
      ENV.delete("ADMIN_EMAIL")
    end
  end
end
