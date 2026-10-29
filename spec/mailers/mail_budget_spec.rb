require "rails_helper"

# The outgoing mail budget (R143): Resend's free tier allows 100 emails a day and 3,000 a month, so whatever anyone
# triggers, the app sends at most MAIL_DAILY_LIMIT a day and MAIL_MONTHLY_LIMIT a month, and low-priority mail stops
# early so codes and report mail keep the rest.
RSpec.describe MailBudget do
  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.utc(2026, 10, 29, 12) }
  let(:budget) { described_class.new(store: store, clock: -> { now }, daily_limit: 5, monthly_limit: 8) }

  def message(low: false)
    Mail.new(from: "hello@midrolo.com", to: "a@example.com", subject: "Hi", body: "x").tap do |mail|
      mail[MailBudget::PRIORITY_HEADER] = "low" if low
    end
  end

  def deliver(mail)
    budget.delivering_email(mail)
    mail.perform_deliveries
  end

  it "sends up to the daily limit, then holds the rest back until the next UTC day" do
    expect(Array.new(5) { deliver(message) }).to all(be(true))
    expect(deliver(message)).to be(false)

    now = Time.utc(2026, 10, 30, 0, 1)
    next_day = described_class.new(store: store, clock: -> { now }, daily_limit: 5, monthly_limit: 8)
    mail = message
    next_day.delivering_email(mail)
    expect(mail.perform_deliveries).to be(true)
  end

  it "holds mail back once the month's limit is reached, whatever the day" do
    days = (1..8).map { |d| described_class.new(store: store, clock: -> { Time.utc(2026, 10, d) }, daily_limit: 5, monthly_limit: 8) }
    expect(days.map { |b| m = message; b.delivering_email(m); m.perform_deliveries }).to all(be(true))
    late = described_class.new(store: store, clock: -> { Time.utc(2026, 10, 20) }, daily_limit: 5, monthly_limit: 8)
    mail = message
    late.delivering_email(mail)
    expect(mail.perform_deliveries).to be(false)
  end

  it "stops low-priority mail at 60% of the daily limit, keeping the rest for codes and report mail" do
    expect(Array.new(3) { deliver(message(low: true)) }).to all(be(true))
    expect(deliver(message(low: true))).to be(false)
    expect(deliver(message)).to be(true)
    expect(deliver(message)).to be(true)
    expect(deliver(message)).to be(false)
  end

  it "never sends its own priority header on" do
    mail = message(low: true)
    budget.delivering_email(mail)
    expect(mail[MailBudget::PRIORITY_HEADER]).to be_nil
  end

  it "holds mail back when the counters can't be read, since the caps protect a hard allowance" do
    nulled = described_class.new(store: ActiveSupport::Cache::NullStore.new, clock: -> { now }, daily_limit: 5, monthly_limit: 8)
    mail = message
    nulled.delivering_email(mail)
    expect(mail.perform_deliveries).to be(false)
  end

  it "takes no slot for a message it holds back" do
    5.times { deliver(message) }
    3.times { deliver(message) }
    expect(store.read(budget.send(:day_key))).to eq(5)
  end

  it "reads its limits from the environment, with defaults under Resend's free tier" do
    expect(described_class.daily_limit).to eq(90)
    expect(described_class.monthly_limit).to eq(2800)
  end

  it "is the production interceptor" do
    production = Rails.root.join("config/environments/production.rb").read
    expect(production).to include('config.action_mailer.interceptors = %w[MailBudget]')
  end

  it "marks welcome and runs-resumed mail as low priority" do
    user = create(:user)
    expect(UserMailer.welcome(user).message[MailBudget::PRIORITY_HEADER].to_s).to eq("low")
  end
end
