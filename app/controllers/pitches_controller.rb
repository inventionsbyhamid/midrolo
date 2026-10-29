# Pitch packs on a match card (spec §5.5). The card's button POSTs and the dialog opens on a skeleton; GeneratePitchJob
# writes the pitch and Pitch streams the result in, over a signed stream only the owner's dialog subscribes to (R50).
# Inside the dialog, Regenerate (and Try again, and Write my pitch on an empty dialog) POST with regenerate=1 and swap
# just the dialog's pack. GET shows the match's newest pitch, or with pitch_id that pitch's current state, for the
# dialog to catch up once it has subscribed. Another user's match and a locked Snapshot match (R43) are not found.
class PitchesController < ApplicationController
  layout "app"
  throttle to: 30, within: 1.hour, only: :create, by: :user_or_ip
  before_action :authenticate_user!
  before_action :set_sponsor_match

  def show
    @catch_up = params[:pitch_id].present?
    @pitch = @catch_up ? @sponsor_match.pitches.find_by!(public_id: params[:pitch_id]) : @sponsor_match.latest_pitch
  end

  def create
    @regenerate = params[:regenerate].present?
    @pitch = reusable_pitch || start_pitch
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to sponsor_match_pitch_path(@sponsor_match), status: :see_other }
    end
  rescue Entitlements::NotAllowed => e
    over_limit(e)
  end

  private

  def set_sponsor_match
    @sponsor_match = current_user.sponsor_matches.includes(report: :show).find_by!(public_id: params[:sponsor_match_id])
    raise ActiveRecord::RecordNotFound if @sponsor_match.locked?(plan)
  end

  def plan = current_plan

  # A pitch still being written is never started twice (a second tab, Regenerate mid-write); without regenerate, a
  # written pitch opens again rather than spending another.
  def reusable_pitch
    latest = @sponsor_match.latest_pitch
    return latest if latest&.in_flight?

    latest if latest&.done? && !@regenerate
  end

  # The match's newest pitch while it is still being written, read fresh.
  def in_flight_pitch
    latest = @sponsor_match.latest_pitch
    latest if latest&.in_flight?
  end

  # The plan's gate and the insert run under the user's usage lock, so parallel requests can't start pitches the plan
  # has no room for (R61). A double-submit for this match that held the lock first already started a pitch, which is
  # shown, as Report.start! does for reports. A concurrent request that inserted first wins too, and its pitch is
  # shown.
  def start_pitch
    created = nil
    pitch = Pitch.transaction do
      Entitlements.lock_usage!(current_user)
      in_flight_pitch || (created = create_pitch!)
    end
    GeneratePitchJob.perform_later(created.id) if created
    pitch
  rescue ActiveRecord::RecordNotUnique
    @sponsor_match.pitches.queued.newest_first.first || raise
  end

  # Plan#authorize! counts done pitches and reserves the user's pitches still being written (R53). The database allows
  # one queued pitch per match (R53); one stuck in the queue already shows as failed, so it's failed first.
  def create_pitch!
    plan.authorize!(:pitch)
    @sponsor_match.pitches.queued.each { |stuck| stuck.mark_failed! if stuck.stale? }
    @sponsor_match.pitches.create!
  end

  # 402 with the plan's refusal (Entitlements::NotAllowed#details) and the way forward; a pitch already on screen
  # stays there.
  def over_limit(error)
    @refusal = error.details
    @pitch = @sponsor_match.latest_pitch
    respond_to do |format|
      format.turbo_stream { render :over_limit, status: :payment_required }
      format.html { render :over_limit, status: :payment_required }
    end
  end
end
