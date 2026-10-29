Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # R134: Active Storage's direct-upload endpoint (drawn after these routes) is open to anyone, so it is closed: it
  # answers 404 like any unknown path. The media kit's photos upload through /uploads instead, which needs a signed-in
  # user and signs only small web images (R149). The read routes (blobs, representations, the disk service) stay open.
  match "rails/active_storage/direct_uploads", via: :all, to: ->(_env) { raise ActionController::RoutingError, "Not Found" }
  post "uploads", to: "direct_uploads#create", as: :direct_uploads, format: false

  devise_for :users,
             skip: %i[sessions registrations passwords confirmations unlocks],
             controllers: { omniauth_callbacks: "users/omniauth_callbacks" }
  devise_scope :user do
    get "users/sign_in", to: "devise/sessions#new", as: :new_user_session
    delete "users/sign_out", to: "devise/sessions#destroy", as: :destroy_user_session
  end

  # Public pages (Task 19, R78): the landing page for everyone, signed in or not, pricing, about and the legal pages,
  # the public sample reports, the sitemap and robots.txt (R88: a route, so its sitemap URL is the request's host).
  root "pages#home"
  get "pricing", to: "pages#pricing", as: :pricing
  get "about", to: "pages#about", as: :about
  get "privacy", to: "pages#privacy", as: :privacy
  get "terms", to: "pages#terms", as: :terms
  get "sitemap.xml", to: "pages#sitemap", as: :sitemap, format: false, defaults: { format: "xml" }
  get "robots.txt", to: "pages#robots", as: :robots, format: false, defaults: { format: "text" }
  resources :samples, only: %i[index show], param: :slug, format: false
  # Share images (og:image) for the sample reports and the public media kits: 1200x630 PNGs drawn by ShareImages.
  get "samples/:slug/og.png", to: "share_images#sample", as: :sample_share_image, format: false
  # A sample's media kit (R152): what a published kit looks like, for visitors whose own show isn't verified.
  get "samples/:slug/kit", to: "samples#kit", as: :sample_kit, format: false
  get "k/:slug/og.png", to: "share_images#kit", as: :kit_share_image, format: false
  # The blog (R148): Markdown posts from content/blog, an Atom feed and a share image for each post.
  get "blog", to: "blog#index", as: :blog, format: false
  get "blog/feed.xml", to: "blog#feed", as: :blog_feed, format: false, defaults: { format: "atom" }
  get "blog/:slug", to: "blog#show", as: :blog_post, format: false
  get "blog/:slug/og.png", to: "share_images#blog_post", as: :blog_post_share_image, format: false

  # R151: no judge code route; everyone gets the hackathon trial (plans.yml promo).
  resource :account, only: %i[show destroy]
  get "shows/search", to: "show_searches#show", as: :search_shows
  resources :shows, only: %i[index new create show edit update] do
    resources :reports, only: %i[create show]
    # show is the private preview (always available); the public page is /k/:slug.
    resource :media_kit, only: %i[show edit update] do
      patch :publish
      patch :unpublish
    end
    # create sends a code or issues a feed token; update checks the code or the feed.
    resource :verification, only: %i[new create show update]
  end
  get "k/:slug", to: "public_kits#show", as: :public_kit, format: false
  resources :sponsor_matches, only: :update do
    resource :pitch, only: %i[show create]
  end
  get "pipeline", to: "pipeline#index", as: :pipeline

  # The marketplace (build spec section 10): each lane draws its routes from its own file in config/routes/.
  draw(:catalog)
  draw(:claims)
  draw(:stats)
  draw(:brands)
  draw(:conversations)

  # Billing (Task 17): checkout and the customer portal through Billing::Provider, the founding-member waitlist, and
  # provider webhooks (an unknown provider is a 404).
  resources :checkouts, only: :create
  get "billing/success", to: "checkouts#success", as: :billing_success
  resource :billing_portal, only: :create
  resources :waitlist_entries, only: :create
  post "webhooks/:provider", to: "webhooks#create", as: :webhooks
  # The Fake billing provider's checkout and portal pages (FakeBillingController): development and test only.
  if Rails.env.local?
    get "fake_checkout", to: "fake_billing#checkout", as: :fake_checkout
    post "fake_checkout", to: "fake_billing#pay"
    get "fake_portal", to: "fake_billing#portal", as: :fake_portal
  end

  # Admin (Task 18, R68): the dashboard and Mission Control Jobs, both behind Admin::BaseController (a signed-in admin
  # plus HTTP basic auth; a 404 for anyone else, and for everyone when ADMIN_USERNAME or ADMIN_PASSWORD is unset).
  namespace :admin do
    root to: "dashboard#index"
    resources :users, only: :index
    # Masquerade (R150): an admin signs in as a user to see what they see. create is admin-only; destroy (the banner's
    # button) is guarded by the session marker instead, since current_user is the other user while it runs.
    resource :masquerade, only: %i[create destroy]
    resource :settings, only: :update
    resource :pause, only: %i[create destroy]
  end
  mount MissionControl::Jobs::Engine, at: "/admin/jobs"

  # Design system gallery and sent mail (letter_opener_web). Development only: production has no such routes.
  if Rails.env.development?
    get "styleguide" => "styleguide#show", as: :styleguide
    mount LetterOpenerWeb::Engine, at: "/letter_opener" if defined?(LetterOpenerWeb) # a development-group gem
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
