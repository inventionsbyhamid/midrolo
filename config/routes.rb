Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  devise_for :users,
             skip: %i[sessions registrations passwords confirmations unlocks],
             controllers: { omniauth_callbacks: "users/omniauth_callbacks" }
  devise_scope :user do
    get "users/sign_in", to: "devise/sessions#new", as: :new_user_session
    delete "users/sign_out", to: "devise/sessions#destroy", as: :destroy_user_session
  end

  # Public pages (Task 19, R78): the landing page for everyone, signed in or not, pricing, about and the legal pages,
  # the public sample reports and the sitemap. robots.txt is a static file in public/.
  root "pages#home"
  get "pricing", to: "pages#pricing", as: :pricing
  get "about", to: "pages#about", as: :about
  get "privacy", to: "pages#privacy", as: :privacy
  get "terms", to: "pages#terms", as: :terms
  get "sitemap.xml", to: "pages#sitemap", as: :sitemap, format: false, defaults: { format: "xml" }
  resources :samples, only: %i[index show], param: :slug, format: false

  resource :account, only: %i[show destroy] do
    post :judge_code
  end
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
    resource :settings, only: :update
    resource :pause, only: %i[create destroy]
  end
  mount MissionControl::Jobs::Engine, at: "/admin/jobs"

  # Design system gallery and sent mail (letter_opener_web). Development only: production has no such routes.
  if Rails.env.development?
    get "styleguide" => "styleguide#show", as: :styleguide
    mount LetterOpenerWeb::Engine, at: "/letter_opener" if defined?(LetterOpenerWeb) # a development-group gem
  end

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
