# Someone who asked to buy a plan while billing is in waitlist mode (spec §11), once per email and price key: the
# founding-member list we email when paid plans open. Task 18 adds entries with Billing::NOTIFY_KEY.
class WaitlistEntry < ApplicationRecord
  belongs_to :user, optional: true

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, message: "Enter a valid email address." },
                    length: { maximum: 254 }
  validates :price_key, inclusion: { in: ->(_entry) { Billing.waitlist_keys }, message: "Pick a plan to join the waitlist for." }

  # Adds email to the list for price_key, or finds it there already: a repeat, in any case, is a friendly no-op. A
  # signed-in user is linked to the entry. Returns the entry, unsaved with errors when invalid.
  def self.join(email:, price_key:, user: nil)
    entry = create_or_find_by(email: email, price_key: price_key) { |new_entry| new_entry.user = user }
    entry.update!(user: user) if entry.persisted? && user && entry.user_id.nil?
    entry
  end
end
