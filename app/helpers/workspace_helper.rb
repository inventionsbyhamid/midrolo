# The podcaster's three steps to being bookable (Your shows cards and the show workspace, review PO-1): claim the
# show, publish the listing, verify the stats. Each step says where it stands in plain words and names its action;
# the first step not done is "next", so a page can lead with one primary button.
module WorkspaceHelper
  Step = Data.define(:key, :title, :state, :status, :action, :path) do
    def done? = state == :done
    def next? = state == :next
    def blocked? = state == :blocked
  end

  # [claim, listing, stats] for show, the first unfinished one marked :next (unless the claim is someone else's).
  def workspace_steps(show)
    steps = [ workspace_claim_step(show), workspace_listing_step(show), workspace_stats_step(show) ]
    upcoming = steps.find { |step| step.state == :todo } unless steps.any?(&:blocked?)
    steps.map { |step| step.equal?(upcoming) ? step.with(state: :next) : step }
  end

  # "2 of 3 done"
  def workspace_progress(steps) = "#{steps.count(&:done?)} of #{steps.size} done"

  # The step to lead with: the next one, or nil when every step is done or the claim is blocked.
  def workspace_next_step(steps) = steps.find(&:next?)

  # The "brands are waiting" line for a show's requests, or nil when there's nothing to answer.
  def workspace_requests_line(show, counts = inbox_workspace_counts(show))
    if counts[:unread].positive?
      "#{pluralize(counts[:unread], 'request')} with something new"
    elsif counts[:open].positive?
      "#{pluralize(counts[:open], 'request')} to answer"
    elsif counts[:waiting].positive?
      "#{pluralize(counts[:waiting], 'brand')} waiting for your claim"
    end
  end

  # A step's mark: a tick when done, the step's number otherwise.
  def workspace_step_mark(step, index)
    return tag.span(index + 1, class: "step-mark", aria: { hidden: true }) unless step.done?

    tag.span(class: "step-mark", aria: { hidden: true }) do
      tag.svg(viewBox: "0 0 16 16", class: "size-3.5", fill: "none", stroke: "currentColor", "stroke-width": "2.5",
              "stroke-linecap": "round", "stroke-linejoin": "round") { tag.path(d: "M3.5 8.5l3 3 6-7") }
    end
  end

  private

  def workspace_claim_step(show)
    case show.claim_status
    when :claimed
      Step.new(:claim, "Claim", :done, "Yours since #{show.verified_at.strftime('%b %-d')}", nil, nil)
    when :managed_elsewhere
      Step.new(:claim, "Claim", :blocked, "Another account manages this show", "Ask for access",
               new_podcast_claim_path(show.podcast))
    else
      Step.new(:claim, "Claim", :todo, "Prove it's yours with a code or a line in your feed", "Verify you own it",
               new_show_verification_path(show))
    end
  end

  def workspace_listing_step(show)
    kit = show.media_kit
    if show.public_kit?
      status = kit.open_to_sponsors? ? "Published, open to sponsors" : "Published, not open to sponsors"
      Step.new(:listing, "List", :done, status, "Edit listing", edit_show_media_kit_path(show))
    else
      status = kit&.persisted? ? "Saved, not published yet" : "Your rates, open months and who you want"
      Step.new(:listing, "List", :todo, status, "Set up your listing", edit_show_media_kit_path(show))
    end
  end

  def workspace_stats_step(show)
    connections = show.podcast.stat_connections.to_a
    active = connections.select { |connection| connection.status == "active" }.sort_by { |connection| connection.provider == "spotify" ? 0 : 1 }
    if active.any? && show.verified?
      names = Copy.and_list(active.map { |connection| ::Stats.platform_name(connection.provider) })
      Step.new(:stats, "Verify stats", :done, "Verified with #{names}", "See stats", show_stats_path(show))
    elsif connections.any? { |connection| connection.status.in?(%w[mismatch failed disconnected]) }
      Step.new(:stats, "Verify stats", :todo, "A connection needs a look", "Fix your stats", show_stats_path(show))
    elsif connections.any? { |connection| connection.status == "pending_invite" }
      Step.new(:stats, "Verify stats", :todo, "Waiting for access on #{workspace_pending_platforms(connections)}",
               "Check your stats", show_stats_path(show))
    else
      Step.new(:stats, "Verify stats", :todo, "Invite Midrolo on Spotify or Apple", "Connect your stats",
               show_stats_path(show))
    end
  end

  def workspace_pending_platforms(connections)
    Copy.and_list(connections.select { |c| c.status == "pending_invite" }.map { |c| ::Stats.platform_name(c.provider) })
  end
end
