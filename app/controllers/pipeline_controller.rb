# Every brand the podcaster is working, across all their shows, grouped by stage (R46).
class PipelineController < ApplicationController
  include PipelineGate

  layout "app"
  before_action :authenticate_user!
  before_action :require_pipeline

  def index
    @matches = Pipeline::Matches.for(current_user).to_a
  end
end
