require "rails_helper"

RSpec.describe Shows::OwnerEmail do
  def channel(inner)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
           xmlns:podcast="https://podcastindex.org/namespace/1.0">
        <channel><title>Owner Show</title>#{inner}</channel>
      </rss>
    XML
  end

  describe ".for" do
    it "prefers itunes:owner over podcast:email and managingEditor" do
      xml = channel(<<~XML)
        <managingEditor>editor@example.com (The Editor)</managingEditor>
        <podcast:email>podcast@example.com</podcast:email>
        <itunes:owner><itunes:name>Jane</itunes:name><itunes:email>jane@example.com</itunes:email></itunes:owner>
      XML

      expect(described_class.for(xml)).to eq("jane@example.com")
    end

    it "falls back to podcast:email, then managingEditor" do
      expect(described_class.for(channel("<podcast:email>podcast@example.com</podcast:email>" \
                                         "<managingEditor>editor@example.com</managingEditor>"))).to eq("podcast@example.com")
      expect(described_class.for(channel("<managingEditor>editor@example.com (The Editor)</managingEditor>"))).to eq("editor@example.com")
    end

    it "takes an already parsed document with namespaces removed" do
      doc = Nokogiri::XML(channel("<itunes:owner><itunes:email>jane@example.com</itunes:email></itunes:owner>"))
      doc.remove_namespaces!

      expect(described_class.for(doc)).to eq("jane@example.com")
    end

    it "returns nil when the feed lists no address" do
      expect(described_class.for(channel("<itunes:owner><itunes:name>Jane</itunes:name></itunes:owner>"))).to be_nil
      expect(described_class.for("not xml")).to be_nil
    end
  end

  describe ".mask" do
    it "keeps the first letter and the domain" do
      expect(described_class.mask("jane@example.com")).to eq("j***@example.com")
      expect(described_class.mask("j@example.com")).to eq("j***@example.com")
    end

    it "returns nil for a blank address" do
      expect(described_class.mask(nil)).to be_nil
      expect(described_class.mask("")).to be_nil
    end
  end
end
