require "rails_helper"

# Final review N1, N2 and N4: a claim proves control of the feed it was made against. A feed move must never hand a
# claim, a pending code or a pending token to a feed nobody proved (N1), must leave nothing the old feed planted on the
# podcast once it released a claim (N4), and must keep a real owner's claim when it is no move at all (http to https,
# www., letter case, a trailing slash) or when the new feed shows the same owner (N2).
RSpec.describe "Feed moves and claims" do
  include ActiveJob::TestHelper

  let(:decoy_url) { "https://evil.example.com/feed.xml" }
  let(:real_url) { "https://real.example.com/feed.xml" }
  let(:attacker) { create(:user, email: "x@evil.example.com") }
  let(:podcast) { create(:podcast, :active, title: "Real Show", feed_url: decoy_url, owner_email: "x@evil.example.com") }

  before do
    travel_to Time.utc(2026, 10, 29, 12)
    allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ])
  end

  def feed_xml(owner:, guid: nil, new_feed_url: nil, description: "A show.", episodes: %w[ep-1])
    items = episodes.map do |guid_text|
      "<item><title>#{guid_text}</title><pubDate>Mon, 26 Oct 2026 09:00:00 -0000</pubDate><guid>#{guid_text}</guid></item>"
    end
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>
        <title>Real Show</title><description><![CDATA[#{description}]]></description>
        <itunes:owner><itunes:name>Owner</itunes:name><itunes:email>#{owner}</itunes:email></itunes:owner>
        #{"<podcast:guid>#{guid}</podcast:guid>" if guid}
        #{"<itunes:new-feed-url>#{new_feed_url}</itunes:new-feed-url>" if new_feed_url}
        #{items.join}
      </channel></rss>
    XML
  end

  def decoy_moves_to_real(token_line: nil, real_token: false, real_episodes: %w[ep-1])
    description = token_line || "A show."
    stub_request(:get, decoy_url).to_return(status: 200, body: feed_xml(owner: "x@evil.example.com", new_feed_url: real_url,
                                                                        description: description))
    stub_request(:get, real_url).to_return(status: 200, body: feed_xml(owner: "host@real.example.com", episodes: real_episodes,
                                                                       description: real_token ? description : "The real show."))
  end

  describe "a code or token issued before the feed moved (N1)" do
    let!(:attacker_show) { create(:show, user: attacker, podcast: podcast) }

    it "won't claim the moved podcast with an emailed code, and says the feed moved" do
      verification = ShowVerification.request_code!(attacker_show)
      code = verification.issue_code!
      decoy_moves_to_real
      travel 1.minute
      Catalog::Ingest.call(podcast)
      expect(podcast.reload.feed_url).to eq(real_url)

      expect(verification.reload.check_code(code)).to be(false)
      expect(verification.failure).to eq(:feed_moved)
      expect(attacker_show.reload).not_to be_verified
      expect(podcast.reload.claimed_at).to be_nil
    end

    it "sends a code asked for after the move to the new feed's owner, never the old feed's" do
      decoy_moves_to_real
      Catalog::Ingest.call(podcast)

      expect(podcast.reload.owner_email).to eq("host@real.example.com")
      expect(ShowVerification.request_code!(attacker_show).sent_to).to eq("host@real.example.com")
    end

    it "won't claim it with a feed token, even if the new feed somehow carries the token" do
      verification = ShowVerification.start_feed_token!(attacker_show)
      decoy_moves_to_real(token_line: verification.token_line, real_token: true)
      travel 1.minute
      Catalog::Ingest.call(podcast)

      expect(verification.reload.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:feed_moved)
      expect(attacker_show.reload).not_to be_verified
    end

    it "won't claim it when the move lands between reading the token and verifying" do
      verification = ShowVerification.start_feed_token!(attacker_show)
      decoy_moves_to_real(token_line: verification.token_line)
      reader = Podcasts::FeedReader.new
      allow(Podcasts::FeedReader).to receive(:new).and_return(reader)
      allow(reader).to receive(:read).and_wrap_original do |original, *args, **options|
        original.call(*args, **options).tap { travel 1.second; Catalog::Ingest.call(Podcast.find(podcast.id)) }
      end
      travel 1.minute

      expect(verification.check_feed_token!).to be(false)
      expect(verification.failure).to eq(:feed_moved)
      expect(attacker_show.reload).not_to be_verified
      expect(podcast.reload.claimed_at).to be_nil
    end

    def reader_that_moves_the_feed(owner_email:)
      instance_double(Podcasts::FeedReader).tap do |reader|
        allow(reader).to receive(:read) do
          Podcast.where(id: podcast.id).update_all(feed_url: real_url, owner_email: owner_email)
          PodcastFeedMove.create!(podcast: podcast, from_url: decoy_url, to_url: real_url, via: "new_feed_url")
          Podcasts::Feed.new(title: "Real Show", description: "", owner_email: "x@evil.example.com", owner_name: nil,
                             episodes: [], cadence_days: nil, warnings: [])
        end
      end
    end

    it "won't claim it at once when the feed moved while its owner address was read, nor store the old feed's address" do
      reader = reader_that_moves_the_feed(owner_email: "host@real.example.com")

      expect(Claims::Start.call(user: attacker, podcast: podcast, reader: reader).outcome).to eq(:verify)
      expect(podcast.reload).to have_attributes(claimed_at: nil, owner_email: "host@real.example.com")
    end

    it "refuses the instant claim when the podcast's feed is no longer the one read, whatever address it has" do
      reader = reader_that_moves_the_feed(owner_email: "x@evil.example.com")

      expect { Claims::Start.call(user: attacker, podcast: podcast, reader: reader) }.to raise_error(Show::FeedMoved)
      expect(podcast.reload.claimed_at).to be_nil
    end
  end

  describe "Show#verify! (N1)" do
    let(:show) { create(:show, user: attacker, podcast: podcast) }

    it "refuses a proof made before a recorded feed move, with a plain message" do
      proof_at = Time.current
      travel 1.second
      PodcastFeedMove.create!(podcast: podcast, from_url: decoy_url, to_url: real_url, via: "redirect")

      expect { show.verify!(via: "email", since: proof_at) }
        .to raise_error(Show::FeedMoved, "This show's feed moved; verify it again.")
      expect(show.reload).not_to be_verified
    end

    it "refuses a proof made against another feed, but not one that differs only by scheme, www., case or a slash" do
      expect { show.verify!(via: "feed_token", feed_url: real_url) }.to raise_error(Show::FeedMoved)
      expect { show.verify!(via: "feed_token", feed_url: "http://www.Evil.example.com/feed.xml/") }.not_to raise_error
      expect(show.reload).to be_verified
    end
  end

  describe "a claimed show whose feed URL changes (N2)" do
    let(:old_url) { "http://feeds.real.example.com/show.xml" }
    let(:new_url) { "https://new-host.example.com/show.xml" }
    let(:owner) { create(:user, email: "host@real.example.com") }
    let(:podcast) { create(:podcast, :active, title: "Real Show", feed_url: old_url, owner_email: "host@real.example.com") }
    let!(:owner_show) { create(:show, user: owner, podcast: podcast).tap { |show| show.verify!(via: "feed_token") } }

    def moves_to(url, body)
      stub_request(:get, old_url).to_return(status: 301, headers: { "Location" => url })
      stub_request(:get, url).to_return(status: 200, body: body)
    end

    def expect_kept
      expect(owner_show.reload).to be_verified
      expect(podcast.reload.claimed_at).to be_present
    end

    it "is no move when only the scheme, a leading www., letter case or a trailing slash changed: the URL follows" do
      moves_to("https://www.Feeds.real.example.com/SHOW.xml/", feed_xml(owner: "someone-else@example.com"))

      expect { Catalog::Ingest.call(podcast) }.not_to have_enqueued_mail(ClaimMailer, :feed_moved)
      expect_kept
      expect(podcast.feed_url).to eq("https://www.feeds.real.example.com/SHOW.xml")
      expect(PodcastFeedMove.count).to eq(0)
    end

    it "keeps the claim on a real move when the new feed names the owner's own signed in address" do
      moves_to(new_url, feed_xml(owner: "HOST@real.example.com"))

      expect { Catalog::Ingest.call(podcast) }.not_to have_enqueued_mail(ClaimMailer, :feed_moved)
      expect_kept
      expect(podcast.feed_moves.sole).to have_attributes(to_url: new_url, released_show: nil)
    end

    it "keeps it when the new feed names an address the owner proved with an emailed code" do
      owner.update!(email: "someone@gmail.example.com")
      ShowVerification.create!(show: owner_show, kind: "email", sent_to: "host@real.example.com", verified_at: 1.day.ago,
                               expires_at: 1.day.ago)
      moves_to(new_url, feed_xml(owner: "host@real.example.com"))

      Catalog::Ingest.call(podcast)
      expect_kept
    end

    it "keeps it when the new feed carries the podcast:guid its old URL minted" do
      owner.update!(email: "someone@gmail.example.com")
      guid = Podcast.podcast_guid_for(old_url)
      podcast.update!(podcast_guid: guid)
      moves_to(new_url, feed_xml(owner: "new-team@new-host.example.com", guid: guid))

      Catalog::Ingest.call(podcast)
      expect_kept
    end

    it "releases it otherwise, even when the new feed repeats the stored owner address or guid the old feed only claimed" do
      owner.update!(email: "someone@gmail.example.com")
      copied = "917393e3-1b1e-5cef-ace4-edaa54e1f810"
      podcast.update!(podcast_guid: copied)
      moves_to(new_url, feed_xml(owner: "host@real.example.com", guid: copied))

      expect { Catalog::Ingest.call(podcast) }.to have_enqueued_mail(ClaimMailer, :feed_moved)
      expect(owner_show.reload).not_to be_verified
      expect(podcast.reload).to have_attributes(feed_url: new_url, claimed_at: nil)
      expect(podcast.feed_moves.sole.released_show).to eq(owner_show)
    end
  end

  describe "a move that released a claim (N4)" do
    let!(:attacker_show) { create(:show, user: attacker, podcast: podcast).tap { |show| show.verify!(via: "feed_token") } }
    let(:brand) { create(:brand) }

    it "deletes the old feed's episodes and sponsor reads that the new feed doesn't carry, and recounts the brands" do
      planted = create(:episode, podcast: podcast, guid: "planted-1")
      create(:episode, podcast: podcast, guid: "ep-1")
      create(:sponsor_mention, episode: planted, brand: brand)
      brand.update_columns(sponsor_mentions_count: 1)
      decoy_moves_to_real(real_episodes: %w[ep-1 real-2])

      Catalog::Ingest.call(podcast)

      expect(podcast.reload.claimed_at).to be_nil
      expect(podcast.episodes.pluck(:guid)).to contain_exactly("ep-1", "real-2")
      expect(SponsorMention.where(podcast_id: podcast.id)).to be_empty
      expect(brand.reload.sponsor_mentions_count).to eq(0)
    end

    it "keeps them when no claim was released" do
      attacker_show.update_columns(verified_at: nil)
      podcast.update!(claimed_at: nil)
      create(:episode, podcast: podcast, guid: "older-1")
      decoy_moves_to_real

      Catalog::Ingest.call(podcast)
      expect(podcast.reload.episodes.pluck(:guid)).to contain_exactly("older-1", "ep-1")
    end
  end
end
