# Drawn by config/routes.rb (draw(:brands)). Lane L6: the brand workspace under /brand with Brands:: controllers.
# (The public brand page, /brands/:slug, is L3's, in catalog.rb.)
#
#   /brand                      the dashboard (ApplicationController::BRAND_HOME): searches, saved shows, requests
#   /brand/start                "I'm a brand": the brand's name and website (onboarding)
#   /brand/verification         prove a work email at the brand's domain with a 6-digit code
#   /brand/searches/...         fit searches: start one, watch its agent steps, read the results
#   /brand/saved/...            the brand's saved shows; :id is the podcast's public id
scope "brand", module: "brands", as: "brand" do
  root "dashboard#show"
  get "start", to: "profiles#new", as: :start
  resource :profile, only: %i[create update]
  resource :verification, only: %i[new create show update]
  resources :searches, only: %i[index new create show]
  resources :saved, controller: "saved_podcasts", as: :saved_podcasts, only: %i[index show create destroy]
end
