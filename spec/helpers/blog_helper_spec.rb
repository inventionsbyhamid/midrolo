require "rails_helper"

RSpec.describe BlogHelper do
  describe "#json_ld" do
    it "writes JSON that parses back, with the page's nonce, and a title that can't close the script tag" do
      allow(helper).to receive(:content_security_policy_nonce).and_return("abc123")
      hostile = %(</script><script>alert(1)</script> & more)
      html = helper.json_ld("@type" => "BlogPosting", "headline" => hostile)
      scripts = Nokogiri::HTML("<head>#{html}</head>").css("script")

      expect(scripts.size).to eq(1)
      expect(scripts.first.to_h).to include("type" => "application/ld+json", "nonce" => "abc123")
      expect(html).not_to include("</script><script>")
      expect(JSON.parse(scripts.first.text)).to eq("@type" => "BlogPosting", "headline" => hostile)
    end
  end

  describe "#blog_listed?" do
    it "reports a post that doesn't parse and leaves the blog unlinked, so other pages still render" do
      allow(Blog::Post).to receive(:published).and_raise(Blog::Post::Invalid, "broken.md: no front matter")
      allow(Rails.error).to receive(:report)

      expect(helper.blog_listed?).to be(false)
      expect(Rails.error).to have_received(:report).with(an_instance_of(Blog::Post::Invalid), handled: true)
    end
  end

  describe "#blog_date" do
    it "writes the long date in a <time> with the ISO date, with no padding before a single digit day" do
      expect(helper.blog_date(Date.new(2026, 11, 2))).to eq(%(<time datetime="2026-11-02">November 2, 2026</time>))
    end
  end
end
