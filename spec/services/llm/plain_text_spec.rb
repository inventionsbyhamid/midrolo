require "rails_helper"

RSpec.describe Llm::PlainText do
  describe ".sanitize (R100)" do
    it "turns a spaced em or en dash into a comma" do
      expect(described_class.sanitize("Notion fans love tools — and they listen weekly.")).to eq("Notion fans love tools, and they listen weekly.")
      expect(described_class.sanitize("Hi team – we love your coffee.")).to eq("Hi team, we love your coffee.")
    end

    it "turns a spaced dash into a full stop when the next word is capitalised" do
      expect(described_class.sanitize("A strong fit — Your listeners love it.")).to eq("A strong fit. Your listeners love it.")
      expect(described_class.sanitize("Great fit – Notion sponsors similar shows.")).to eq("Great fit. Notion sponsors similar shows.")
    end

    it "turns an unspaced dash into a comma, whatever follows" do
      expect(described_class.sanitize("Founders—Operators love it.")).to eq("Founders, Operators love it.")
    end

    it "reads a dash between two numbers as a range (R100a)" do
      expect(described_class.sanitize("Ages 25–34")).to eq("Ages 25 to 34")
      expect(described_class.sanitize("Ages 25 – 34 lean in.")).to eq("Ages 25 to 34 lean in.")
      expect(described_class.sanitize("From 2020—2024, twice.")).to eq("From 2020 to 2024, twice.")
    end

    it "turns a pair of dashes inside one sentence into a pair of commas, never a full stop (R100a)" do
      expect(described_class.sanitize("these — Notion, Linear — fit")).to eq("these, Notion, Linear, fit")
      expect(described_class.sanitize("Two brands — Notion and Linear — fit well.")).to eq("Two brands, Notion and Linear, fit well.")
    end

    it "pairs dashes only within a sentence" do
      expect(described_class.sanitize("A fit — Notion leads. Then — and only then — pitch.")).to eq("A fit. Notion leads. Then, and only then, pitch.")
    end

    it "treats a dash with space on one side as spaced, and a run of dashes as one" do
      expect(described_class.sanitize("tools —and shows")).to eq("tools, and shows")
      expect(described_class.sanitize("tools—— and shows")).to eq("tools, and shows")
    end

    it "drops a dash at the start or end of a line and keeps the line breaks" do
      expect(described_class.sanitize("Thanks,\n— Maya")).to eq("Thanks,\nMaya")
      expect(described_class.sanitize("Hi there —\nThanks")).to eq("Hi there\nThanks")
      expect(described_class.sanitize("One.\n\nTwo — three.")).to eq("One.\n\nTwo, three.")
    end

    it "doesn't double the punctuation that is already there" do
      expect(described_class.sanitize("A fit, — and a good one.")).to eq("A fit, and a good one.")
    end

    it "leaves hyphens, other text and nil alone" do
      expect(described_class.sanitize("A well-known brand, 3 to 5 reads.")).to eq("A well-known brand, 3 to 5 reads.")
      expect(described_class.sanitize(nil)).to be_nil
    end
  end

  describe ".clip_words" do
    it "keeps text within the limit as it is" do
      expect(described_class.clip_words("Five words are fine here.", 5)).to eq("Five words are fine here.")
    end

    it "keeps the first sentence when it fits" do
      text = "Listeners love Notion. They also love long walks, slow travel, specialty coffee and weekend projects."
      expect(described_class.clip_words(text, 6)).to eq("Listeners love Notion.")
    end

    it "cuts at a word boundary as a last resort, without trailing punctuation" do
      text = "Your listeners love slow travel, specialty coffee, long reads and weekend projects with friends."
      expect(described_class.clip_words(text, 6)).to eq("Your listeners love slow travel, specialty…")
      expect(described_class.clip_words(text, 5)).to eq("Your listeners love slow travel…")
    end

    it "never takes an abbreviation for a first sentence: it cuts at a word boundary instead" do
      squatch = "Dr. Squatch fans share this audience's love of #{(1..20).map { |i| "t#{i}" }.join(' ')} and more."
      clipped = described_class.clip_words(squatch, 25)
      expect(clipped).to start_with("Dr. Squatch fans share")
      expect(clipped.split.size).to eq(25)

      us = "U.S. founders love budgeting apps and side projects. #{'They also love long walks and cheap flights. ' * 3}"
      expect(described_class.clip_words(us, 25)).to eq("U.S. founders love budgeting apps and side projects.")
    end

    it "keeps a first sentence only when it has a real length" do
      text = "Yes. #{(1..30).map { |i| "w#{i}" }.join(' ')}."
      expect(described_class.clip_words(text, 25)).to start_with("Yes. w1 w2")
    end

    it "also holds a character limit" do
      expect(described_class.clip_words("x" * 30, 25, max_chars: 10)).to eq("#{'x' * 9}…")
      expect(described_class.clip_words("aaaa bbbb cccc dddd", 25, max_chars: 12)).to eq("aaaa bbbb…")
    end
  end

  describe ".sentences" do
    it "splits at sentence ends, but not after an abbreviation" do
      expect(described_class.sentences("Dr. Squatch is a fit. U.S. founders love it! Mr. Beast too?"))
        .to eq([ "Dr. Squatch is a fit.", "U.S. founders love it!", "Mr. Beast too?" ])
      expect(described_class.sentences("")).to eq([])
    end
  end

  describe ".word_count" do
    it "counts words separated by whitespace" do
      expect(described_class.word_count(" One two\nthree ")).to eq(3)
      expect(described_class.word_count(nil)).to eq(0)
    end
  end
end
