module Conversations
  # Turbo Stream refreshes for the pages that show conversations: a thread, a podcast's inbox (its owner's) and a
  # brand's inbox. A refresh carries no data: each page that hears it fetches itself again as its own viewer, so one
  # broadcast suits both sides, and the page that made the change ignores it (Turbo's request id). The stream names
  # use public ids, so a page's markup never shows a database id.
  module Broadcast
    module_function

    def changed(conversation)
      thread(conversation)
      podcast_inbox(conversation.podcast)
      brand_inbox(conversation.brand_id)
    end

    def thread(conversation) = refresh(thread_stream(conversation))

    def podcast_inbox(podcast) = refresh(podcast_stream(podcast))

    def brand_inbox(brand_or_id)
      brand = brand_or_id.is_a?(Brand) ? brand_or_id : Brand.find_by(id: brand_or_id)
      refresh(brand_stream(brand)) if brand
    end

    def thread_stream(conversation) = "conversation:#{conversation.public_id}"

    def podcast_stream(podcast) = "inbox:podcast:#{podcast.public_id}"

    def brand_stream(brand) = "inbox:brand:#{brand.public_id}"

    def refresh(stream) = Turbo::StreamsChannel.broadcast_refresh_to(stream)
  end
end
