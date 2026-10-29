# Drawn by config/routes.rb (draw(:conversations)). Request a spot and the inboxes (build spec L7).
#   /inbox                  everything the user is a party to, both sides (the nav's Inbox)
#   /shows/:show_id/inbox   one workspace's requests (the podcaster side)
#   /brand/inbox            the brand side (the brand dashboard links here)
#   /conversations/new      the Request a spot form on its own page (?podcast=<slug>): sign in and brand setup
#                           come back here, and fit results link to it
#   /conversations/:id      a thread, for either side; its messages, answers, report and block
get "inbox", to: "conversations#index", as: :inbox
get "shows/:show_id/inbox", to: "conversations#index", as: :show_inbox
get "brand/inbox", to: "conversations#index", as: :brand_inbox, defaults: { side: "brand" }
resources :conversations, only: %i[new create show] do
  member do
    patch :accept
    patch :decline
    patch :close
    post :report
    post :block
    delete :block, action: :unblock
  end
  resources :messages, only: :create
end
