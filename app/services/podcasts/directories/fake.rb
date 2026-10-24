module Podcasts
  module Directories
    # Offline adapter with a made-up catalog. Selected automatically when Podcast Index keys are missing
    # outside production. Everything here is deterministic.
    class Fake
      FAKE_SPONSORS = [ "Notion", "Squarespace", "Shopify", "HelloFresh", "Calm", "Mercury", "Ramp", "Linear", "AG1", "Rocket Money" ].freeze

      FEED_ANCHOR = Time.utc(2026, 10, 19, 9, 0, 0) # newest episode of every fake feed
      FEED_PREFIX = "fake://".freeze

      CATALOG = [
        { directory_id: "fake-1", title: "The Founder's Ledger", author: "Maya Brandt", categories: [ "Business", "Finance" ],
          description: "Plain-English money lessons from first-time founders." },
        { directory_id: "fake-2", title: "Index Fund Mornings", author: "Theo Park", categories: [ "Business", "Finance" ],
          description: "Ten minutes a day on investing, savings and staying calm about markets." },
        { directory_id: "fake-3", title: "Code & Coffee Weekly", author: "Priya Nair", categories: [ "Technology" ],
          description: "Developers talk shipping, tooling and the odd production fire." },
        { directory_id: "fake-4", title: "Side Hustle Spreadsheet", author: "Dana Ortiz", categories: [ "Business", "Finance" ],
          description: "How ordinary people turn weekend projects into income." },
        { directory_id: "fake-5", title: "Bootstrapped Brains", author: "Lena Fischer", categories: [ "Business", "Finance" ],
          description: "Profitable small companies and the owners who run them." },
        { directory_id: "fake-6", title: "Laugh Track Lab", author: "Sam Okafor", categories: [ "Comedy" ],
          description: "Two comedians workshop bits live and argue about the results." },
        { directory_id: "fake-7", title: "Whole Body Reset", author: "Dr. Elena Cruz", categories: [ "Health" ],
          description: "Sleep, movement and nutrition without the hype." },
        { directory_id: "fake-8", title: "Cold Case Cafe", author: "Rhea Dalton", categories: [ "True Crime" ],
          description: "Unsolved mysteries retold over a pot of coffee." },
        { directory_id: "fake-9", title: "Study Hall Stories", author: "Marcus Webb", categories: [ "Education" ],
          description: "Teachers and researchers on how people really learn." },
        { directory_id: "fake-10", title: "Pickup Game Podcast", author: "Jonah Reyes", categories: [ "Sports" ],
          description: "Amateur leagues, weekend athletes and the stories behind the scoreboard." },
        { directory_id: "fake-11", title: "Dollar Dispatch", author: "Iris Koh", categories: [ "Business", "Finance" ],
          description: "A weekly briefing on prices, payments and personal budgets." },
        { directory_id: "fake-12", title: "Shipping Soon", author: "Noel Archer", categories: [ "Technology", "Business" ],
          description: "Product makers on launches, delays and lessons learned." },
        # The other podcasts Taste::Providers::Fake knows, so the proven-sponsor scan can read every one.
        { directory_id: "fake-13", title: "Main Street Stories", author: "Gloria Vance", categories: [ "Education" ],
          description: "Small-town shop owners and the neighbors who keep them going." },
        { directory_id: "fake-14", title: "Deep Work Daily", author: "Arjun Mehta", categories: [ "Business" ],
          description: "Focus, calendars and the craft of doing hard things well." },
        { directory_id: "fake-15", title: "The Prompt Engineers", author: "Wen Li", categories: [ "Technology" ],
          description: "Builders compare notes on shipping with language models." },
        { directory_id: "fake-16", title: "Midnight Mysteries", author: "Odette Crane", categories: [ "True Crime" ],
          description: "Late-night retellings of strange disappearances." }
      ].map { |s| s.merge(language: "en").freeze }.freeze

      STEMS = {
        "Business" => [ "Pricing your first product", "Hiring when you cannot afford to", "The customer who changed our plan",
                        "Cash flow surprises", "Saying no to a big client", "Our worst quarter", "Building a simple sales process",
                        "What we would do differently" ],
        "Technology" => [ "Debugging a flaky deploy", "Choosing boring technology", "Shipping without a design team",
                          "The case for small teams", "Learning in public", "Taming a legacy codebase", "Tools we actually use",
                          "When to rewrite" ],
        "Comedy" => [ "Bombing on purpose", "The worst opening line", "Crowd work gone wrong", "Writing a tight five",
                      "Stories from the road", "Hecklers and how to love them", "Improv rules we broke", "A very awkward wedding gig" ],
        "Health" => [ "Why sleep beats supplements", "Walking as medicine", "Reading nutrition labels", "Stress and the gut",
                      "Strength training after forty", "Hydration myths", "Building a morning routine", "Recovery days" ],
        "True Crime" => [ "The vanishing at Miller's Pond", "A forged will", "The wrong suspect", "Letters from a cold case",
                          "The lighthouse mystery", "A town with a secret", "The missing ledger", "Witness who remembered too late" ],
        "Education" => [ "How memory really works", "The case against cramming", "Teaching with stories", "Learning a language late",
                         "What makes a great mentor", "Curiosity in the classroom", "Rethinking homework", "Study habits that last" ],
        "Sports" => [ "A league run on group chats", "The comeback season", "Coaching your own kid", "Training for a first marathon",
                      "Pickup rules everyone knows", "The underdog final", "Injuries and patience", "Why we keep score" ]
      }.freeze

      GUESTS = [ "Alex Rivera", "Jordan Lee", "Casey Morgan", "Riley Chen", "Taylor Brooks", "Morgan Ellis", "Jamie Patel",
                 "Quinn Foster", "Avery Stone", "Rowan Hayes" ].freeze

      SPONSOR_LINES = [ "This episode is sponsored by %s.", "Thanks to our sponsor %s.", "Today's show is brought to you by %s." ].freeze

      class << self
        # Deterministic fake iTunes id: fake-7 => "1000000007".
        def itunes_id_for(directory_id)
          (1_000_000_000 + directory_id.delete_prefix("fake-").to_i).to_s
        end

        # Deterministic feed for a catalog id, or nil when the id is unknown.
        def feed_for(directory_id)
          show = CATALOG.find { |s| s[:directory_id] == directory_id }
          return nil unless show

          n = directory_id.delete_prefix("fake-").to_i
          count = 15 + (n % 6)
          slug = show[:title].parameterize
          episodes = Array.new(count) { |i| episode(show, n, i, count) }
          Feed.new(title: show[:title], description: show[:description], owner_email: "host@#{slug}.example",
                   owner_name: show[:author], episodes: episodes, cadence_days: 7, warnings: [])
        end

        private

        def episode(show, n, i, count)
          category = show[:categories].first
          stems = STEMS.fetch(category)
          stem = stems[(i + n) % stems.size]
          guest = GUESTS[(i * 3 + n) % GUESTS.size]
          description = "#{show[:author]} sits down with #{guest} to talk about #{stem.downcase}. " \
                        "Plus listener questions and what to try this week."
          if (i + n) % 3 == 0
            sponsor = FAKE_SPONSORS[(i + n * 3) % FAKE_SPONSORS.size]
            description += " #{SPONSOR_LINES[i % SPONSOR_LINES.size] % sponsor}"
          end
          EpisodeInfo.new(title: "#{count - i}. #{stem} with #{guest}", description: description,
                          published_at: FEED_ANCHOR - i.weeks, guid: "#{show[:directory_id]}-ep-#{count - i}")
        end
      end

      def search(term, limit: 10)
        words = term.to_s.downcase.split
        return [] if words.empty?

        CATALOG.select { |s| words.all? { |w| haystack(s).include?(w) } }.first(limit).map { |s| to_show(s) }
      end

      def find(directory_id)
        show = CATALOG.find { |s| s[:directory_id] == directory_id.to_s }
        show && to_show(show)
      end

      def find_by_itunes_id(itunes_id)
        show = CATALOG.find { |s| self.class.itunes_id_for(s[:directory_id]) == itunes_id.to_s }
        show && to_show(show)
      end

      def find_by_feed_url(url)
        id = url.to_s.delete_prefix(FEED_PREFIX) if url.to_s.start_with?(FEED_PREFIX)
        id && find(id)
      end

      private

      def haystack(show)
        ([ show[:title], show[:author] ] + show[:categories]).join(" ").downcase
      end

      def to_show(show)
        ShowInfo.new(directory_id: show[:directory_id], title: show[:title], author: show[:author],
                     description: show[:description], artwork_url: nil, feed_url: "#{FEED_PREFIX}#{show[:directory_id]}",
                     categories: show[:categories], episode_count: self.class.feed_for(show[:directory_id]).episodes.size,
                     itunes_id: self.class.itunes_id_for(show[:directory_id]), language: show[:language])
      end
    end
  end
end
