# The pipeline pieces of a match card (sponsor_matches/_status_form) and of the /pipeline page.
module SponsorMatchesHelper
  FOLLOW_UP_TONES = { overdue: :danger, today: :warning, upcoming: :neutral }.freeze
  FOLLOW_UP_BADGES = { overdue: "Overdue", today: "Due today" }.freeze

  # Asks Entitlements once per user per render: a report page draws a pipeline form on every card, also inside
  # Turbo broadcasts from jobs, where there is no current_user.
  def pipeline_enabled_for?(user)
    @pipeline_enabled ||= {}
    @pipeline_enabled.fetch(user.id) { @pipeline_enabled[user.id] = Entitlements.for(user).pipeline? }
  end

  def status_options = SponsorMatch::STATUSES.map { |status| [ status.humanize, status ] }

  def follow_up_tone(match) = FOLLOW_UP_TONES[match.follow_up_state]

  # "Due today" or "Overdue", or nil for a later date.
  def follow_up_badge(match)
    text = FOLLOW_UP_BADGES[match.follow_up_state]
    ui_badge(text, tone: follow_up_tone(match)) if text
  end

  # "Nov 2", or "Nov 2, 2027" outside this year, in a <time>.
  def follow_up_time(date)
    text = date.year == Date.current.year ? date.strftime("%b %-d") : date.strftime("%b %-d, %Y")
    tag.time(text, datetime: date.iso8601)
  end

  # The closed notes panel's flag: "Follow up Nov 2", "Follow up today" or "Follow-up overdue".
  def follow_up_flag(match)
    case match.follow_up_state
    when :today then "Follow up today"
    when :overdue then "Follow-up overdue"
    when :upcoming then safe_join([ "Follow up ", follow_up_time(match.follow_up_on) ])
    end
  end
end
