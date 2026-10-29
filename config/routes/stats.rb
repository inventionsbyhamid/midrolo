# Drawn by config/routes.rb (draw(:stats)). Verified stats (build spec section 11): the workspace's Stats screen with
# its Spotify and Apple connections and the numbers provided by the show, and the admin's service sessions and
# connections queue.
resources :shows, only: [] do
  resource :stats, only: :show do
    # The owner's own downloads per episode ("provided by the show").
    patch :provided
  end
  # "I've invited Midrolo" (create), check now, and disconnect (destroy).
  resources :stat_connections, only: %i[create destroy], path: "stats/connections" do
    post :check, on: :member
  end
end

namespace :admin do
  # Midrolo's own platform sessions: entered as a form, never shown again; a test fetch against a connection.
  resources :service_sessions, only: %i[index update], param: :platform do
    post :test, on: :member
  end
  # Pending invites (oldest first, so the admin knows which to accept) and every other connection.
  resources :stat_connections, only: :index do
    post :check, on: :member
    # A connection held because another show has the same name (Stats::Ownership::NEEDS_REVIEW), checked by hand:
    # approve counts it, reject disconnects it with its numbers (Stats::RejectConnection).
    post :approve, on: :member
    post :reject, on: :member
  end
end
