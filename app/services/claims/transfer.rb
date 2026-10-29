module Claims
  # An admin moves a podcast's ownership to another account (the "managed by someone else" case, settled by hand):
  # the current owner show becomes a draft workspace again (its kit and reports stay with it), the new owner's
  # workspace is reused or made, and it is verified via "admin". The listing columns follow the new owner's kit.
  module Transfer
    module_function

    # Returns the new owner show.
    def call(podcast:, to:)
      show = nil
      Podcast.transaction do
        podcast.lock!
        podcast.shows.where.not(verified_at: nil).where.not(user_id: to.id).find_each { |old| old.update!(verified_at: nil) }
        show = to.shows.find_or_create_by!(podcast: podcast)
        show.verify!(via: "admin")
      end
      show.sync_listing!
      show
    end
  end
end
