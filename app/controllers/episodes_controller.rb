# An episode's page (spec L3, plan 4.2): its notes from the feed, the sponsors found in them with codes and offers, the
# show's people and a link to the audio on the show's own site. Indexed only when it adds something a show page
# doesn't: a sponsor read found in it.
class EpisodesController < ApplicationController
  include CatalogPage

  def show
    @podcast = find_podcast(Podcast.for_cards.includes(people: { image: { file_attachment: :blob } }).strict_loading) do |slug|
      podcast_episode_path(slug, params[:episode_slug].to_s)
    end or return
    return render_removed if @podcast.removed?

    @episode = Episode.strict_loading.find_by!(podcast_id: @podcast.id, slug: params[:episode_slug].to_s)
    @mentions = SponsorMention.where(episode_id: @episode.id).includes(:brand).order(:id).strict_loading.to_a
    noindex! unless @podcast.page_indexable? && @mentions.any?
    return if fresh_for_visitors(etag: [ @podcast, @episode, @mentions ], last_modified: [ @podcast, @episode ].map(&:updated_at).max)

    @newer, @older = neighbours
  end

  private

  # The episodes either side of this one by date, as [newer, older] (nil at the ends or for an undated episode).
  def neighbours
    return [ nil, nil ] unless @episode.published_at

    scope = Episode.where(podcast_id: @podcast.id).where.not(id: @episode.id).strict_loading
    [ scope.where(published_at: @episode.published_at..).order(published_at: :asc, id: :asc).first,
      scope.where(published_at: ..@episode.published_at).newest_first.first ]
  end
end
