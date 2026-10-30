require "rails_helper"

# The real post at content/blog/podcorn-alternative.md, for podcasters leaving Audacy Creator Lab (formerly Podcorn),
# which closes on November 1, 2026. Other blog specs read fixtures; this one reads content/blog, so it checks that the
# post is live from its date, is listed on /blog, carries the same search and share tags as every post, and keeps the
# line saying Midrolo isn't affiliated with Audacy, Creator Lab or Podcorn (the wording of pages/home/_creator_lab).
RSpec.describe "The Podcorn alternative post" do
  def page = Nokogiri::HTML(response.body)
  def meta(attribute, name) = page.css("meta[#{attribute}='#{name}']").map { |tag| tag["content"] }

  let(:title) { "Podcorn alternative: finding podcast sponsors after Creator Lab" }
  let(:url) { "http://www.example.com/blog/podcorn-alternative" }

  before do
    Blog::Post.directory = Blog::Post::DEFAULT_DIRECTORY
    travel_to Time.zone.local(2026, 10, 30, 9)
  end

  it "is live on its date and listed on /blog" do
    get "/blog"

    expect(response).to have_http_status(:ok)
    expect(page.css("main .post-card h2 a").map { |link| [ link["href"], link.text.squish ] })
      .to include([ "/blog/podcorn-alternative", title ])
  end

  it "renders its title, meta tags, links and the non-affiliation line" do
    get "/blog/podcorn-alternative", params: { utm_source: "reddit" }

    expect(response).to have_http_status(:ok)
    expect(page.at_css("title").text).to eq("#{title} | Midrolo")
    expect(page.at_css("main article h1").text.squish).to eq(title)
    description = Blog::Post.find!("podcorn-alternative").description
    expect(meta("name", "description")).to eq([ description ])
    expect(description.length).to be_between(150, 160)
    expect_share_tags(page, url: url, image: %r{\Ahttp://www\.example\.com/blog/podcorn-alternative/og\.png\?v=\h{12}\z})
    expect(meta("property", "og:type")).to eq([ "article" ])
    expect(meta("property", "article:published_time")).to eq([ "2026-10-30T00:00:00Z" ])

    prose = page.at_css("main .post-prose")
    expect(prose.text.squish).to include("Midrolo is an independent tool. We are not affiliated with Audacy, Creator Lab or Podcorn.")
    expect(prose.css("a").map { |link| link["href"] }).to include("/podcasts", "/start", "/pricing", "/samples")
    expect(page.at_css("main").text).not_to match(/[–—]/)
  end
end
