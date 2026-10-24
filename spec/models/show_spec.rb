require "rails_helper"

RSpec.describe Show do
  it "requires a title, a user and a way to find the feed" do
    expect(build(:show, title: "")).not_to be_valid
    expect(build(:show, feed_url: nil, directory_id: nil)).not_to be_valid
    expect(build(:show, feed_url: nil, directory_id: "fake-1")).to be_valid
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

    it "does not let one user add the same directory id or feed url twice" do
      user = create(:user)
      create(:show, user: user, directory_id: "fake-1", feed_url: "fake://fake-1")
      expect(build(:show, user: user, directory_id: "fake-1", feed_url: "https://x.example/a")).not_to be_valid
      expect(build(:show, user: user, feed_url: "fake://fake-1")).not_to be_valid
      expect(build(:show, directory_id: "fake-1", feed_url: "fake://fake-1")).to be_valid
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
    it "uses the first letters of the first two words" do
      expect(build(:show, title: "The Founder's Ledger").initials).to eq("TF")
      expect(build(:show, title: "Serial").initials).to eq("S")
      expect(build(:show, title: "!!!").initials).to eq("?")
    end
  end

  it "is destroyed with its user" do
    show = create(:show)
    expect { show.user.destroy }.to change(described_class, :count).by(-1)
  end
end
