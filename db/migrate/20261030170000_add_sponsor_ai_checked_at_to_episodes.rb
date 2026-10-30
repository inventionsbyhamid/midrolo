# AI-first sponsor detection (2026-10-30): each recent episode gets one model check, and model work is never repeated.
# sponsor_ai_checked_at records when the AI-first scan settled an episode (the model checked it, or its notes were too
# short to hold a read), apart from sponsor_scanned_at, which the pattern-only scans before it set too. Episodes that
# already carry a reading the model confirmed (detected_by 'llm') were checked by the model and count as done. The
# partial index serves the scan's lookup: a podcast's episodes not yet checked, the newest first.
class AddSponsorAiCheckedAtToEpisodes < ActiveRecord::Migration[8.1]
  BACKFILL = <<~SQL.squish.freeze
    UPDATE episodes SET sponsor_ai_checked_at = COALESCE(sponsor_scanned_at, CURRENT_TIMESTAMP)
    WHERE sponsor_ai_checked_at IS NULL AND EXISTS (
      SELECT 1 FROM sponsor_mentions
      WHERE sponsor_mentions.episode_id = episodes.id AND sponsor_mentions.detected_by = 'llm'
    )
  SQL

  def up
    add_column :episodes, :sponsor_ai_checked_at, :datetime
    execute BACKFILL
    add_index :episodes, %i[podcast_id published_at], order: { published_at: :desc }, where: "sponsor_ai_checked_at IS NULL",
                                                      name: "index_episodes_ai_unchecked_on_podcast_id_and_published_at"
  end

  def down
    remove_index :episodes, name: "index_episodes_ai_unchecked_on_podcast_id_and_published_at"
    remove_column :episodes, :sponsor_ai_checked_at
  end
end
