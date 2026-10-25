require "rails_helper"

RSpec.describe Copy do
  describe ".and_list" do
    it "joins plain words as A, B and C, with no comma before the and, and leaves them unescaped" do
      expect(described_class.and_list(%w[A B C])).to eq("A, B and C")
      expect(described_class.and_list(%w[A B])).to eq("A and B")
      expect(described_class.and_list([ "Code & Coffee" ])).to eq("Code & Coffee")
      expect(described_class.and_list([])).to eq("")
      expect(described_class.and_list(%w[A B C])).not_to be_html_safe
    end

    it "keeps html-safe parts (links) safe and escapes plain ones beside them" do
      links = [ ActionController::Base.helpers.link_to("A&B", "#a"), "<i>C</i>" ]
      joined = described_class.and_list(links)
      expect(joined).to be_html_safe
      expect(joined).to eq(%(<a href="#a">A&amp;B</a> and &lt;i&gt;C&lt;/i&gt;))
    end
  end
end
