# An earlier slug of a podcast (a renamed show, an old /k/:slug kit link), answered with a 301 to its page.
class PodcastRedirect < ApplicationRecord
  belongs_to :podcast

  validates :from_slug, presence: true, uniqueness: true
end
