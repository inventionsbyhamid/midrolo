class User < ApplicationRecord
  # Omniauth-only Devise: no passwords. Google (or the development strategy) mints the session.
  devise :omniauthable, :rememberable, :trackable, omniauth_providers: Devise.omniauth_configs.keys

  has_many :shows, dependent: :destroy
  has_many :sponsor_matches, through: :shows
  has_many :pitches, through: :sponsor_matches
  has_many :subscriptions, dependent: :destroy
  has_many :waitlist_entries, dependent: :destroy

  # The owner of the public sample reports (Samples::Generate, R78). It has no provider or uid, so no OmniAuth sign-in
  # can match it (a Google account with this email can't take the address either), and Devise refuses it a session.
  SAMPLES_EMAIL = "samples@midrolo.com".freeze

  validates :provider, :uid, presence: true, unless: :samples_owner?
  validates :email, uniqueness: { case_sensitive: false }, allow_nil: true

  def self.from_omniauth(auth)
    user = find_or_initialize_by(provider: auth.provider.to_s, uid: auth.uid.to_s)
    user.email = auth.info.email.presence || user.email
    user.name = auth.info.name.presence || user.name
    user.avatar_url = auth.info.image.presence || user.avatar_url
    user.save!
    user
  end

  def samples_owner? = email == SAMPLES_EMAIL && provider.nil?

  # Devise checks this for every session, a remembered one included.
  def active_for_authentication? = super && !samples_owner?

  def initials
    source = name.presence || email.to_s
    letters = source.split.first(2).map { |word| word[0] }.join
    letters.upcase.presence || "?"
  end
end
