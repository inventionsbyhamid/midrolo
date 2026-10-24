module Podcasts
  # txt holds the channel's podcast:txt values and website its <link>; both are optional, so older callers that
  # build a Feed without them still work.
  Feed = Data.define(:title, :description, :owner_email, :owner_name, :episodes, :cadence_days, :warnings, :txt, :website) do
    def initialize(txt: [], website: nil, **fields) = super(txt: txt, website: website, **fields)

    # A feed that could not be read: no episodes, one warning code.
    def self.unreadable(warning = "feed_unreadable")
      new(title: nil, description: nil, owner_email: nil, owner_name: nil, episodes: [], cadence_days: nil, warnings: [ warning ])
    end
  end
end
