module Verifications
  # Reads a show's feed again after a failed "Check my feed" (ShowVerification#watch!), since hosts and their CDNs can
  # take minutes to serve the new description. The checks run 15 s, 1 min, 3 min and 5 min after the press, then every
  # 5 minutes until watch_until (a later failed press moves it); the feed is read through check_feed_token!, so the
  # same fresh read and SSRF guard as the button. Each check enqueues the next, and only the verification id and the
  # check's number travel in the job.
  #
  #   found         the show is verified: the owner gets VerificationMailer#verified and an open verification page
  #                 refreshes (it lands on the verified page).
  #   window over   one VerificationMailer#not_found. The watch ends either way, so a watch sends one email at most.
  #   no longer pending, the show verified another way, the feed moved, or another account claimed the podcast: the
  #                 watch ends quietly.
  class WatchFeedJob < ApplicationJob
    queue_as :default
    # One check per verification at a time; a chain never overlaps itself.
    limits_concurrency to: 1, key: ->(verification_id, *) { verification_id }, duration: 2.minutes
    # The verification went with its show or its user.
    discard_on ActiveRecord::RecordNotFound

    # The wait before each check, after the one before it (the first after the failed press), then EVERY.
    WAITS = [ 15.seconds, 45.seconds, 2.minutes, 2.minutes ].freeze
    EVERY = 5.minutes

    # Check number check_number, after its wait, but no later than latest (the end of the watch).
    def self.check_later(verification_id, check_number, latest: nil)
      at = WAITS.fetch(check_number - 1, EVERY).from_now
      at = [ at, latest ].min if latest
      set(wait_until: at).perform_later(verification_id, check_number)
    end

    def perform(verification_id, check_number)
      verification = ShowVerification.find(verification_id)
      return if verification.watch_until.nil?
      return verification.stop_watching! unless watchable?(verification)

      if verification.check_feed_token!
        verified(verification)
      elsif verification.failure.in?(%i[expired feed_moved])
        verification.stop_watching!
      elsif over?(verification)
        VerificationMailer.with(verification: verification).not_found.deliver_later
      elsif verification.watch_until # nil when a stray copy ended the watch meanwhile
        self.class.check_later(verification.id, check_number + 1, latest: verification.watch_until)
      end
    rescue Show::AlreadyClaimed, Show::FeedMoved
      verification.stop_watching!
    end

    private

    # A feed token still waiting for its feed, on a show nobody verified another way (an emailed code, an instant claim).
    def watchable?(verification)
      verification.feed_token? && verification.pending? && !verification.show.verified?
    end

    def verified(verification)
      verification.stop_watching!
      show = verification.show.reload
      show.sync_listing!
      VerificationMailer.with(verification: verification).verified.deliver_later
      Turbo::StreamsChannel.broadcast_refresh_to(ShowVerification.stream_name(show))
    end

    # Ends the watch when its time is up, under the row lock a press takes to extend it: a press either lands first
    # (and this check schedules the next one) or finds the watch over (and starts a new one).
    def over?(verification)
      verification.with_lock do
        next false if verification.watch_until.nil? || verification.watch_until > Time.current

        verification.update!(watch_until: nil)
        true
      end
    end
  end
end
