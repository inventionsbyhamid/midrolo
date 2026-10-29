class User < ApplicationRecord
  # Omniauth-only Devise: no passwords. Google (or the development strategy) mints the session.
  devise :omniauthable, :rememberable, :trackable, omniauth_providers: Devise.omniauth_configs.keys

  include Brands

  has_many :shows, dependent: :destroy
  has_many :sponsor_matches, through: :shows
  has_many :pitches, through: :sponsor_matches
  has_many :subscriptions, dependent: :destroy
  has_many :waitlist_entries, dependent: :destroy
  # The brand side (build spec section 10): memberships and searches are the user's and go with the account; what
  # other people see (messages, conversations started, saved shows, stats connections) stays, unlinked.
  has_many :brand_members, dependent: :destroy
  has_many :brands, through: :brand_members
  has_many :fit_searches, dependent: :destroy
  has_many :messages, dependent: :nullify
  has_many :started_conversations, class_name: "Conversation", foreign_key: :started_by_id, inverse_of: :started_by,
                                   dependent: :nullify
  has_many :saved_podcasts, dependent: :nullify
  has_many :stat_connections, dependent: :nullify

  # Which side the account used last, so sign in lands there (ApplicationController#after_sign_in_path_for).
  LAST_ROLES = %w[podcaster brand].freeze

  # The owner of the public sample reports (Samples::Generate, R78). It has no provider or uid, so no OmniAuth sign-in
  # can match it (a Google account with this email can't take the address either), and Devise refuses it a session.
  SAMPLES_EMAIL = "samples@midrolo.com".freeze

  validates :provider, :uid, presence: true, unless: :samples_owner?
  validates :email, uniqueness: { case_sensitive: false }, allow_nil: true
  validates :last_role, inclusion: { in: LAST_ROLES }, allow_nil: true

  def self.from_omniauth(auth)
    user = find_or_initialize_by(provider: auth.provider.to_s, uid: auth.uid.to_s)
    user.email = auth.info.email.presence || user.email
    user.name = auth.info.name.presence || user.name
    user.avatar_url = auth.info.image.presence || user.avatar_url
    user.save!
    user
  end

  def samples_owner? = email == SAMPLES_EMAIL && provider.nil?

  # A plan the provider will charge again (R132): the account can't be deleted until it's cancelled.
  def renewing_subscription? = subscriptions.renewing.exists?

  # Devise checks this for every session, a remembered one included.
  def active_for_authentication? = super && !samples_owner?

  def initials
    source = name.presence || email.to_s
    letters = source.split.first(2).map { |word| word[0] }.join
    letters.upcase.presence || "?"
  end
end
