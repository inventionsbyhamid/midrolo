# The pitch pack's pieces: the card's button (pitches/_button) and the dialog (pitches/_pitch).
module PitchesHelper
  GMAIL_COMPOSE = "https://mail.google.com/mail/?view=cm&fs=1".freeze
  BODY_WORDS = 100..150

  # Gmail's compose window with the pitch's subject and body filled in, each URL-encoded.
  def gmail_compose_url(pitch)
    "#{GMAIL_COMPOSE}&su=#{ERB::Util.url_encode(pitch.subject.to_s)}&body=#{ERB::Util.url_encode(pitch.body.to_s)}"
  end

  # True once the match has a pitch, so its card opens that one instead of writing another. Asks once per report per
  # render: a report page draws this button on every card, also inside Turbo broadcasts from jobs.
  def pitch_written?(match)
    @pitched_match_ids ||= {}
    ids = @pitched_match_ids.fetch(match.report_id) do
      @pitched_match_ids[match.report_id] =
        Pitch.joins(:sponsor_match).where(sponsor_matches: { report_id: match.report_id }).distinct.pluck(:sponsor_match_id).to_set
    end
    ids.include?(match.id)
  end

  # "132 words", plus the target range when the body misses it.
  def pitch_word_count(pitch)
    count = pitch.word_count
    text = pluralize(count, "word")
    BODY_WORDS.cover?(count) ? text : "#{text} · aim for #{BODY_WORDS.min} to #{BODY_WORDS.max}"
  end
end
