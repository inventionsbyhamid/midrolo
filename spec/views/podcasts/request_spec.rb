require "rails_helper"

# The podcast page's Request a spot box (lane L7), rendered as lane L3's page does: with a strict_loading podcast, so
# any association it touched would raise.
RSpec.describe "podcasts/_request" do
  let(:owner) { create(:user) }
  let(:claimed) { claimed_podcast(owner: owner, title: "The Founder's Ledger") }

  def strict(podcast) = Podcast.strict_loading.find(podcast.id)

  def render_box(podcast, user: nil)
    without_partial_double_verification { allow(view).to receive(:current_user).and_return(user) }
    render partial: "podcasts/request", locals: { podcast: strict(podcast) }
    Nokogiri::HTML(rendered)
  end

  it "sends a signed-out visitor to the form page, which signs them in" do
    box = render_box(claimed)

    link = box.at_css("#request a.btn")
    expect(link.text).to eq("Request a spot")
    expect(link["href"]).to eq("/conversations/new?podcast=#{claimed.slug}")
  end

  it "gives a brand member the form in a dialog" do
    membership = brand_member_for
    box = render_box(claimed, user: membership.user)

    expect(box.at_css("#request button[data-action='dialog#open']").text.strip).to eq("Request a spot")
    expect(box.at_css("dialog h2").text).to eq("Request a spot on The Founder's Ledger")
    form = box.at_css("dialog form[action='/conversations']")
    expect(form.at_css("input[name=podcast]")["value"]).to eq(claimed.slug)
    expect(form.css("input[name='spot_request[months][]'][type=checkbox]").size).to eq(6)
    expect(form.text).to include("Unverified brand label")
  end

  it "links an ongoing request and the owner's inbox instead of the form" do
    membership = brand_member_for
    conversation = start_request(claimed, membership)

    expect(render_box(claimed, user: membership.user).at_css("#request a")["href"]).to eq("/conversations/#{conversation.public_id}")
  end

  it "says a colleague asked, with no link or date, to an unverified member" do
    colleague = brand_member_for
    start_request(claimed, colleague)
    member = brand_member_for(brand: colleague.brand)

    box = render_box(claimed, user: member.user)

    expect(box.at_css("#request").text).to include(Conversations::Start::COLLEAGUE_ASKED)
    expect(box.css("#request a, #request form")).to be_empty
    expect(box.text).not_to include("You asked on")
  end

  it "points the owner at their requests" do
    expect(render_box(claimed, user: owner).at_css("#request a").text).to eq("Requests to your show")
  end

  it "counts the brands waiting on an unclaimed show" do
    unclaimed = create(:podcast)
    2.times { start_request(unclaimed, brand_member_for) }

    expect(render_box(unclaimed).text).to include("2 brands asked about sponsoring this show")
  end

  it "shows the reply time once the owner has answered 3 requests" do
    3.times { create(:conversation, podcast: claimed, created_at: 1.hour.from_now, first_reply_at: 3.hours.from_now) }

    expect(render_box(claimed).text).to include("Usually replies within a day")
  end
end
