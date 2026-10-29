# Lane L7's spec setup: a claimed podcast and its owner, a brand and its member, and a request between them.
module InboxHelpers
  # A podcast claimed by owner (a verified show), with an address in its feed that must never get mail.
  def claimed_podcast(owner: create(:user), title: "The Founder's Ledger")
    show = create(:show, user: owner, title: title, owner_email: "feed-owner@example.com")
    show.verify!(via: "admin")
    show.podcast.reload
  end

  def brand_member_for(user = create(:user), brand: create(:brand), verified: false)
    create(:brand_member, user: user, brand: brand, verified_at: (Time.current if verified))
  end

  def request_form(**attributes)
    Conversations::RequestForm.new({ format: "midroll", months: [ Date.current.next_month.strftime("%Y-%m") ],
                                     budget: "500", body: "We'd love a midroll next month." }.merge(attributes))
  end

  # A conversation started by membership's user through Conversations::Start (so it has its first message).
  def start_request(podcast, membership, **attributes)
    Conversations::Start.call(podcast: podcast, membership: membership, form: request_form(**attributes)).conversation
  end
end

RSpec.configure do |config|
  config.include InboxHelpers
end
