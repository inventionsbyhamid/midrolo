module Brands
  # Verifying a brand member's work email (Brands::WorkEmail): new asks for the address, create sends a 6-digit code,
  # show takes the code, update checks it. A verified member sends more requests a day and sees the brand's shared
  # work.
  class VerificationsController < BaseController
    # Codes sent, per account and per address (any account), on top of WorkEmail's one a minute.
    throttle to: 5, within: 1.hour, only: :create, by: -> { current_user.id }, name: "brand_code_sends"
    throttle to: 5, within: 1.day, only: :create, name: "brand_code_sends_per_address",
             by: -> { Digest::SHA256.hexdigest(WorkEmail.normalize(params[:email])) }
    # Guesses, on top of WorkEmail's per-code limit.
    throttle to: 10, within: 1.minute, only: :update, by: -> { current_user.id }, name: "brand_code_checks"

    before_action :redirect_verified, except: :show

    VERIFIED = "You're verified. Podcasters see a verified brand, and you can send more requests each day.".freeze

    def new
      @email = current_user.email if current_brand.domain.present? &&
                                     Brand.normalize_domain(current_user.email.to_s.split("@").last) == current_brand.domain
    end

    def create
      WorkEmail.request_code!(current_brand_member, params[:email])
      redirect_to brand_verification_path, status: :see_other
    rescue WorkEmail::Invalid => e
      @email = params[:email].to_s.strip.first(200)
      flash.now[:alert] = e.message
      render :new, status: :unprocessable_content
    rescue WorkEmail::Throttled => e
      redirect_to brand_verification_path, alert: "We just sent a code. You can ask for another in #{helpers.pluralize(e.retry_in, 'second')}.",
                                           status: :see_other
    end

    def show
      return redirect_to(brand_root_path, notice: VERIFIED) if current_brand_member.verified?

      redirect_to new_brand_verification_path unless current_brand_member.code_sent_to.present?
    end

    def update
      case WorkEmail.check_code(current_brand_member, params[:code])
      when :verified then redirect_to brand_root_path, notice: VERIFIED, status: :see_other
      when :wrong_code
        left = helpers.pluralize(WorkEmail.attempts_left(current_brand_member), "try")
        redirect_to brand_verification_path, alert: "That code didn't match. You have #{left} left.", status: :see_other
      when :locked then redirect_to brand_verification_path, alert: WorkEmail::LOCKED_MESSAGE, status: :see_other
      else redirect_to brand_verification_path, alert: WorkEmail::EXPIRED_MESSAGE, status: :see_other
      end
    end

    private

    def redirect_verified
      redirect_to brand_root_path, notice: VERIFIED, status: :see_other if current_brand_member.verified?
    end
  end
end
