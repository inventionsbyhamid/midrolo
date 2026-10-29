class FitSearch
  # Open search pages re-render (morphed, as a report's do) when the search starts, finishes or fails; its agent steps
  # stream on their own (AgentStep's callbacks).
  module Broadcast
    module_function

    def refresh(search) = Turbo::StreamsChannel.broadcast_refresh_to(search)
  end
end
