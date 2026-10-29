module Conversations
  # A podcast's owner stops a brand: a Block row (Conversations::Start refuses the brand's requests while it's there),
  # and every conversation still running between them closes. Unblocking only removes the row.
  module BlockBrand
    module_function

    def block(podcast:, brand:)
      begin
        Block.find_or_create_by!(podcast: podcast, brand: brand)
      rescue ActiveRecord::RecordNotUnique
        nil # blocked in parallel: the row is there
      end
      now = Time.current
      Conversation.where(podcast_id: podcast.id, brand_id: brand.id, status: Conversation::WRITABLE)
                  .update_all(status: "closed", closed_at: now, updated_at: now)
      changed(podcast, brand)
    end

    def unblock(podcast:, brand:)
      Block.where(podcast_id: podcast.id, brand_id: brand.id).delete_all
      changed(podcast, brand)
    end

    def blocked?(podcast_id:, brand_id:) = Block.exists?(podcast_id: podcast_id, brand_id: brand_id)

    def changed(podcast, brand)
      podcast.touch
      Conversation.where(podcast_id: podcast.id, brand_id: brand.id).find_each { |conversation| Broadcast.thread(conversation) }
      Broadcast.podcast_inbox(podcast)
      Broadcast.brand_inbox(brand.id)
    end
    private_class_method :changed
  end
end
