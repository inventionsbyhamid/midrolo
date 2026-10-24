module Podcasts
  Feed = Data.define(:title, :description, :owner_email, :owner_name, :episodes, :cadence_days, :warnings) do
    # A feed that could not be read: no episodes, one warning code.
    def self.unreadable(warning = "feed_unreadable")
      new(title: nil, description: nil, owner_email: nil, owner_name: nil, episodes: [], cadence_days: nil, warnings: [ warning ])
    end
  end
end
