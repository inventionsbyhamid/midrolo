# A random, URL-safe id for the routes (R147): to_param returns it, so every path helper puts it in the URL instead of
# the database id, which would leak how many records there are and invite guessing. Controllers find records with
# find_by!(public_id:), scoped to the signed-in user as before. The database id stays the key for everything else.
module HasPublicId
  extend ActiveSupport::Concern

  included do
    before_validation :assign_public_id, on: :create
  end

  def to_param = public_id

  # dom_id and Turbo's stream targets build element ids from this, so a page's anchors (#sponsor_match_3f9a…) don't
  # show the database id either. Nil for a new record, as Active Record's own.
  def to_key = (new_record? ? nil : [ public_id ])

  private

  # 16 hex characters, as the migration gave existing rows; the unique index has the last word.
  def assign_public_id
    self.public_id ||= SecureRandom.hex(8)
  end
end
