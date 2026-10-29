require "rails_helper"

RSpec.describe WorkspaceHelper do
  let(:user) { create(:user) }
  let(:show) { create(:show, user: user) }

  def states(steps) = steps.map { |step| [ step.key, step.state ] }

  it "leads a draft with the claim, then the listing and stats" do
    steps = helper.workspace_steps(show)

    expect(states(steps)).to eq([ [ :claim, :next ], [ :listing, :todo ], [ :stats, :todo ] ])
    expect(helper.workspace_next_step(steps)).to have_attributes(action: "Verify you own it", path: new_show_verification_path(show))
    expect(helper.workspace_progress(steps)).to eq("0 of 3 done")
  end

  it "moves on to the listing, then the stats, as each is done" do
    show.verify!(via: "admin")
    expect(states(helper.workspace_steps(show.reload))).to eq([ [ :claim, :done ], [ :listing, :next ], [ :stats, :todo ] ])

    create(:media_kit, :published, show: show, open_to_sponsors: true)
    steps = helper.workspace_steps(show.reload)
    expect(states(steps)).to eq([ [ :claim, :done ], [ :listing, :done ], [ :stats, :next ] ])
    expect(steps.second.status).to eq("Published, open to sponsors")
    expect(steps.third).to have_attributes(status: "Invite Midrolo on Spotify or Apple", path: show_stats_path(show))

    create(:stat_connection, podcast: show.podcast, show: show, user: user, status: "pending_invite")
    expect(helper.workspace_steps(show.reload).third.status).to eq("Waiting for access on Spotify")

    show.podcast.stat_connections.sole.update!(status: "active", activated_at: Time.current)
    steps = helper.workspace_steps(show.reload)
    expect(steps.third).to have_attributes(state: :done, status: "Verified with Spotify")
    expect(helper.workspace_next_step(steps)).to be_nil
    expect(helper.workspace_progress(steps)).to eq("3 of 3 done")
  end

  it "blocks the claim, and offers no next step, when another account owns the show" do
    create(:show, podcast: show.podcast).verify!(via: "admin")
    steps = helper.workspace_steps(show.reload)

    expect(steps.first).to have_attributes(state: :blocked, action: "Ask for access")
    expect(helper.workspace_next_step(steps)).to be_nil
  end

  it "says what's waiting in the inbox" do
    expect(helper.workspace_requests_line(show, { unread: 2, open: 3, waiting: 0 })).to eq("2 requests with something new")
    expect(helper.workspace_requests_line(show, { unread: 0, open: 1, waiting: 0 })).to eq("1 request to answer")
    expect(helper.workspace_requests_line(show, { unread: 0, open: 0, waiting: 2 })).to eq("2 brands waiting for your claim")
    expect(helper.workspace_requests_line(show, { unread: 0, open: 0, waiting: 0 })).to be_nil
  end
end
