# The pipeline (match statuses, notes, follow-ups and the /pipeline page) is a Creator+ feature (R45, spec §11).
# Without it on their plan, a podcaster's pipeline requests go to pricing with a notice; a Turbo form submit
# follows the 303 there too.
module PipelineGate
  extend ActiveSupport::Concern

  UPSELL = "Tracking brands in your pipeline is part of the Creator plan.".freeze

  private

  def plan = @plan ||= Entitlements.for(current_user)

  def require_pipeline
    redirect_to pricing_path, notice: UPSELL, status: :see_other unless plan.pipeline?
  end
end
