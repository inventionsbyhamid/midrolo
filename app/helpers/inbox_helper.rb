# The inbox's view helpers (build spec section 10: one module per lane, inbox_ names): request facts in words, status
# badges, read state and the links other lanes render (the brand dashboard, the nav).
module InboxHelper
  STATUS_TONES = { "waiting_for_claim" => :warning, "open" => :accent, "accepted" => :success, "declined" => :danger,
                   "closed" => :neutral }.freeze
  STATUS_LABELS = { "waiting_for_claim" => "Waiting for the show", "open" => "Open", "accepted" => "Accepted",
                    "declined" => "Declined", "closed" => "Closed" }.freeze
  # How many months the form offers, from this one.
  MONTHS_OFFERED = 6

  # "2026-11" => "Nov 2026".
  def inbox_month_label(month)
    Date.strptime(month.to_s, "%Y-%m").strftime("%b %Y")
  rescue Date::Error
    month.to_s
  end

  # [label, value] pairs for the form's month boxes: this month and the next five, plus any the request already has.
  def inbox_month_options(selected = [], from: Date.current)
    offered = Array.new(MONTHS_OFFERED) { |index| from.beginning_of_month.next_month(index).strftime("%Y-%m") }
    (offered | Array(selected)).sort.map { |month| [ inbox_month_label(month), month ] }
  end

  def inbox_budget(cents)
    number_to_currency(cents / 100.0, precision: 0) if cents
  end

  # The ask in a phrase: "a midroll in Nov 2026 and Dec 2026, with a budget of $500".
  def inbox_request_summary(conversation)
    format = MediaKit::RATE_SLOTS[conversation.format.to_s]
    parts = [ format ? "a #{format.downcase}" : "a spot" ]
    parts << "in #{Copy.and_list(conversation.months.map { |month| inbox_month_label(month) })}" if conversation.months.any?
    text = parts.join(" ")
    budget = inbox_budget(conversation.budget_cents)
    budget ? "#{text}, with a budget of #{budget}" : text
  end

  def inbox_status_badge(conversation)
    ui_badge STATUS_LABELS.fetch(conversation.status), tone: STATUS_TONES.fetch(conversation.status)
  end

  def inbox_unverified_badge(conversation)
    ui_badge("Unverified brand", tone: :warning) unless conversation.from_verified_brand?
  end

  # Who's on the other end, as this side sees it: the brand for a podcaster, the show for a brand.
  def inbox_counterparty(conversation, side)
    side == :podcaster ? conversation.brand.name : conversation.podcast.title
  end

  # "Oct 30" (or "Oct 30, 2025" in another year), "3 hours ago" within the day.
  def inbox_time(time)
    return "" unless time

    words = "#{time_ago_in_words(time)} ago" if time > 1.day.ago
    words ||= time.year == Time.current.year ? time.strftime("%b %-d") : time.strftime("%b %-d, %Y")
    tag.time(words, datetime: time.iso8601)
  end

  # Conversations with something new for the user, from both sides: the nav's Inbox count.
  def inbox_unread_count(user = current_user)
    return 0 unless user

    Conversation.for_podcaster(user).unread_by_podcaster.count + Conversation.for_brand_user(user).unread_by_brand.count
  end

  # A message's author as both sides see it: the person's first name and their side ("Maya, The Founder's Ledger").
  # brand_user_ids are the brand's members' user ids (one query per thread, not per message).
  def inbox_author(message, conversation, brand_user_ids)
    return "Deleted account" unless message.user

    side = brand_user_ids.include?(message.user_id) ? conversation.brand.name : conversation.podcast.title
    name = message.user.name.to_s.split.first || "Someone"
    "#{name}, #{side}"
  end

  # The Turbo streams an inbox page listens on for refreshes (Conversations::Broadcast): its podcasts' (the podcaster
  # side: the one workspace's, or every show the user owns) and the user's brands'.
  def inbox_streams(sides, show: nil, user: current_user)
    streams = []
    if sides.include?(:podcaster)
      podcasts = show ? [ show.podcast ] : Podcast.where(id: user.shows.where.not(verified_at: nil).select(:podcast_id))
      streams.concat(podcasts.map { |podcast| Conversations::Broadcast.podcast_stream(podcast) })
    end
    if sides.include?(:brand)
      brands = Brand.where(id: user.brand_members.select(:brand_id))
      streams.concat(brands.map { |brand| Conversations::Broadcast.brand_stream(brand) })
    end
    streams
  end

  # { unread:, open:, waiting: } for a workspace's requests card (conversations/_workspace): unread and open once the
  # show is verified, waiting (brands that asked before the claim) until then.
  def inbox_workspace_counts(show)
    if show.verified?
      requests = Conversation.where(podcast_id: show.podcast_id).where.not(status: "waiting_for_claim")
      { unread: requests.unread_by_podcaster.count, open: requests.open.count, waiting: 0 }
    else
      { unread: 0, open: 0, waiting: Conversation.waiting_for_claim.where(podcast_id: show.podcast_id).count }
    end
  end

  # The podcast's public page (lane L3's /podcasts/:slug), before and after that route exists.
  def inbox_podcast_path(podcast)
    respond_to?(:podcast_path) ? podcast_path(podcast) : "/podcasts/#{podcast.to_param}"
  end

  # The inbox a side's list lives in.
  def inbox_path_for(side, show: nil)
    return show_inbox_path(show) if side == :podcaster && show

    side == :brand ? brand_inbox_path : inbox_path
  end
end
