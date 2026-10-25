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

  # Temporary: Task 19 replaces this with pages#home.
  root to: redirect("/shows")
  # Temporary: Task 19 replaces this with pages#pricing.
  get "pricing", to: redirect("/account"), as: :pricing

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
