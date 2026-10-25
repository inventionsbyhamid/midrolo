# The search and share tags every public page carries exactly once (SocialMetaHelper#social_meta), and what private
# pages carry instead (noindex, no share image).
module ShareTags
  REQUIRED = %w[description og:site_name og:type og:url og:title og:description og:image og:image:width og:image:height
                og:image:alt og:locale twitter:card twitter:title twitter:description twitter:image
                twitter:image:alt].freeze

  # { "og:title" => [content, ...] } for every <meta> with a name or property in the document.
  def share_tags(doc)
    doc.css("meta[property], meta[name]").each_with_object(Hash.new { |tags, key| tags[key] = [] }) do |meta, tags|
      tags[meta["property"] || meta["name"]] << meta["content"]
    end
  end

  def expect_share_tags(doc, url:, image:)
    tags = share_tags(doc)
    REQUIRED.each { |key| expect(tags[key].size).to eq(1), "expected one #{key}, got #{tags[key].inspect}" }
    expect(doc.css("link[rel='canonical']").map { |link| link["href"] }).to eq([ url ])
    expect(tags["og:url"]).to eq([ url ])
    expect(tags["og:image"].first).to match(image)
    expect(tags["twitter:image"]).to eq(tags["og:image"])
    expect(tags["og:image:width"] + tags["og:image:height"]).to eq(%w[1200 630])
    expect(tags["twitter:card"]).to eq([ "summary_large_image" ])
    expect(tags["og:description"]).to eq(tags["description"])
    expect(tags["robots"]).to be_empty
  end

  def expect_private_tags(doc)
    tags = share_tags(doc)
    expect(tags["robots"]).to eq([ "noindex, nofollow" ])
    expect(tags.keys.grep(/\A(og|twitter):/)).to be_empty
  end
end

RSpec.configure { |config| config.include ShareTags, type: :request }
