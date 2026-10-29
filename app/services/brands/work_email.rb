module Brands
  # Proving a brand member works at the brand (build spec L6): a 6-digit code sent to an address at the brand's
  # domain. A free email address never verifies a brand. As with show verification (ShowVerification), the code is
  # never stored: BrandMailer#work_email_code makes it while the email renders and keeps only its HMAC digest, so it
  # never sits in the job queue or a log line. Each code allows MAX_ATTEMPTS guesses, counted under a row lock.
  # Requests are rate limited per account and per address by Brands::VerificationsController, and mail goes through
  # MailBudget like every other message.
  module WorkEmail
    CODE_TTL = 30.minutes
    RESEND_AFTER = 60.seconds
    MAX_ATTEMPTS = 5
    DIGEST_SALT = "brand_member/code".freeze
    ADDRESS = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    LOCKED_MESSAGE = "Too many tries. Request a new code to try again.".freeze
    EXPIRED_MESSAGE = "That code has expired. Request a new one.".freeze

    # Why a request can't go out, in words the member can act on.
    class Invalid < StandardError; end

    class Throttled < StandardError
      attr_reader :retry_in

      def initialize(retry_in)
        @retry_in = [ retry_in.to_f.ceil, 1 ].max
        super("Wait #{@retry_in} seconds before asking for another code.")
      end
    end

    module_function

    def normalize(email) = email.to_s.strip.downcase

    # Queues a code to email, an address at the member's brand domain. Retires any earlier code.
    def request_code!(member, email)
      address = normalize(email)
      check_address!(member.brand, address)
      member.with_lock do
        last_sent = member.code_expires_at && (member.code_expires_at - CODE_TTL)
        raise Throttled, last_sent + RESEND_AFTER - Time.current if last_sent && last_sent > RESEND_AFTER.ago

        member.update!(code_sent_to: address, code_digest: nil, code_expires_at: CODE_TTL.from_now, attempts: 0)
      end
      BrandMailer.with(member: member, sent_to: address).work_email_code.deliver_later
      address
    end

    def check_address!(brand, address)
      domain = brand.domain
      raise Invalid, "Add your company's website to your brand first, so we know which addresses count." if domain.blank?
      raise Invalid, "Enter a work email address." unless address.match?(ADDRESS)

      host = address.split("@", 2).last
      raise Invalid, "Free email addresses can't verify a brand. Use your address at #{domain}." if Brand.webmail?(Brand.normalize_domain(host))
      raise Invalid, "Use an address at #{domain}, your brand's website." unless Brand.normalize_domain(host) == domain
    end

    # Makes the code for the email being rendered and stores its digest. nil when the request was retired (a newer
    # address), expired or already used, so a late mail job sends nothing.
    def issue_code!(member, sent_to)
      member.with_lock do
        if !member.verified? && member.code_sent_to == sent_to && member.code_expires_at&.future?
          code = format("%06d", SecureRandom.random_number(1_000_000))
          member.update!(code_digest: digest(member.id, code), attempts: 0)
          code
        end
      end
    end

    # :verified, :wrong_code, :locked or :expired. Spaces and dashes in the typed code are ignored.
    def check_code(member, code)
      member.with_lock do
        next :verified if member.verified?
        next :locked if member.attempts >= MAX_ATTEMPTS
        next :expired if member.code_digest.blank? || !member.code_expires_at&.future?

        member.attempts += 1
        if ActiveSupport::SecurityUtils.secure_compare(member.code_digest, digest(member.id, code.to_s.gsub(/[\s-]/, "")))
          member.update!(verified_at: Time.current, code_digest: nil, code_expires_at: nil)
          member.brand.mark_verified!
          :verified
        else
          member.save!
          member.attempts >= MAX_ATTEMPTS ? :locked : :wrong_code
        end
      end
    end

    def pending?(member)
      !member.verified? && member.code_sent_to.present? && member.code_expires_at&.future? && member.attempts < MAX_ATTEMPTS
    end

    def attempts_left(member) = [ MAX_ATTEMPTS - member.attempts, 0 ].max

    def digest(id, code)
      key = Rails.application.key_generator.generate_key(DIGEST_SALT, 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{id}:#{code}")
    end
  end
end
