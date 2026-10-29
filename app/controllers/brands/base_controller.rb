module Brands
  # The brand workspace (lane L6, /brand): a signed-in member of a brand works here. What a brand shares (its saved
  # shows, its members' searches) is visible to verified members only; before verifying, a member sees only what they
  # made, so anyone can join a brand by name without reading its work.
  class BaseController < ApplicationController
    layout "brand"
    before_action :authenticate_user!
    before_action :require_brand_member

    helper_method :current_brand_member, :current_brand

    private

    def current_brand_member
      return @current_brand_member if defined?(@current_brand_member)

      @current_brand_member = current_user.brand_member(session[:brand_member_id])
    end

    def current_brand = current_brand_member&.brand

    def require_brand_member
      redirect_to brand_start_path unless current_brand_member
    end

    # A brand's shared rows as this member may see them: all once verified, else only their own.
    def brand_scoped(relation) = current_brand_member.verified? ? relation : relation.where(user: current_user)

    # Searches this user may open: their own, and every search of a brand where they are verified.
    def visible_searches
      FitSearch.where(user: current_user).or(FitSearch.where(brand_id: current_user.brand_members.verified.select(:brand_id)))
    end
  end
end
