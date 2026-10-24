module Research
  module Tools
    class BuildAudienceProfile < Base
      description "Builds the audience profile for a seed set (the saved seeds when no ids are given): top brands, " \
                  "artists, TV shows, podcasts, taste tags, age and gender leans and where listeners live. Saves those " \
                  "report sections and returns a digest. It says when the profile is thin."
      arguments({ entity_ids: string_array("Seed entity ids; leave empty to use the saved seeds"),
                  tag_ids: string_array("Seed tag ids; leave empty to use the saved seeds") })

      def execute(entity_ids: [], tag_ids: [])
        entity_ids, tag_ids, ignored = seed_ids(entity_ids, tag_ids)
        return "#{ignored_note(ignored)}#{NO_SEEDS}" if entity_ids.empty? && tag_ids.empty?

        profile = AudienceProfile.build(toolkit, seed_entity_ids: entity_ids, seed_tag_ids: tag_ids, country: show.country)
        "#{ignored_note(ignored)}#{profile[:digest]}"
      end
    end
  end
end
