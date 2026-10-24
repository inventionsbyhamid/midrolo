# Placeholder until onboarding (Task 8) replaces both pages.
class ShowsController < ApplicationController
  layout "app"
  before_action :authenticate_user!

  def index; end
  def new; end
end
