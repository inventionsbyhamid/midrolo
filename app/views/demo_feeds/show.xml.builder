# The demo show's feed (DemoFeedsController): RSS 2.0 with the iTunes and Podcasting 2.0 namespaces. No audio and no
# owner email: it's a fictional show, already claimed.
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.rss version: "2.0", "xmlns:itunes" => "http://www.itunes.com/dtds/podcast-1.0.dtd",
                        "xmlns:podcast" => "https://podcastindex.org/namespace/1.0" do
  xml.channel do
    xml.title @podcast.title
    xml.link root_url
    xml.description @podcast.description
    xml.language @podcast.language
    xml.tag! "itunes:author", @podcast.author
    xml.tag! "itunes:explicit", "false"
    xml.tag! "itunes:type", "episodic"
    # The show's cover (app/assets/images/demo/artwork.png), read by ingest like any feed's artwork.
    xml.tag! "itunes:image", href: image_url("demo/artwork.png")
    xml.image do
      xml.url image_url("demo/artwork.png")
      xml.title @podcast.title
      xml.link root_url
    end
    @podcast.categories.each { |category| xml.tag! "itunes:category", text: category }
    xml.tag! "podcast:guid", @podcast.podcast_guid
    xml.tag! "podcast:locked", "yes"
    @episodes.each do |episode|
      xml.item do
        xml.title episode.title
        xml.description episode.description
        xml.guid episode.guid, isPermaLink: "false"
        xml.pubDate episode.published_at&.rfc2822
      end
    end
  end
end
