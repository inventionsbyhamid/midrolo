module Conversations
  # When a podcast is claimed (Show#verify!, after its transaction): the requests that waited for the claim open, and
  # the new owner gets one email saying how many brands asked (never one per request, and never to the feed's owner
  # address: to the account that claimed). A brand the podcast blocked before (under an earlier owner) stays closed.
  # Safe to call again: with nothing waiting it does nothing.
  module ClaimHandoff
    module_function

    # The number of requests opened.
    def call(podcast)
      now = Time.current
      waiting = Conversation.waiting_for_claim.where(podcast_id: podcast.id)
      brand_ids = waiting.distinct.pluck(:brand_id)
      return 0 if brand_ids.empty?

      blocked = Block.where(podcast_id: podcast.id).select(:brand_id)
      waiting.where(brand_id: blocked).update_all(status: "closed", closed_at: now, updated_at: now)
      opened = waiting.update_all(status: "open", updated_at: now)

      podcast.touch
      ConversationMailer.with(podcast: podcast).waiting_requests.deliver_later if opened.positive?
      Broadcast.podcast_inbox(podcast)
      brand_ids.each { |brand_id| Broadcast.brand_inbox(brand_id) }
      opened
    end
  end
end
