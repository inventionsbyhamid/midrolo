# The pipeline form on a match card (sponsor_matches/_status_form): status, notes and follow-up date. Turbo gets
# the form morphed in place plus a polite "Saved"; a no-JavaScript submit goes back to the card. Only the copy of a
# brand that counts can be changed (R48): an older report's copy, superseded by a newer one, is refused.
class SponsorMatchesController < ApplicationController
  include PipelineGate

  before_action :authenticate_user!
  before_action :set_sponsor_match
  before_action :require_pipeline
  before_action :refuse_superseded

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

  # 409 with the form turned read-only (pointing at the newer copy) for Turbo; the newer copy's card otherwise.
  def refuse_superseded
    match = @sponsor_match
    @newer = Pipeline::Matches.newer_copies(match.report, brand_entity_ids: [ match.brand_entity_id ])[match.brand_entity_id]
    return unless @newer

    respond_to do |format|
      format.turbo_stream { render :update, status: :conflict }
      format.html do
        redirect_to card_path(@newer), status: :see_other,
                                       notice: "#{match.name} is tracked on your latest report, so update it there."
      end
    end
  end

  def sponsor_match_params
    params.expect(sponsor_match: %i[status notes follow_up_on])
  end

  def redirect_back_to_card
    flash_message = @saved ? { notice: "Saved #{@sponsor_match.name}." } : { alert: "Couldn't save: #{Copy.and_list(@sponsor_match.errors.full_messages)}." }
    redirect_to card_path(@sponsor_match), status: :see_other, **flash_message
  end

  def card_path(match) = show_report_path(match.show_id, match.report_id, anchor: helpers.dom_id(match))
end
