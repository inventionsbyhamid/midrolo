# One message in a conversation. The author link is nullified when their account goes; the text stays for the other
# party.
class Message < ApplicationRecord
  BODY_LIMIT = 4000

  belongs_to :conversation, inverse_of: :messages
  belongs_to :user, optional: true

  validates :body, presence: true, length: { maximum: BODY_LIMIT }

  after_create :touch_conversation

  private

  def touch_conversation
    conversation.update_columns(last_message_at: created_at, updated_at: created_at)
  end
end
