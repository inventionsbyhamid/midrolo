# Someone who asked to buy a plan while billing is in waitlist mode (spec §11), once per email and price key: the
# founding-member list we email when paid plans open. Task 18 adds entries with Billing::NOTIFY_KEY.
class WaitlistEntry < ApplicationRecord
  belongs_to :user, optional: true

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, message: "Enter a valid email address." },
                    length: { maximum: 254 }
  validates :price_key, inclusion: { in: ->(_entry) { Billing.waitlist_keys }, message: "Pick a plan to join the waitlist for." }

  # The notify list (Billing::NOTIFY_KEY) not yet told that new runs are back (RunsResumedMailJob, R81).
  scope :awaiting_notice, -> { where(price_key: Billing::NOTIFY_KEY, notified_at: nil) }

  # Adds email to the list for price_key, or finds it there already: a repeat, in any case, is a friendly no-op. A
  # signed-in user is linked to the entry, and a notify entry already told about one resume waits for the next one.
  # Returns the entry, unsaved with errors when invalid.
  def self.join(email:, price_key:, user: nil)
    entry = create_or_find_by(email: email, price_key: price_key) { |new_entry| new_entry.user = user }
    return entry unless entry.persisted?

    entry.user = user if user && entry.user_id.nil?
    entry.notified_at = nil if entry.price_key == Billing::NOTIFY_KEY
    entry.save! if entry.changed?
    entry
  end
end
