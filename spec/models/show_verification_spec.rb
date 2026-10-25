require "rails_helper"

RSpec.describe ShowVerification do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger", owner_email: "jane@example.com") }

  def wrong_code_for(code) = code == "000000" ? "111111" : "000000"

  describe ".request_code!" do
    it "creates an email verification to the feed's owner address and enqueues the code email" do
      verification = nil
      expect { verification = described_class.request_code!(show) }.to have_enqueued_mail(VerificationMailer, :code)

      expect(verification).to have_attributes(kind: "email", sent_to: "jane@example.com", attempts: 0, code_digest: nil)
      expect(verification.masked_sent_to).to eq("j***@example.com")
      expect(verification.expires_at).to be_within(1.second).of(30.minutes.from_now)
    end

    it "is unavailable when the feed lists no owner email" do
      show.update!(owner_email: nil)
      expect { described_class.request_code!(show) }.to raise_error(ShowVerification::Unavailable)
    end

    it "waits at least 60 seconds between sends" do
      freeze_time
      described_class.request_code!(show)
      travel 20.seconds

      expect { described_class.request_code!(show) }
        .to raise_error(ShowVerification::Throttled) { |error| expect([ error.retry_in, error.scope ]).to eq([ 40, :show ]) }
      travel 40.seconds
      expect { described_class.request_code!(show) }.not_to raise_error
    end

    it "sends at most 5 codes per show a day" do
      5.times do
        described_class.request_code!(show)
        travel 61.seconds
      end

      expect { described_class.request_code!(show) }
        .to raise_error(ShowVerification::Throttled) { |error| expect(error.retry_in).to be > 23.hours.to_i }
      travel 1.day
      expect { described_class.request_code!(show) }.not_to raise_error
    end

    describe "the per-address cap (R65)" do
      # Another account added the same feed; its owner address differs only in case and spacing.
      let(:copy) { create(:show, title: show.title, feed_url: show.feed_url, owner_email: " JANE@Example.com ") }

      it "stores the address normalized" do
        expect(described_class.request_code!(copy).sent_to).to eq("jane@example.com")
      end

      it "makes another account wait 60 seconds after a code to the same address" do
        freeze_time
        described_class.request_code!(show)
        travel 15.seconds

        expect { described_class.request_code!(copy) }.to raise_error(ShowVerification::Throttled) { |error|
          expect([ error.reason, error.scope, error.retry_in ]).to eq([ :resend, :address, 45 ])
        }
      end

      it "caps two accounts with the same feed at 5 codes a day to its owner address together" do
        3.times do
          described_class.request_code!(show)
          travel 61.seconds
        end
        2.times do
          described_class.request_code!(copy)
          travel 61.seconds
        end

        expect { described_class.request_code!(copy) }.to raise_error(ShowVerification::Throttled) { |error|
          expect([ error.reason, error.scope ]).to eq([ :daily, :address ])
          expect(error.retry_in).to be > 23.hours.to_i
        }
        expect(described_class.email.where(sent_to: "jane@example.com").count).to eq(5)
        travel 1.day
        expect { described_class.request_code!(copy) }.not_to raise_error
      end

      it "counts every show that names the address, whoever's feed it is" do
        other_feed = create(:show, title: "Unrelated Feed", owner_email: "jane@example.com")
        described_class.request_code!(show)
        travel 61.seconds
        4.times do
          described_class.request_code!(other_feed)
          travel 61.seconds
        end

        expect { described_class.request_code!(show) }
          .to raise_error(ShowVerification::Throttled) { |error| expect(error.scope).to eq(:address) }
      end

      it "takes a transaction-scoped advisory lock on the address while it checks" do
        allow(described_class.connection).to receive(:execute).and_call_original
        described_class.request_code!(copy)

        expect(described_class.connection).to have_received(:execute)
          .with(a_string_matching(/pg_advisory_xact_lock\(#{ShowVerification::ADDRESS_LOCK_NAMESPACE}, hashtext\('jane@example\.com'\)\)/))
      end
    end
  end

  describe "#issue_code! and #check_code" do
    let(:verification) { described_class.request_code!(show) }

    it "stores only an HMAC-SHA256 digest of the code, keyed from secret_key_base" do
      code = verification.issue_code!
      verification.reload

      expect(code).to match(/\A\d{6}\z/)
      expect(verification.attributes.values.map(&:to_s)).not_to include(code)
      key = Rails.application.key_generator.generate_key("show_verification/code", 32)
      expect(verification.code_digest).to eq(OpenSSL::HMAC.hexdigest("SHA256", key, "#{verification.id}:#{code}"))
    end

    it "verifies the show with the right code and gives it a slug from the title" do
      code = verification.issue_code!

      expect(verification.check_code(code)).to be(true)
      expect(show.reload).to have_attributes(verified_at: be_present, slug: "the-founder-s-ledger")
      expect(verification.reload.verified_at).to be_present
    end

    it "accepts the code typed with spaces" do
      code = verification.issue_code!
      expect(verification.check_code(" #{code[0, 3]} #{code[3, 3]} ")).to be(true)
    end

    it "says how many tries are left after a wrong code" do
      code = verification.issue_code!

      expect(verification.check_code(wrong_code_for(code))).to be(false)
      expect(verification.failure).to eq(:wrong_code)
      expect(verification.attempts_left).to eq(4)
    end

    it "locks after 5 wrong codes, even for the right one" do
      code = verification.issue_code!
      5.times { expect(verification.check_code(wrong_code_for(code))).to be(false) }

      expect(verification.reload).to be_locked
      expect(verification.check_code(code)).to be(false)
      expect(verification.failure).to eq(:locked)
      expect(verification.reload.attempts).to eq(5)
      expect(show.reload).not_to be_verified
    end

    it "rejects a code after 30 minutes" do
      code = verification.issue_code!
      travel 31.minutes

      expect(verification.check_code(code)).to be(false)
      expect(verification.failure).to eq(:expired)
      expect(show.reload).not_to be_verified
    end

    it "retires the earlier code once a new one is requested" do
      old_code = verification.issue_code!
      travel 61.seconds
      newer = described_class.request_code!(show)

      expect(verification.reload.check_code(old_code)).to be(false)
      expect(verification.failure).to eq(:expired)
      expect(described_class.current_for(show)).to eq(newer)
    end

    it "gives a second show with the same title the slug title-2" do
      other = create(:show, title: "The Founder's Ledger", owner_email: "sam@example.com")
      first = described_class.request_code!(show)
      first.check_code(first.issue_code!)
      second = described_class.request_code!(other)
      second.check_code(second.issue_code!)

      expect([ show.reload.slug, other.reload.slug ]).to eq(%w[the-founder-s-ledger the-founder-s-ledger-2])
    end

    it "leaves other users' copies of the same feed unverified" do
      copy = create(:show, title: show.title, feed_url: show.feed_url, owner_email: "jane@example.com")
      verification.check_code(verification.issue_code!)

      expect(show.reload).to be_verified
      expect(copy.reload).to have_attributes(verified_at: nil, slug: nil)
    end
  end

  describe "feed tokens" do
    let(:feed_url) { "https://host.example.com/feed.xml" }
    let(:show) { create(:show, user: user, title: "Token Talk", feed_url: feed_url, owner_email: nil) }

    before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

    def feed_xml(description: "A show about tokens.", txt: nil)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>
          <title>Token Talk</title><description><![CDATA[#{description}]]></description>
          #{"<podcast:txt purpose=\"verify\">#{txt}</podcast:txt>" if txt}
          <item><title>Ep 1</title><pubDate>Mon, 12 Oct 2026 09:00:00 -0000</pubDate><guid>t-1</guid></item>
        </channel></rss>
      XML
    end

    it "issues a token and reuses it while it is pending" do
      verification = described_class.start_feed_token!(show)

      expect(verification).to have_attributes(kind: "feed_token", token: match(/\A[a-z0-9]{16}\z/))
      expect(verification.expires_at).to be > 6.days.from_now
      expect(described_class.start_feed_token!(show)).to eq(verification)
    end

    it "verifies when the token is in the channel description" do
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(description: "<p>Great show.</p><p>midrolo-verify=#{verification.token}</p>"))

      expect(verification.check_feed_token!).to be(true)
      expect(show.reload).to have_attributes(verified_at: be_present, slug: "token-talk")
    end

    it "verifies when the token is in podcast:txt" do
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(txt: "midrolo-verify=#{verification.token}"))

      expect(verification.check_feed_token!).to be(true)
    end

    it "re-reads the feed on every check instead of trusting a cached copy" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return({ status: 200, body: feed_xml },
                                             { status: 200, body: feed_xml(txt: "midrolo-verify=#{verification.token}") })

      expect(verification.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:not_found)
      expect(verification.check_feed_token!).to be(true)
      expect(a_request(:get, feed_url)).to have_been_made.twice
    end

    it "asks FeedReader for a fresh read" do
      reader = instance_double(Podcasts::FeedReader)
      allow(Podcasts::FeedReader).to receive(:new).and_return(reader)
      allow(reader).to receive(:read).and_return(Podcasts::Feed.unreadable)

      described_class.start_feed_token!(show).check_feed_token!
      expect(reader).to have_received(:read).with(feed_url, hash_including(fresh: true))
    end

    it "does not accept a different token that starts with this one" do
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(description: "midrolo-verify=#{verification.token}x"))

      expect(verification.check_feed_token!).to be(false)
      expect(show.reload).not_to be_verified
    end

    it "goes through the SSRF guard: an internal feed URL is never fetched" do
      show.update_columns(feed_url: "http://169.254.169.254/latest/meta-data")
      verification = described_class.start_feed_token!(show)

      expect(verification.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:unreadable)
      expect(a_request(:any, /169\.254/)).not_to have_been_made
    end

    it "reports an unreadable feed" do
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return(status: 500)

      expect(verification.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:unreadable)
    end

    it "rejects an expired token" do
      verification = described_class.start_feed_token!(show)
      stub_request(:get, feed_url).to_return(status: 200, body: feed_xml(txt: "midrolo-verify=#{verification.token}"))
      travel 8.days

      expect(verification.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:expired)
      expect(described_class.start_feed_token!(show)).not_to eq(verification)
    end
  end
end
