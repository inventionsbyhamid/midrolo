# One try at proving a user owns a show, which a public media kit requires: a 6-digit code emailed to the feed's
# owner address (kind "email"), or a token the owner puts in the feed (kind "feed_token"). Success marks only this
# user's Show row verified; other users' copies of the same feed are untouched.
#
# Codes are never stored: code_digest is an HMAC-SHA256 keyed from secret_key_base, and the code itself is made in
# VerificationMailer#code while the email renders, so it never sits in the job queue or a log line.
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

  # The method can't be used for this show (no owner email in the feed, or no feed URL).
  class Unavailable < StandardError; end

  # Too soon after the last code (reason :resend) or too many today (reason :daily). retry_in is in seconds.
  class Throttled < StandardError
    attr_reader :reason, :retry_in

    def initialize(reason, retry_in)
      @reason = reason
      @retry_in = [ retry_in.to_f.ceil, 1 ].max
      super("Throttled (#{reason}); retry in #{@retry_in}s")
    end
  end

  belongs_to :show
  enum :kind, { email: "email", feed_token: "feed_token" }, validate: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :unexpired, -> { where(verified_at: nil).where("expires_at > ?", Time.current) }

  # Why the last check_code or check_feed_token! failed: :wrong_code, :locked, :expired, :not_found or :unreadable.
  attr_reader :failure

  def self.current_for(show) = show.verifications.newest_first.first

  # Queues a code to the feed's owner address. Retires any earlier code, so only the newest one works.
  def self.request_code!(show)
    raise Unavailable, "the feed lists no owner email" if show.owner_email.blank?

    verification = show.with_lock do
      throttle!(show)
      show.verifications.email.unexpired.update_all(expires_at: Time.current)
      create!(show: show, kind: "email", sent_to: show.owner_email, expires_at: CODE_TTL.from_now)
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

  # At least RESEND_AFTER between sends, and at most SENDS_PER_DAY in any 24 hours, per show.
  def self.throttle!(show)
    sent = show.verifications.email.where(created_at: 1.day.ago..)
    last = sent.maximum(:created_at)
    raise Throttled.new(:resend, last + RESEND_AFTER - Time.current) if last && last > RESEND_AFTER.ago
    raise Throttled.new(:daily, sent.minimum(:created_at) + 1.day - Time.current) if sent.count >= SENDS_PER_DAY
  end
  private_class_method :throttle!

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
    with_lock do
      next fail_with(:locked) if locked?
      next fail_with(:expired) unless email? && !verified? && !expired?

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
  # channel description or a podcast:txt tag.
  def check_feed_token!
    @failure = nil
    return fail_with(:expired) unless feed_token? && !verified? && !expired?

    feed = Podcasts::FeedReader.new.read(show.feed_url, max_episodes: 0, description_limit: TOKEN_SCAN_LIMIT, fresh: true)
    increment!(:attempts)
    return fail_with(:unreadable) if feed.warnings.any?
    return fail_with(:not_found) unless token_in?(feed)

    with_lock { verified? || mark_verified! } # a parallel check may have got there first
  end

  def token_line = "#{TOKEN_PREFIX}#{token}"
  def masked_sent_to = Shows::OwnerEmail.mask(sent_to)
  def verified? = verified_at.present?
  def expired? = expires_at <= Time.current
  def locked? = email? && attempts >= MAX_ATTEMPTS
  def attempts_left = [ MAX_ATTEMPTS - attempts, 0 ].max
  def pending? = !verified? && !expired? && !locked?

  private

  def mark_verified!
    update!(verified_at: Time.current)
    show.verify!
    true
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
