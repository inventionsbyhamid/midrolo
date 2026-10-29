require "rails_helper"

RSpec.describe Sponsors::Notes do
  def candidates_for(name)
    fixture = sponsor_fixture(name)
    described_class.new(fixture.notes, sponsor_context(fixture)).candidates
  end

  def summary(candidates)
    candidates.map { |c| [ c.name, c.domain, c.promo_code, c.strong? ] }
  end

  it "reads a Sponsors block: one brand a line, its link on the next, until the next heading" do
    candidates = candidates_for("sponsor_block")

    expect(summary(candidates)).to eq([
      [ "Encord", "encord.com", nil, true ], [ "Notion", "notion.com", nil, true ],
      [ "LMNT", "drinklmnt.com", nil, true ], [ "AG1", "drinkag1.com", nil, true ]
    ])
    expect(candidates.first.url).to eq("https://encord.com/sam")
    expect(candidates.first.evidence).to eq("Encord: AI tooling for annotation and data management. Go to https://encord.com/sam")
    expect(candidates.map(&:signals)).to all(include(:section))
  end

  it "reads host read lead-ins with their vanity links, codes and offers" do
    candidates = candidates_for("host_reads")

    expect(summary(candidates)).to eq([
      [ "AG1", "drinkag1.com", nil, true ], [ "Shopify", "shopify.com", nil, true ], [ "Helix Sleep", "helixsleep.com", "TIM", true ]
    ])
    helix = candidates.last
    expect(helix.offer).to eq("20% off all mattress orders")
    expect(helix.url).to eq("https://helixsleep.com/tim")
    expect(helix.signals).to include(:lead_in, :code, :vanity)
    expect(candidates.first.evidence).to start_with("This episode is brought to you by AG1.")
    expect(candidates.first.evidence).to include("drinkAG1.com/Tim")
  end

  it "reads a promo code next to a domain, without a lead-in, and drops ad choices notices" do
    candidates = candidates_for("promo_codes")

    expect(summary(candidates)).to eq([ [ "shopify.com", "shopify.com", "SIGNAL", true ], [ "manscaped.com", "manscaped.com", "LOST20", true ] ])
    expect(candidates.last.offer).to eq("Get 20% off and free shipping")
    expect(candidates.map(&:domain)).not_to include("megaphone.fm")
  end

  it "reads a list after one lead-in, matching each brand to its own link" do
    candidates = candidates_for("inline_list")

    expect(summary(candidates)).to eq([ [ "Notion", "notion.com", nil, true ], [ "Ramp", "ramp.com", nil, true ], [ "Mercury", nil, nil, true ] ])
    expect(candidates.first.url).to eq("https://notion.com/hardreset")
  end

  it "reads a dashed Sponsors list with codes" do
    expect(summary(candidates_for("sponsors_list_dashes"))).to eq([
      [ "Delete Me", "joindeleteme.com", "DARKWIRE", true ], [ "Vanta", "vanta.com", nil, true ]
    ])
  end

  it "finds no sponsor in self promotion, Patreon, social links, a book, a guest, a negation or a news mention" do
    candidates = candidates_for("false_positives")

    expect(candidates.select(&:strong?)).to be_empty
    expect(candidates.map(&:name)).to eq([ "Pfizer" ]) # "a study sponsored by" is only a hint for the model
    expect(candidates.map(&:domain).compact).to be_empty
  end

  it "keeps softer hints weak, each with its own brand" do
    candidates = candidates_for("weak_hints")

    expect(summary(candidates)).to eq([ [ "Wealthfront", nil, nil, false ], [ "Athletic Brewing", "athleticbrewing.com", nil, false ] ])
    expect(candidates.last.offer).to eq("20% off your first order")
  end

  describe "one sentence at a time" do
    let(:context) { Sponsors::Context.new(title: "Quiet Hours", author: "Ivy Chen", urls: [ "https://quiethours.fm" ]) }

    def names(text) = described_class.new(text, context).candidates.select(&:strong?).map(&:name)

    it "takes the lead-ins sponsor reads open with" do
      expect(names("Support for this podcast comes from Mint Mobile.")).to eq([ "Mint Mobile" ])
      expect(names("Today's sponsor is Rocket Money.")).to eq([ "Rocket Money" ])
      expect(names("Thanks to Wix for sponsoring this episode.")).to eq([ "Wix" ])
      expect(names("This episode is sponsored by Hims & Hers.")).to eq([ "Hims & Hers" ])
      expect(names("Sponsored by iRacing and 1Password.")).to eq(%w[iRacing 1Password])
      expect(names("Brought to you by our friends at Mercury.")).to eq([ "Mercury" ])
    end

    it "ignores credits, listener thanks and the show's own plugs" do
      expect(names("Music by Blue Dot Sessions. Produced by Ivy Chen.")).to be_empty
      expect(names("This episode is brought to you by listeners like you. Become a patron!")).to be_empty
      expect(names("Brought to you by Patreon supporters, Ko-fi tips and Spotify.")).to be_empty
      expect(names("Quiet Hours is brought to you by Quiet Hours Media and Ivy Chen.")).to be_empty
      expect(names("Merch at quiethours.fm/shop, use code QUIET.")).to be_empty
      expect(names("This show is not sponsored by Nike.")).to be_empty
      expect(names("Sponsors: Email ads@quiethours.fm to advertise.")).to be_empty
      expect(names("Get 20% off my new course at learnwithivy.com with code IVY.")).to be_empty
    end

    it "takes a vanity path only when it's made for this show" do
      context = Sponsors::Context.new(title: "Quiet Hours", author: "Ivy Chen")
      vanity = ->(text) { described_class.new(text, context).candidates.select { |c| c.signals.include?(:vanity) }.map(&:domain) }

      expect(vanity.("Go to betterhelp.com/quiet for 10% off your first month.")).to eq([ "betterhelp.com" ])
      expect(vanity.("Go to betterhelp.com/ivy.")).to eq([ "betterhelp.com" ])
      expect(vanity.("Read it at nytimes.com/quiet-hours-review and wired.com/story/quiet-hours.")).to be_empty
    end
  end

  it "gives the model only the sentences around its candidates" do
    fixture = sponsor_fixture("sponsor_block")
    notes = described_class.new(fixture.notes, sponsor_context(fixture))

    expect(notes.excerpt).to include("SPONSORS:", "Encord: AI tooling", "drinkag1.com/sam")
    expect(notes.excerpt).not_to include("Why we sleep", "danawu")
    expect(notes.excerpt.length).to be <= described_class::EXCERPT_LIMIT
  end
end
