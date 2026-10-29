require "rails_helper"

RSpec.describe ShareImages::BlogCard, :blog_posts do
  let(:post) { Blog::Post.find!("finding-your-first-sponsor") }

  # Each <text>'s words; a title's lines (tspans) joined with a space.
  def texts(svg)
    Nokogiri::XML(svg) { |config| config.strict }.css("text").map do |node|
      node.css("tspan").any? ? node.css("tspan").map(&:text).join(" ") : node.text
    end
  end

  it "shows the Blog label, the post's title, its date and reading time, and its tags" do
    shown = texts(described_class.new(post).layout.svg)

    expect(shown).to include("Blog", "Finding your first sponsor when your show is small", "October 20, 2026 · 1 min read",
                             "Sponsorship", "Pitching")
    expect(shown.join(" ")).not_to match(/[–—]/) # no dashes in copy
  end

  it "gives a long title three lines before it shortens it" do
    long = Blog::Post.parse(<<~MD, slug: "long")
      ---
      title: How independent podcasters can find sponsors who already love their listeners, and what to send them first
      description: D
      published_on: 2026-10-20
      ---
      Body
    MD
    title = Nokogiri::XML(described_class.new(long).layout.svg).at_css("text[data-role='title']")

    expect(title.css("tspan").size).to eq(3)
  end

  it "draws a 1200x630 PNG, complete (it has no artwork to wait for)" do
    image = described_class.new(post).draw
    png = Vips::Image.new_from_buffer(image.png, "")

    expect(image.complete).to be(true)
    expect([ png.width, png.height ]).to eq([ 1200, 630 ])
  end

  it "keys the cache on the post file, so an edit draws a new card under a new og:image URL" do
    edited = Blog::Post.parse(Rails.root.join("spec/fixtures/blog/finding-your-first-sponsor.md").read + "\nOne more line.\n",
                              slug: post.slug)

    expect(described_class.new(post).cache_key).to start_with("share_images/v#{ShareImages::Card::VERSION}/blog/finding-your-first-sponsor/")
    expect(described_class.new(edited).cache_key).not_to eq(described_class.new(post).cache_key)
    expect(described_class.new(edited).version).not_to eq(described_class.new(post).version)
  end
end
