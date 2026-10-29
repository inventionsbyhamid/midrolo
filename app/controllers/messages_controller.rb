# A message in a conversation, from either side (Conversations::Reply). Found through Conversation.visible_to, so a
# third party gets a 404. A Turbo Stream request gets the message appended and a fresh form; the other side's open
# page refreshes through the conversation's stream.
class MessagesController < ApplicationController
  # Public form: throttled per user (build spec section 2), on top of the global per-IP limit.
  throttle to: 20, within: 5.minutes, by: :user_or_ip, scope: "conversation_messages"
  before_action :authenticate_user!

  def create
    @conversation = Conversation.visible_to(current_user).includes(:podcast, :brand).find_by!(public_id: params[:conversation_id])
    @side = @conversation.side_for(current_user) || raise(ActiveRecord::RecordNotFound)
    result = Conversations::Reply.call(conversation: @conversation, user: current_user, side: @side,
                                       body: params.dig(:message, :body))
    @message = result.message
    @error = result.error
    @brand_user_ids = BrandMember.where(brand_id: @conversation.brand_id).pluck(:user_id).to_set

    respond_to do |format|
      format.turbo_stream { render :create, status: result.ok? ? :ok : :unprocessable_content }
      format.html do
        result.ok? ? redirect_to(conversation_path(@conversation)) : redirect_to(conversation_path(@conversation), alert: @error)
      end
    end
  end
end
