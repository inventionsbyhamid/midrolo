module Research
  module Tools
    # The audience profile (AudienceProfile), then the shows with a similar audience (SimilarPodcasts, build spec L8):
    # once a run, and again only when what it asks Qloo with changes (a proxy profile rebuilt from other seeds), since the
    # same question gets the same answer.
    class BuildAudienceProfile < Base
      calls_qloo!

      SIMILAR_NAMES = 5

      description "Builds the audience profile for a seed set (the saved seeds when no ids are given): top " \
                  "#{AudienceProfile::TYPES.map { |type| AudienceProfile::NOUNS.fetch(type) }.join(', ')}, taste tags, " \
                  "age and gender leans and where listeners live, and finds the shows with a similar audience. Saves " \
                  "those report sections and returns a digest. It says when the profile is thin."
      arguments({ entity_ids: string_array("Seed entity ids; leave empty to use the saved seeds"),
                  tag_ids: string_array("Seed tag ids; leave empty to use the saved seeds") })

      def execute(entity_ids: [], tag_ids: [])
        entity_ids, tag_ids, ignored = seed_ids(entity_ids, tag_ids)
        return "#{ignored_note(ignored)}#{NO_SEEDS}" if entity_ids.empty? && tag_ids.empty?

        profile = AudienceProfile.build(toolkit, seed_entity_ids: entity_ids, seed_tag_ids: tag_ids, country: show.country)
        "#{ignored_note(ignored)}#{profile[:digest]}#{similar_note(similar_podcasts)}"
      end

      private

      def similar_podcasts
        signals = SimilarPodcasts.signals(toolkit)
        return nil if signals.nil? || signals == @similar_signals

        @similar_signals = signals
        SimilarPodcasts.call(toolkit)
      end

      def similar_note(entries)
        return "" if entries.blank?

        "\nShows with a similar audience (saved): #{entries.first(SIMILAR_NAMES).map { |e| e["name"] }.join(', ')}"
      end
    end
  end
end
