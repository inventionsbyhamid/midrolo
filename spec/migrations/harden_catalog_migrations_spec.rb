require "rails_helper"
require Rails.root.join("db/migrate/20261030130000_create_podcast_feed_moves")
require Rails.root.join("db/migrate/20261030130100_add_downloads_bands_only_to_podcasts")

# The two migrations of the hardening lane, run down and up again on the test database inside the example's
# transaction (Postgres rolls DDL back with it), with rows like production's.
RSpec.describe "Hardening migrations" do
  def migrate(migration, direction)
    ActiveRecord::Migration.suppress_messages { migration.new.migrate(direction) }
    Podcast.reset_column_information
  end

  it "adds downloads_bands_only, set for a claimed show whose owner chose ranges, and clears unclaimed figures" do
    banded = create(:podcast, :claimed, downloads_per_episode: 4_200, downloads_trust: "verified")
    create(:media_kit, show: create(:show, podcast: banded, verified_at: 1.day.ago), bands_only: true)
    exact = create(:podcast, :claimed, downloads_per_episode: 900, downloads_trust: "provided")
    create(:media_kit, show: create(:show, podcast: exact, verified_at: 1.day.ago))
    stale = create(:podcast, downloads_per_episode: 2_000, downloads_trust: "verified")

    migrate(AddDownloadsBandsOnlyToPodcasts, :down)
    expect(Podcast.column_names).not_to include("downloads_bands_only")
    migrate(AddDownloadsBandsOnlyToPodcasts, :up)

    expect(banded.reload).to have_attributes(downloads_bands_only: true, downloads_per_episode: 4_200)
    expect(exact.reload).to have_attributes(downloads_bands_only: false, downloads_per_episode: 900)
    expect(stale.reload).to have_attributes(downloads_per_episode: nil, downloads_trust: nil)
  end

  it "makes podcast_feed_moves, which go with their podcast and outlive the show they released" do
    migrate(CreatePodcastFeedMoves, :down)
    expect(ActiveRecord::Base.connection.table_exists?(:podcast_feed_moves)).to be(false)
    migrate(CreatePodcastFeedMoves, :up)
    PodcastFeedMove.reset_column_information

    show = create(:show)
    move = PodcastFeedMove.create!(podcast: show.podcast, from_url: "https://a.example.com/f", to_url: "https://b.example.com/f",
                                   via: "redirect", released_show: show)
    show.destroy!
    expect(move.reload.released_show_id).to be_nil
    show.podcast.destroy!
    expect(PodcastFeedMove.exists?(move.id)).to be(false)
  end
end
