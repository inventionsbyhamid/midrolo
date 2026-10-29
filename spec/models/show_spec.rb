require "rails_helper"

RSpec.describe Show do
  it "needs a user and a podcast, and reads what it is from the podcast" do
    expect(build(:show, user: nil)).not_to be_valid
    expect(build(:show, podcast: nil)).not_to be_valid

    show = create(:show, title: "The Founder's Ledger", author: "Maya Brandt", directory_id: "fake-1",
                         owner_email: "maya@example.com", categories: %w[Business Finance])
    expect(show).to have_attributes(title: "The Founder's Ledger", author: "Maya Brandt", feed_url: "fake://fake-1",
                                    directory_id: "fake-1", owner_email: "maya@example.com",
                                    categories: %w[Business Finance], slug: show.podcast.slug, initials: "TF")
    expect(described_class.column_names).not_to include("title", "feed_url", "owner_email", "slug")
  end

  describe "hints" do
    it "drops blanks, trims, caps at 5 entries and truncates to 100 characters" do
      show = build(:show, hints: { "comparable_shows" => [ " A ", "", "  ", "B", "C", "D", "E", "F", "G" ],
                                   "topics" => [ "x" * 150, nil ] })
      show.validate

      expect(show.hints[:comparable_shows]).to eq(%w[A B C D E])
      expect(show.hints[:topics]).to eq([ "x" * 100 ])
    end

    it "defaults to empty lists and tolerates garbage" do
      show = build(:show, hints: { "comparable_shows" => "not an array", "other" => 1 })
      show.validate
      expect(show.hints[:comparable_shows]).to eq([])
      expect(show.hints[:topics]).to eq([])
      expect(show.hints.keys).to contain_exactly("comparable_shows", "topics")

      expect(build(:show, hints: nil).tap(&:validate).hints[:topics]).to eq([])
    end
  end

  describe "validations" do
    it "accepts a blank downloads figure but not a negative one" do
      expect(build(:show, downloads_per_episode: nil)).to be_valid
      expect(build(:show, downloads_per_episode: 0)).to be_valid
      expect(build(:show, downloads_per_episode: -1)).not_to be_valid
      expect(build(:show, downloads_per_episode: 1.5)).not_to be_valid
    end

    it "limits country to the supported list, default US" do
      expect(create(:show).country).to eq("US")
      expect(build(:show, country: "GB")).to be_valid
      expect(build(:show, country: "ZZ")).not_to be_valid
    end

    it "validates a contact email when present" do
      expect(build(:show, contact_email: "")).to be_valid
      expect(build(:show, contact_email: "me@example.com")).to be_valid
      expect(build(:show, contact_email: "nope")).not_to be_valid
    end

    it "gives a user one workspace per podcast, while other users have their own" do
      user = create(:user)
      first = create(:show, user: user, directory_id: "fake-1")
      expect(build(:show, user: user, podcast: first.podcast)).not_to be_valid
      expect(build(:show, podcast: first.podcast)).to be_valid
    end
  end

  describe "#verified? and reports" do
    it "is verified once verified_at is set" do
      expect(build(:show)).not_to be_verified
      expect(build(:show, verified_at: Time.current)).to be_verified
    end

    it "has no reports before Task 9" do
      show = create(:show)
      expect(show.latest_report).to be_nil
      expect(show.active_report).to be_nil
    end
  end

  describe "#verify!" do
    it "makes the show the podcast's owner, keeping the first verification's time" do
      show = create(:show, title: "The Founder's Ledger")
      show.verify!(via: "email")
      first = show.reload.verified_at
      expect(show.podcast.reload).to have_attributes(claimed_at: first, owner_show: show)
      expect(show.podcast).to be_claimed

      travel 1.day
      show.verify!(via: "feed_token")
      expect(show.reload.verified_at).to eq(first)
    end

    it "hands the podcast's waiting requests to the new owner, once" do
      show = create(:show)
      allow(Conversations::ClaimHandoff).to receive(:call)

      2.times { show.verify!(via: "email") }
      expect(Conversations::ClaimHandoff).to have_received(:call).with(show.podcast).once
    end

    it "refuses a second owner for a podcast" do
      owner = create(:show).tap { |show| show.verify!(via: "email") }
      other = create(:show, podcast: owner.podcast)

      expect { other.verify!(via: "email") }.to raise_error(Show::AlreadyClaimed, /already claimed/)
      expect(other.reload).not_to be_verified
      expect(owner.podcast.reload.owner_show).to eq(owner)
    end

    it "names how ownership was proven" do
      expect { create(:show).verify!(via: "guess") }.to raise_error(ArgumentError)
    end
  end

  describe "when the owner show goes" do
    it "unclaims the podcast and takes its listing down" do
      show = create(:show)
      create(:media_kit, :published, show: show, open_to_sponsors: true)
      show.podcast.refresh_listing!
      expect(show.podcast.reload).to have_attributes(open_to_sponsors: true, min_price_cents: be_positive)

      show.destroy!
      expect(show.podcast.reload).to have_attributes(claimed_at: nil, open_to_sponsors: false, min_price_cents: nil)
    end
  end

  describe ".with_public_kit" do
    it "matches #public_kit?: verified and published" do
      public_show = create(:show, title: "Public")
      create(:media_kit, :published, show: public_show)
      unpublished = create(:show, title: "Unpublished").tap { |show| show.verify!(via: "admin") }
      create(:media_kit, show: unpublished)
      unverified = create(:show, title: "Unverified")
      create(:media_kit, show: unverified, published_at: Time.current)
      no_kit = create(:show, title: "No kit").tap { |show| show.verify!(via: "admin") }

      expect(described_class.with_public_kit).to contain_exactly(public_show)
      expect([ public_show, unpublished, unverified, no_kit ].map { |show| show.reload.public_kit? })
        .to eq([ true, false, false, false ])
    end
  end

  describe ".http_url" do
    it "keeps http(s) URLs with a host and drops everything else" do
      expect(described_class.http_url(" https://show.example.com/ ")).to eq("https://show.example.com/")
      expect(described_class.http_url("javascript:alert(1)")).to be_nil
      expect(described_class.http_url("mailto:a@example.com")).to be_nil
      expect(described_class.http_url("not a url")).to be_nil
      expect(described_class.http_url(nil)).to be_nil
    end
  end

  describe "#initials" do
    it "uses the first letters of the first two words of the podcast's title" do
      expect(build(:show, title: "The Founder's Ledger").initials).to eq("TF")
      expect(build(:show, title: "Serial").initials).to eq("S")
      expect(build(:show, title: "!!!").initials).to eq("?")
    end
  end

  it "is destroyed with its user, and the podcast stays in the catalog" do
    show = create(:show)
    expect { show.user.destroy }.to change(described_class, :count).by(-1)
    expect(show.podcast.reload).to be_persisted
  end

  it "takes its media kit and verifications with it" do
    show = create(:show, owner_email: "jane@example.com")
    create(:media_kit, show: show)
    ShowVerification.start_feed_token!(show)

    expect { show.destroy }.to change(MediaKit, :count).by(-1).and change(ShowVerification, :count).by(-1)
  end
end
