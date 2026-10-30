require "rails_helper"
require Rails.root.join("db/migrate/20261030170000_add_sponsor_ai_checked_at_to_episodes")

# Run down and up again on the test database inside the example's transaction (Postgres rolls DDL back with it), with
# rows like production's: episodes the model checked carry a reading it confirmed (detected_by "llm").
RSpec.describe AddSponsorAiCheckedAtToEpisodes do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    Episode.reset_column_information
  end

  after { Episode.reset_column_information }

  it "marks the episodes with a reading the model confirmed as checked, and no other" do
    checked = create(:episode, sponsor_scanned_at: 2.days.ago)
    create(:sponsor_mention, episode: checked, detected_by: "llm")
    create(:sponsor_mention, episode: checked, detected_by: "pattern")
    patterned = create(:episode, sponsor_scanned_at: 1.day.ago)
    create(:sponsor_mention, episode: patterned, detected_by: "pattern")
    plain = create(:episode, sponsor_scanned_at: 1.day.ago)
    waiting = create(:episode)

    migrate(:down)
    expect(Episode.column_names).not_to include("sponsor_ai_checked_at")
    migrate(:up)

    expect(checked.reload.sponsor_ai_checked_at).to be_within(1.second).of(checked.sponsor_scanned_at)
    expect([ patterned, plain, waiting ].map { |episode| episode.reload.sponsor_ai_checked_at }).to all(be_nil)
    index = ActiveRecord::Base.connection.indexes(:episodes).find { |i| i.name == "index_episodes_ai_unchecked_on_podcast_id_and_published_at" }
    expect(index).to have_attributes(columns: %w[podcast_id published_at], where: "(sponsor_ai_checked_at IS NULL)",
                                     orders: { "published_at" => :desc })
  end
end
