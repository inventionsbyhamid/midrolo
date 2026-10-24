# Development-only gallery of the design system. The route only exists in
# development; the guard below keeps the page dark if it is ever routed elsewhere.
class StyleguideController < ApplicationController
  LAYOUTS = %w[app marketing kit print application].freeze

  before_action :development_only
  layout :chosen_layout

  def show
    flash.now[:notice] = "Report started. Matches appear here as the agent finds them."
    flash.now[:alert] = "Qloo didn't answer. Your saved sections are kept; try again in a minute."
  end

  private

  def development_only
    head :not_found unless Rails.env.development?
  end

  # /styleguide?layout=kit previews the same page inside another layout.
  def chosen_layout
    LAYOUTS.include?(params[:layout]) ? params[:layout] : "app"
  end
end
