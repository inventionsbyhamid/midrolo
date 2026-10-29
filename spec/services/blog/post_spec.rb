require "rails_helper"

# Blog posts (R148): Markdown files with YAML front matter, read here from spec/fixtures/blog
# (spec/support/blog_posts.rb).
RSpec.describe Blog::Post do
  def source(front_matter, body = "Body text.\n") = "---\n#{front_matter}\n---\n#{body}"

  def parse(front_matter, body = "Body text.\n", slug: "a-post") = described_class.parse(source(front_matter, body), slug: slug)

  def env(name) = allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(name))

  let(:minimal) { "title: A post\ndescription: What it says.\npublished_on: 2026-11-02" }

  describe ".parse" do
    it "reads the front matter, with Midrolo as the author, no tags and not a draft by default" do
      post = parse(minimal)

      expect(post).to have_attributes(slug: "a-post", title: "A post", description: "What it says.",
                                      published_on: Date.new(2026, 11, 2), updated_on: nil, author: "Midrolo", tags: [],
                                      draft?: false, body: "Body text.\n", to_param: "a-post")
      expect(post.modified_on).to eq(Date.new(2026, 11, 2))
    end

    it "reads every optional field, and a quoted date" do
      post = parse(<<~YAML.chomp)
        title: "  A   post "
        description: What it says.
        published_on: "2026-11-02"
        updated_on: 2026-11-09
        author: Sam Rivera
        tags: [Pricing, pricing, " Media kits "]
        draft: true
      YAML

      expect(post).to have_attributes(title: "A post", author: "Sam Rivera", tags: [ "Pricing", "Media kits" ], draft?: true,
                                      published_on: Date.new(2026, 11, 2), modified_on: Date.new(2026, 11, 9))
      expect(post.published_at.iso8601).to eq("2026-11-02T00:00:00Z")
      expect(post.modified_at.iso8601).to eq("2026-11-09T00:00:00Z")
    end

    it "fails loudly, naming the file, when the title is missing or blank" do
      expect { parse("description: D\npublished_on: 2026-11-02") }
        .to raise_error(described_class::Invalid, "a-post.md: missing title")
      expect { parse("title: \"  \"\ndescription: D\npublished_on: 2026-11-02") }
        .to raise_error(described_class::Invalid, /a-post\.md: missing title/)
    end

    it "fails loudly on any other front matter it can't use" do
      {
        "description: D\npublished_on: 2026-11-02\ntitle: [A, B]" => /title must be text/,
        "title: T\npublished_on: 2026-11-02" => /missing description/,
        "title: T\ndescription: D" => /missing published_on/,
        "title: T\ndescription: D\npublished_on: next week" => /published_on must be a date/,
        "title: T\ndescription: D\npublished_on: 2026-11-02\nupdated_on: soon" => /updated_on must be a date/,
        "title: T\ndescription: D\npublished_on: 2026-11-02\ntags: Pricing" => /tags must be a list/,
        "title: T\ndescription: D\npublished_on: 2026-11-02\ndraft: maybe" => /draft must be true or false/,
        "title: T\ndescription: D\npublished_on: 2026-11-02\nsubtitle: S" => /unknown front matter subtitle/,
        "title: T\ndescription: D\npublished_on: 2026-11-02 10:00:00" => /unreadable front matter/,
        "title: [unclosed" => /unreadable front matter/,
        "just a string" => /isn't a list of keys/
      }.each do |front_matter, message|
        expect { parse(front_matter) }.to raise_error(described_class::Invalid, message), front_matter
      end

      expect { described_class.parse("No front matter here.", slug: "a-post") }
        .to raise_error(described_class::Invalid, /no front matter/)
      expect { parse(minimal, slug: "A_Post") }.to raise_error(described_class::Invalid, /lowercase words joined by hyphens/)
    end

    it "changes its version when anything in the file changes" do
      expect(parse(minimal).version).to eq(parse(minimal).version)
      expect(parse(minimal, "Edited.\n").version).not_to eq(parse(minimal).version)
    end
  end

  describe "the body" do
    it "renders Markdown with the GitHub extensions, and counts the reading time from its words" do
      post = parse(minimal, "Some **bold** text.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n~~gone~~\n")

      html = Nokogiri::HTML5.fragment(post.html)
      expect(html.at_css("strong").text).to eq("bold")
      expect(html.at_css(".post-table[role='region'] table")).to be_present
      expect(html.at_css("del").text).to eq("gone")
      expect(post.reading_minutes).to eq(1)
      expect(parse(minimal, "word " * 451).reading_minutes).to eq(3) # 225 words a minute, rounded up
    end

    it "lists the h2s for a table of contents only when there are three or more" do
      three = parse(minimal, "## One\n\n### Inner\n\n## Two\n\n## Two\n")
      expect(three.contents).to eq([ %w[one One], %w[two Two], %w[two-2 Two] ])

      expect(parse(minimal, "## One\n\n## Two\n").contents).to eq([])
    end
  end

  context "with the fixture posts", :blog_posts do
    it "reads every post in the directory, newest first, and the published ones outside development" do
      expect(described_class.all.map(&:slug)).to eq(%w[scheduled-for-later finding-your-first-sponsor
                                                       what-to-charge-for-a-midroll unfinished-draft media-kits-brands-read])
      expect(described_class.published.map(&:slug))
        .to eq(%w[finding-your-first-sponsor what-to-charge-for-a-midroll media-kits-brands-read])
    end

    it "hides drafts and future posts in production, and shows them in development" do
      env("production")
      expect(described_class.published.map(&:slug)).not_to include("unfinished-draft", "scheduled-for-later")
      expect { described_class.find!("unfinished-draft") }.to raise_error(ActiveRecord::RecordNotFound)
      expect { described_class.find!("scheduled-for-later") }.to raise_error(ActiveRecord::RecordNotFound)

      env("development")
      expect(described_class.published.map(&:slug)).to include("unfinished-draft", "scheduled-for-later")
      expect(described_class.find!("unfinished-draft")).to be_draft
      expect(described_class.find!("scheduled-for-later")).to be_scheduled
    end

    it "publishes a future post on its date, with no restart" do
      expect(described_class.published.map(&:slug)).not_to include("scheduled-for-later")

      travel_to Time.utc(2099, 1, 1, 0, 1) do
        expect(described_class.published.first.slug).to eq("scheduled-for-later")
      end
    end

    it "finds a published post by slug, and raises RecordNotFound (a 404) for anything else" do
      expect(described_class.find!("finding-your-first-sponsor").title).to eq("Finding your first sponsor when your show is small")
      expect { described_class.find!("no-such-post") }.to raise_error(ActiveRecord::RecordNotFound, /no-such-post/)
      expect { described_class.find!("../config/database") }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "reads the files once per process, and on every call in development" do
      allow(described_class).to receive(:parse).and_call_original

      2.times { described_class.all }
      expect(described_class).to have_received(:parse).exactly(5).times

      allow(Rails.env).to receive(:development?).and_return(true)
      2.times { described_class.all }
      expect(described_class).to have_received(:parse).exactly(15).times
    end

    it "relates posts that share the most tags first, then the newest" do
      first = described_class.find!("finding-your-first-sponsor") # Sponsorship, Pitching
      expect(first.related.map(&:slug)).to eq(%w[what-to-charge-for-a-midroll media-kits-brands-read])

      kits = described_class.find!("media-kits-brands-read") # shares no tag
      expect(kits.related.map(&:slug)).to eq(%w[finding-your-first-sponsor what-to-charge-for-a-midroll])
      expect(kits.related(limit: 1).map(&:slug)).to eq(%w[finding-your-first-sponsor])
    end
  end

  it "has no posts when its directory is empty or missing" do
    expect(described_class.all).to eq([])
    described_class.directory = Rails.root.join("tmp/no-such-blog")
    expect(described_class.published).to eq([])
  end
end
