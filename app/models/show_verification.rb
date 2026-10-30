# One try at proving a user owns a show, which a public media kit requires: a 6-digit code emailed to the feed's
# owner address (kind "email"), or a token the owner puts in the feed (kind "feed_token"). Success makes this user's
# Show the podcast's owner show (Show#verify!); other users' workspaces for the same podcast stay unverified, and a
# podcast another account already owns can't be verified again (Show::AlreadyClaimed).
#
# sent_to is encrypted, deterministically, so the per-address caps can still query it.
#
# Codes are never stored: code_digest is an HMAC-SHA256 keyed from secret_key_base, and the code itself is made in
# VerificationMailer#code while the email renders, so it never sits in the job queue or a log line.
#
# Sends are capped twice: per show, and per recipient address across every show and account (R65), so neither many
# accounts adding one feed nor an attacker's feed naming someone else's address can flood an inbox.
#
# Hosts update their feeds late (a CDN can serve the old copy for a while), so a feed check that doesn't find the token
# starts a watch (#watch!): Verifications::WatchFeedJob reads the feed again until watch_until and emails the owner how
# it ended.
class ShowVerification < ApplicationRecord
  CODE_TTL = 30.minutes
  TOKEN_TTL = 7.days
  MAX_ATTEMPTS = 5
  RESEND_AFTER = 60.seconds
  SENDS_PER_DAY = 5
  TOKEN_PREFIX = "midrolo-verify=".freeze
  # How much of the channel description the token check reads (FeedReader truncates descriptions).
  TOKEN_SCAN_LIMIT = 20_000
  DIGEST_SALT = "show_verification/code".freeze
  # The first key of the two-key advisory lock taken while checking a recipient address's allowance.
  ADDRESS_LOCK_NAMESPACE = 15_015
  # How long a watch reads the feed after the latest failed check, and the failures that start one.
  WATCH_WINDOW = 30.minutes
  WATCHED_FAILURES = %i[not_found unreadable].freeze

  # Shown on the verification page and in the flash after a failed check.
  LOCKED_MESSAGE = "Too many tries. Request a new code to try again.".freeze
  EXPIRED_CODE_MESSAGE = "That code has expired. Request a new one.".freeze

  # The method can't be used for this show (no owner email in the feed, or no feed URL).
  class Unavailable < StandardError; end

  # Too soon after the last code (reason :resend) or too many today (reason :daily), counted for this show
  # (scope :show) or for the recipient address across all shows (scope :address). retry_in is in seconds.
  class Throttled < StandardError
    attr_reader :reason, :scope, :retry_in

    def initialize(reason, retry_in, scope: :show)
      @reason = reason
      @scope = scope
      @retry_in = [ retry_in.to_f.ceil, 1 ].max
      super("Throttled (#{reason}, per #{scope}); retry in #{@retry_in}s")
    end
  end

  belongs_to :show
  encrypts :sent_to, deterministic: true
  enum :kind, { email: "email", feed_token: "feed_token" }, validate: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :unexpired, -> { where(verified_at: nil).where("expires_at > ?", Time.current) }

  # Why the last check_code or check_feed_token! failed: :wrong_code, :locked, :expired, :feed_moved, :not_found or
  # :unreadable.
  attr_reader :failure

  def self.current_for(show) = show.verifications.newest_first.first

  # Queues a code to the feed's owner address. Retires any earlier code, so only the newest one works. The address
  # allowance is checked under an advisory lock on the address, so parallel requests from different accounts can't
  # both slip under the cap; the show's row lock does the same for its own allowance.
  #
  # The address is read under the podcast's row lock, the lock a feed move holds while it records itself and expires
  # pending codes (final review N1): a code goes either to the address of the feed it was asked for, and is retired if
  # that feed moves, or to the new feed's address.
  def self.request_code!(show)
    verification = transaction do
      address = normalize_address(Podcast.lock.find(show.podcast_id).owner_email)
      raise Unavailable, "the feed lists no owner email" if address.blank?

      lock_address!(address)
      show.lock!
      throttle!(show.verifications.email, scope: :show)
      throttle!(email.where(sent_to: address), scope: :address)
      show.verifications.email.unexpired.update_all(expires_at: Time.current)
      create!(show: show, kind: "email", sent_to: address, expires_at: CODE_TTL.from_now)
    end
    VerificationMailer.with(verification: verification).code.deliver_later
    verification
  end

  # The pending token for this show, or a new one. Reused so a token already pasted into the feed stays valid.
  def self.start_feed_token!(show)
    raise Unavailable, "the show has no feed URL" if show.feed_url.blank?

    show.with_lock do
      show.verifications.feed_token.unexpired.newest_first.first ||
        create!(show: show, kind: "feed_token", token: SecureRandom.base36(16), expires_at: TOKEN_TTL.from_now)
    end
  end

  def self.digest(id, code)
    key = Rails.application.key_generator.generate_key(DIGEST_SALT, 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{id}:#{code}")
  end

  def self.normalize_address(email) = email.to_s.strip.downcase.presence

  # The Turbo stream an open verification page listens on, named by the show's public id (R147), as
  # Conversations::Broadcast names its streams.
  def self.stream_name(show) = "verification:#{show.public_id}"

  # At least RESEND_AFTER between sends, and at most SENDS_PER_DAY in any 24 hours, among the given sends.
  def self.throttle!(sends, scope:)
    sent = sends.where(created_at: 1.day.ago..)
    last = sent.maximum(:created_at)
    raise Throttled.new(:resend, last + RESEND_AFTER - Time.current, scope: scope) if last && last > RESEND_AFTER.ago
    raise Throttled.new(:daily, sent.minimum(:created_at) + 1.day - Time.current, scope: scope) if sent.count >= SENDS_PER_DAY
  end

  # Held until the transaction ends.
  def self.lock_address!(address)
    connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", ADDRESS_LOCK_NAMESPACE, address ]))
  end
  private_class_method :throttle!, :lock_address!

  # Makes this request's code, stores its digest and returns it for the email. nil once the request was retired,
  # used or locked, so a late mail job can't revive it.
  def issue_code!
    return nil unless email? && !verified? && !expired? && !locked?

    code = format("%06d", SecureRandom.random_number(1_000_000))
    update!(code_digest: self.class.digest(id, code), attempts: 0, expires_at: CODE_TTL.from_now)
    code
  end

  # True when the code matches, which verifies the show. Every check counts toward MAX_ATTEMPTS, under a row lock
  # so parallel guesses can't exceed it. Spaces and dashes in the typed code are ignored.
  def check_code(code)
    @failure = nil
    with_podcast_lock do
      next fail_with(:locked) if locked?
      next fail_with(expired_reason) unless email? && !verified? && !expired?

      self.attempts += 1
      if code_digest.present? && ActiveSupport::SecurityUtils.secure_compare(code_digest, self.class.digest(id, code.to_s.gsub(/[\s-]/, "")))
        mark_verified!
      else
        save!
        fail_with(locked? ? :locked : :wrong_code)
      end
    end
  end

  # True when the feed, read fresh through FeedReader (and so the SSRF guard), carries midrolo-verify=TOKEN in its
  # channel description or a podcast:txt tag. The claim is bound to the feed URL read, so a move that lands while the
  # feed is read can't carry it onto the new feed (final review N1).
  def check_feed_token!
    @failure = nil
    return fail_with(expired_reason) unless feed_token? && !verified? && !expired?

    feed_url = show.feed_url
    feed = Podcasts::FeedReader.new.read(feed_url, max_episodes: 0, description_limit: TOKEN_SCAN_LIMIT, fresh: true)
    increment!(:attempts)
    return fail_with(:unreadable) if feed.warnings.any?
    return fail_with(:not_found) unless token_in?(feed)

    with_podcast_lock do
      next true if verified? # a parallel check got there first
      next fail_with(expired_reason) if expired?

      mark_verified!(feed_url: feed_url)
    end
  end

  # After a feed check that didn't find the token (or couldn't read the feed), keeps checking until WATCH_WINDOW from
  # now. A watch that is running is only extended: the row lock lets one of two parallel presses start the chain.
  # True when this call started one.
  def watch!
    return false unless feed_token? && failure.in?(WATCHED_FAILURES)

    started = with_lock do
      running = watching?
      update!(watch_until: WATCH_WINDOW.from_now)
      !running
    end
    Verifications::WatchFeedJob.check_later(id, 1) if started
    started
  end

  # Only this column: a claim refused mid-check (Show::AlreadyClaimed) leaves its rolled-back verified_at in memory.
  def stop_watching! = update_columns(watch_until: nil)

  def watching? = watch_until.present? && watch_until > Time.current
  def token_line = "#{TOKEN_PREFIX}#{token}"
  def masked_sent_to = Shows::OwnerEmail.mask(sent_to)
  def verified? = verified_at.present?
  def expired? = expires_at <= Time.current
  def locked? = email? && attempts >= MAX_ATTEMPTS
  def attempts_left = [ MAX_ATTEMPTS - attempts, 0 ].max
  def pending? = !verified? && !expired? && !locked?

  private

  def mark_verified!(feed_url: nil)
    update!(verified_at: Time.current)
    show.verify!(via: kind, since: created_at, feed_url: feed_url)
    true
  end

  # The podcast's row, then this one: the order a feed move takes them in (Catalog::FeedMove), so a check and a move
  # never deadlock, and the check sees a move that committed before it.
  def with_podcast_lock(&)
    transaction do
      Podcast.lock.find(show.podcast_id)
      lock!
      yield
    end
  end

  # An expired code or token says the feed moved when that is why: a move retires every pending one (Catalog::FeedMove).
  def expired_reason
    show.feed_moved_since?(created_at) ? :feed_moved : :expired
  end

  def token_in?(feed)
    pattern = /#{Regexp.escape(token_line)}(?![[:alnum:]])/
    [ feed.description, *feed.txt ].any? { |text| text.to_s.match?(pattern) }
  end

  def fail_with(reason)
    @failure = reason
    false
  end
end
