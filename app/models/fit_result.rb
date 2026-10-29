# One podcast a fit search found, scored 0 to 100 (taste 50%, proof 25%, price 15%, trust 10%), with the reasons and
# proof the results page shows.
class FitResult < ApplicationRecord
  belongs_to :fit_search, inverse_of: :results
  belongs_to :podcast

  validates :podcast_id, uniqueness: { scope: :fit_search_id }
  validates :score, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
end
