module Brands
  # "I'm a brand" (onboarding): the website finds the brand already at its domain, or makes a new one with the typed
  # name (Brand.for_onboarding); the user becomes its member, unverified until they prove a work email there. A name
  # never joins a brand, and onboarding never changes a brand's name or domain (review C1). update switches the
  # workspace to another of the user's brands.
  class ProfilesController < BaseController
    skip_before_action :require_brand_member, only: %i[new create]
    throttle to: 10, within: 1.hour, only: :create, by: -> { current_user.id }, name: "brand_profiles"

    WEBMAIL = "Use your company's website, not a free email provider.".freeze
    NEEDS_NAME = "Enter your brand's name.".freeze
    NEEDS_WEBSITE = "Enter your company's website, like yourbrand.com. A work email there verifies you.".freeze

    def new
      @name = current_brand&.name
      @website = current_brand&.domain
    end

    def create
      @name = params[:name].to_s.squish.first(Brand::NAME_LIMIT)
      @website = params[:website].to_s.strip.first(200)
      domain = Brand.normalize_domain(@website)
      return refuse(NEEDS_NAME) if @name.blank?
      return refuse(NEEDS_WEBSITE) if domain.nil?
      return refuse(WEBMAIL) if Brand.webmail?(domain)

      member = join(Brand.for_onboarding(name: @name, website: domain))
      session[:brand_member_id] = member.id
      current_user.working_as_brand!
      # Back to where the brand was going (a Request a spot form stores itself before sending them here), else search.
      if (back = stored_location_for(:user))
        return redirect_to(back, status: :see_other, notice: "Welcome to #{APP_NAME} for brands.")
      end

      redirect_to new_brand_search_path, status: :see_other,
                                         notice: "Welcome to #{APP_NAME} for brands. Run your first search below."
    rescue ActiveRecord::RecordInvalid => e
      refuse("#{Copy.and_list(e.record.errors.full_messages)}.")
    end

    def update
      member = current_user.brand_members.find_by!(id: params[:member_id])
      session[:brand_member_id] = member.id
      redirect_to brand_root_path, status: :see_other
    end

    private

    def join(brand)
      current_user.brand_members.find_by(brand: brand) ||
        current_user.brand_members.create!(brand: brand, role: brand.members.exists? ? "member" : "owner")
    rescue ActiveRecord::RecordNotUnique
      current_user.brand_members.find_by!(brand: brand)
    end

    def refuse(message)
      flash.now[:alert] = message
      render :new, status: :unprocessable_content
    end
  end
end
