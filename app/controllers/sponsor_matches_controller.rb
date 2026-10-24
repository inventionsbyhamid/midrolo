# The pipeline form on a match card (sponsor_matches/_status_form): status, notes and follow-up date. Turbo gets
# the form morphed in place plus a polite "Saved"; a no-JavaScript submit goes back to the card.
class SponsorMatchesController < ApplicationController
  include PipelineGate

  before_action :authenticate_user!
  before_action :set_sponsor_match
  before_action :require_pipeline

  def update
    @saved = @sponsor_match.update(sponsor_match_params)
    respond_to do |format|
      format.turbo_stream { render :update, status: (@saved ? :ok : :unprocessable_content) }
      format.html { redirect_back_to_card }
    end
  end

  private

  # Another user's match and a locked Snapshot match (R43) are both simply not found, so no response names a
  # brand the podcaster can't see.
  def set_sponsor_match
    @sponsor_match = current_user.sponsor_matches.includes(:report).find(params[:id])
    raise ActiveRecord::RecordNotFound if @sponsor_match.locked?(plan)
  end

  def sponsor_match_params
    params.expect(sponsor_match: %i[status notes follow_up_on])
  end

  def redirect_back_to_card
    flash_message = @saved ? { notice: "Saved #{@sponsor_match.name}." } : { alert: "Couldn't save: #{@sponsor_match.errors.full_messages.to_sentence}." }
    redirect_to show_report_path(@sponsor_match.show_id, @sponsor_match.report_id, anchor: helpers.dom_id(@sponsor_match)),
                status: :see_other, **flash_message
  end
end
