# Pitch packs on a match card (spec §5.5). The card's button POSTs and the dialog opens on a skeleton; GeneratePitchJob
# writes the pitch and Pitch streams the result in, over a signed stream only the owner's dialog subscribes to (R50).
# Inside the dialog, Regenerate (and Try again, and Write my pitch on an empty dialog) POST with regenerate=1 and swap
# just the dialog's pack. GET shows the match's newest pitch, or with pitch_id that pitch's current state, for the
# dialog to catch up once it has subscribed. Another user's match and a locked Snapshot match (R43) are not found.
class PitchesController < ApplicationController
  layout "app"
  before_action :authenticate_user!
  before_action :set_sponsor_match

  def show
    @catch_up = params[:pitch_id].present?
    @pitch = @catch_up ? @sponsor_match.pitches.find(params[:pitch_id]) : @sponsor_match.latest_pitch
  end

  def create
    @regenerate = params[:regenerate].present?
    @pitch = reusable_pitch
    return over_limit if @pitch.nil? && !pitch_allowed?

    @pitch ||= start_pitch
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to sponsor_match_pitch_path(@sponsor_match), status: :see_other }
    end
  end

  private

  def set_sponsor_match
    @sponsor_match = current_user.sponsor_matches.includes(report: :show).find(params[:sponsor_match_id])
    raise ActiveRecord::RecordNotFound if @sponsor_match.locked?(plan)
  end

  def plan = @plan ||= Entitlements.for(current_user)

  # pitches_left may be Float::INFINITY (unlimited); nil counts as none.
  def pitch_allowed? = plan.can_pitch? && plan.pitches_left.to_f.positive?

  # A pitch still being written is never started twice (a second tab, Regenerate mid-write); without regenerate, a
  # written pitch opens again rather than spending another.
  def reusable_pitch
    latest = @sponsor_match.latest_pitch
    return latest if latest&.in_flight?

    latest if latest&.done? && !@regenerate
  end

  def start_pitch
    pitch = @sponsor_match.pitches.create!
    GeneratePitchJob.perform_later(pitch.id)
    pitch
  end

  # 402 with the reason and the way to more pitches; a pitch already on screen stays there.
  def over_limit
    @limit_reason = plan.can_pitch? ? :used_up : :plan
    @pitch = @sponsor_match.latest_pitch
    respond_to do |format|
      format.turbo_stream { render :over_limit, status: :payment_required }
      format.html { render :over_limit, status: :payment_required }
    end
  end
end
