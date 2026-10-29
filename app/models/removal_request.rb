# "Remove this page": a request to take a podcast out of the catalog. The owner's own request removes it at once; an
# admin decides the rest.
class RemovalRequest < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze
  REASON_LIMIT = 2000

  belongs_to :podcast

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :reason, length: { maximum: REASON_LIMIT }
end
