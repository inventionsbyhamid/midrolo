module Catalog
  # The one way to turn a Qloo podcast entity into a catalog podcast (L1's seed, L6's fit search and L8's similar shows
  # all use it): the podcast already linked to the entity, or nil. Lane L1 adds matching by title (Podcast#title_key)
  # and author through the directory.
  class QlooMatch
    def self.call(entity) = new(entity).call

    def initialize(entity)
      @entity = entity
    end

    def call
      id = @entity.respond_to?(:id) ? @entity.id : @entity
      Podcast.find_by(qloo_entity_id: id.to_s) if id.present?
    end
  end
end
