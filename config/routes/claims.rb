# Drawn by config/routes.rb (draw(:claims)). Lane L4: claiming a podcast from its public page, asking a claimed show's
# owner for access, the demo show's feed, and the admin's ownership transfer. The listing editor is inside the media
# kit editor (/shows/:show_id/media_kit/edit), and /k/:slug 301s to the podcast page's rates (PublicKitsController).
get "podcasts/:slug/claim", to: "claims#new", as: :new_podcast_claim, format: false
post "podcasts/:slug/claim", to: "claims#create", as: :podcast_claim, format: false
post "podcasts/:slug/claim/access", to: "claims#access", as: :podcast_claim_access, format: false

# The demo show's RSS feed (bin/rails demo:setup), served by Midrolo itself.
get "demo/feed.xml", to: "demo_feeds#show", as: :demo_feed, format: false, defaults: { format: "xml" }

namespace :admin do
  resources :claim_transfers, only: %i[new create]
end
