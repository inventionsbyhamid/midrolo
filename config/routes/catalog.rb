# Drawn by config/routes.rb (draw(:catalog)). Lane L3's public catalog: /podcasts (the directory and search),
# /podcasts/category/:category (drawn before /podcasts/:slug), /podcasts/:slug and its episodes, removal, the public
# brand page /brands/:slug, the data sources page and the sitemaps. Lane L1 adds nothing public.
get "podcasts", to: "podcasts#index", as: :podcasts, format: false
# Search hits still being read from their feeds, reloaded into a Turbo Frame until they're ready. Under "search", which
# FriendlySlug never gives a podcast, so no show's page can be shadowed by it.
get "podcasts/search/adding", to: "podcasts#adding", as: :adding_podcasts, format: false
get "podcasts/category/:category", to: "categories#show", as: :podcast_category, format: false
get "podcasts/:slug", to: "podcasts#show", as: :podcast, format: false
# A page whose feed is still being read polls this until the podcast is ready.
get "podcasts/:slug/status", to: "podcasts#status", as: :podcast_status, format: false
get "podcasts/:slug/sign_in", to: "podcasts#sign_in_first", as: :podcast_sign_in, format: false
get "podcasts/:slug/episodes/:episode_slug", to: "episodes#show", as: :podcast_episode, format: false
get "podcasts/:slug/remove", to: "removal_requests#new", as: :new_podcast_removal, format: false
post "podcasts/:slug/remove", to: "removal_requests#create", as: :podcast_removal, format: false

# The public brand page ("Podcasts Notion sponsors"). The brand workspace is /brand (lane L6, config/routes/brands.rb).
get "brands/:slug", to: "brands#show", as: :public_brand, format: false

get "data-sources", to: "data_sources#show", as: :data_sources, format: false

# /sitemap.xml (config/routes.rb) is the index of these.
get "sitemaps/:name.xml", to: "sitemaps#show", as: :sitemap_part, format: false, defaults: { format: "xml" },
                          constraints: { name: /pages|podcasts|categories|brands|blog/ }

namespace :admin do
  resources :removal_requests, only: %i[index update]
end
