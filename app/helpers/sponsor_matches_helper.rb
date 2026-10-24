# The pipeline pieces of a match card (sponsor_matches/_status_form) and of the /pipeline page.
module SponsorMatchesHelper
  FOLLOW_UP_TONES = { overdue: :danger, today: :warning }.freeze
  FOLLOW_UP_BADGES = { overdue: "Overdue", today: "Due today" }.freeze
  STATUS_TONES = { "saved" => :accent, "pitched" => :accent, "replied" => :accent, "won" => :success }.freeze

  # Asks Entitlements once per user per render: a report page draws a pipeline form on every card, also inside
  # Turbo broadcasts from jobs, where there is no current_user.
  def pipeline_enabled_for?(user)
    @pipeline_enabled ||= {}
    @pipeline_enabled.fetch(user.id) { @pipeline_enabled[user.id] = Entitlements.for(user).pipeline? }
  end

  # The copy of this match's brand that counts, when it is on a newer report (R48): the card then shows its status
  # read-only and links there. One query per report per render, however many cards.
  def newer_copy_for(match)
    @newer_copies ||= {}
    copies = @newer_copies.fetch(match.report_id) { @newer_copies[match.report_id] = Pipeline::Matches.newer_copies(match.report) }
    copies[match.brand_entity_id]
  end

  def status_options = SponsorMatch::STATUSES.map { |status| [ status.humanize, status ] }

  def status_badge(status) = ui_badge(status.humanize, tone: STATUS_TONES.fetch(status, :neutral))

  # Danger when an open deal's follow-up is overdue, warning when it's due today, otherwise neutral.
  def follow_up_tone(match) = FOLLOW_UP_TONES.fetch(match.follow_up_alert, :neutral)

  # "Due today" or "Overdue" on an open deal, or nil.
  def follow_up_badge(match)
    text = FOLLOW_UP_BADGES[match.follow_up_alert]
    ui_badge(text, tone: follow_up_tone(match)) if text
  end

  # "Nov 2", or "Nov 2, 2027" outside this year, in a <time>.
  def follow_up_time(date)
    text = date.year == Date.current.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y")
    tag.time(text, datetime: date.iso8601)
  end

  # The closed notes panel's flag: "Follow up today" or "Follow-up overdue" on an open deal, else "Follow up Nov 2".
  def follow_up_flag(match)
    return unless match.follow_up_on

    case match.follow_up_alert
    when :today then "Follow up today"
    when :overdue then "Follow-up overdue"
    else safe_join([ "Follow up ", follow_up_time(match.follow_up_on) ])
    end
  end
end
