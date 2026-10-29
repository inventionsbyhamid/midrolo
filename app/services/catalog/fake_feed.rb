module Catalog
  # The RSS for a demo directory feed (fake://fake-1, Podcasts::Directories::Fake): the same made-up show and episodes
  # the demo directory describes, as XML, so development and specs run the real parser and ingest offline.
  module FakeFeed
    module_function

    # The feed's XML, or nil for an id the demo directory doesn't know.
    def xml(directory_id)
      feed = Podcasts::Directories::Fake.feed_for(directory_id.to_s)
      show = Podcasts::Directories::Fake::CATALOG.find { |entry| entry[:directory_id] == directory_id.to_s }
      return nil unless feed && show

      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.rss(version: "2.0", "xmlns:itunes" => "http://www.itunes.com/dtds/podcast-1.0.dtd",
                "xmlns:podcast" => "https://podcastindex.org/namespace/1.0") do
          xml.channel { channel(xml, feed, show) }
        end
      end.to_xml
    end

    def channel(xml, feed, show)
      slug = show[:title].parameterize
      xml.title feed.title
      xml.description feed.description
      xml.link "https://#{slug}.example.com"
      xml.language show[:language]
      xml["itunes"].author show[:author]
      xml["itunes"].owner do
        xml["itunes"].name feed.owner_name
        xml["itunes"].email feed.owner_email
      end
      show[:categories].each { |category| xml["itunes"].category(text: category) }
      xml["podcast"].person(show[:author], role: "host")
      feed.episodes.each do |episode|
        xml.item do
          xml.title episode.title
          xml.description episode.description
          xml.pubDate episode.published_at.rfc2822
          xml.guid(episode.guid, isPermaLink: "false")
          xml.enclosure(url: "https://media.example.com/#{slug}/#{episode.guid}.mp3", length: "1000", type: "audio/mpeg")
        end
      end
    end
  end
end
