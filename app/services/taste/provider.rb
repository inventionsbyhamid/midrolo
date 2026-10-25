module Taste
  # Adapter interface (all return value objects, never raw JSON):
  #   #search(query:, types:, take: 5) (no results is []), #find_tags(query:, take: 10, types: []) (types: tag type
  #     URNs to keep to, exact matches; none means all),
  #   #recommend(type:, entity_ids: [], tag_ids: [], filter_tags: [], popularity_max: nil, take: 20),
  #   #affinity_for(candidate_ids:, entity_ids: [], tag_ids: [], type: :brand) -> Hash{String=>Float, nil}:
  #     every candidate id is a key; nil means no score (Qloo omitted it, or Fake knows it as another entity type),
  #   #taste_tags(entity_ids: [], tag_ids: [], take: 20),
  #   #demographics(entity_ids: [], tag_ids: []), #heatmap(location:, entity_ids: [], tag_ids: [], take: 50),
  #   #compare(a_entity_ids:, b_entity_ids:, take: 10)
  module Provider
    TYPE_URNS = {
      brand: "urn:entity:brand", artist: "urn:entity:artist", tv_show: "urn:entity:tv_show", podcast: "urn:entity:podcast",
      movie: "urn:entity:movie", book: "urn:entity:book", place: "urn:entity:place"
    }.freeze

    class << self
      def current
        @current ||= build
      end

      def reset!
        @current = nil
      end

      def fake?
        current.is_a?(Providers::Fake)
      end

      def urn_for(type)
        TYPE_URNS.fetch(type.to_sym) { raise ArgumentError, "unknown taste entity type: #{type.inspect}" }
      end

      def type_for(urn)
        TYPE_URNS.key(urn.to_s)
      end

      private

      # Never the live API from a spec, even with QLOO_API_KEY exported (R92): specs that exercise the Qloo adapter
      # build it themselves, against WebMock.
      def build
        return Providers::Fake.new if Rails.env.test?

        key = ENV["QLOO_API_KEY"].presence
        return Providers::Qloo.new(api_key: key) if key
        raise MissingCredentials, "Taste provider is not configured: set QLOO_API_KEY" if Rails.env.production?

        Providers::Fake.new
      end
    end
  end
end
