require "rails_helper"

# A post's Markdown as HTML (R148): GitHub-flavored, with no raw HTML, no script links and no smart dashes.
RSpec.describe Blog::Markdown do
  def render(markdown) = described_class.render(markdown)

  def fragment(markdown) = Nokogiri::HTML5.fragment(render(markdown).html)

  it "leaves raw HTML and javascript: links out, so a post can't run a script" do
    result = render(<<~MD)
      Hello <script>alert(1)</script> <img src=x onerror="alert(1)">

      <iframe src="https://example.com"></iframe>

      [click](javascript:alert(1)) and [ok](https://example.com)
    MD

    doc = Nokogiri::HTML5.fragment(result.html)
    expect(doc.css("script, iframe, img, [onerror]")).to be_empty
    expect(doc.css("a").map { |link| link["href"] }).to eq([ "", "https://example.com" ])
    expect(result.html).not_to include("<script", "javascript:", "<!--")
    expect(result.html).to be_html_safe
  end

  it "keeps -- and --- as typed, never turning them into dashes, and keeps a wrapped line in one paragraph" do
    html = render("Pitch -- then wait --- a week.\nSame paragraph.").html

    expect(html).not_to match(/[–—]/)
    expect(html).to include("Pitch -- then wait --- a week.")
    expect(html).not_to include("<br")
  end

  it "draws code blocks without inline styles, which the CSP would block" do
    html = render("```ruby\nputs 1\n```\n").html

    expect(html).to include("<pre", "puts 1")
    expect(html).not_to include("style=")
  end

  it "makes an h1 an h2 (the page's h1 is the title) and gives each h2 and h3 a unique id and a # link" do
    result = render("# Intro\n\n## Pricing\n\n### Pricing\n\n## 2026 rates\n\n#### Small print\n")
    doc = Nokogiri::HTML5.fragment(result.html)

    expect(doc.css("h1")).to be_empty
    expect(doc.css("h2, h3").map { |heading| heading["id"] }).to eq(%w[intro pricing pricing-2 2026-rates])
    expect(doc.at_css("h4")["id"]).to be_nil
    anchor = doc.at_css("h3 a.heading-anchor")
    expect(anchor.to_h).to include("href" => "#pricing-2", "aria-hidden" => "true", "tabindex" => "-1")
    expect(result.headings.map(&:to_h)).to eq([
      { level: 2, id: "intro", text: "Intro" }, { level: 2, id: "pricing", text: "Pricing" },
      { level: 3, id: "pricing-2", text: "Pricing" }, { level: 2, id: "2026-rates", text: "2026 rates" }
    ])
  end

  it "gives the feed the same HTML without the # links" do
    result = render("## Pricing\n\nText.\n")

    expect(result.feed_html).to include(%(<h2 id="pricing">Pricing</h2>), "<p>Text.</p>")
    expect(result.feed_html).not_to include("heading-anchor")
  end

  it "loads images lazily and puts each table in a box that scrolls on its own" do
    doc = fragment("![A chart](/chart.png)\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n")

    expect(doc.at_css("img").to_h).to include("src" => "/chart.png", "alt" => "A chart", "loading" => "lazy")
    box = doc.at_css("div.post-table")
    expect(box.to_h).to include("role" => "region", "aria-label" => "Table", "tabindex" => "0")
    expect(box.at_css("table")).to be_present
  end

  it "counts the words a reader reads" do
    expect(render("## Two words\n\nAnd three more.").words).to eq(5)
  end
end
