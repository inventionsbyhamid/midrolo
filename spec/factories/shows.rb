FactoryBot.define do
  factory :show do
    user

    # A show reads what it is from its podcast, so these build (or reuse, by feed URL) the podcast: create(:show,
    # title: "X", feed_url: "...", owner_email: "...") reads as before. directory_id "fake-1" means the demo
    # directory's feed (fake://fake-1); a numeric one is a Podcast Index id. A feed URL that already has a podcast
    # gives that podcast the other values passed, so two users' shows of one feed share it.
    transient do
      title { nil }
      author { nil }
      description { nil }
      feed_url { nil }
      directory_id { nil }
      itunes_id { nil }
      artwork_url { nil }
      categories { nil }
      episode_count { nil }
      language { nil }
      cadence_days { nil }
      owner_email { nil }
      slug { nil }
      qloo_entity_id { nil }
      website { nil }
    end

    podcast do
      attributes = { title: title, author: author, description: description, artwork_url: artwork_url,
                     categories: categories, episode_count: episode_count, language: language,
                     cadence_days: cadence_days, owner_email: owner_email, slug: slug, qloo_entity_id: qloo_entity_id,
                     website: website }.compact
      fake_feed = "#{Podcasts::Directories::Fake::FEED_PREFIX}#{directory_id}" if directory_id.to_s.start_with?("fake-")
      attributes[:feed_url] = feed_url || fake_feed if feed_url || fake_feed
      attributes[:podcast_index_id] = Integer(directory_id.to_s, 10) if directory_id.to_s.match?(/\A\d+\z/)
      attributes[:apple_id] = Integer(itunes_id.to_s, 10) if itunes_id.to_s.match?(/\A\d+\z/)

      existing = attributes[:feed_url] && Podcast.find_by(feed_url: attributes[:feed_url])
      if existing
        existing.update!(attributes.except(:feed_url))
        existing
      else
        association(:podcast, **attributes)
      end
    end
  end
end
