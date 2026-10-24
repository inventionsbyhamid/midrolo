module Research
  module Tools
    class SaveTasteSeeds < Base
      SOURCE_LIMIT = 80
      AGENT_SOURCE = "Picked by the research agent".freeze

      description "Saves the taste seeds the report is built on: #{Seeds::MAX_ENTITIES} entity ids at most and " \
                  "#{Seeds::MAX_TAGS} tag ids at most (aim for 3–8 and 2–5), from find_on_qloo, each with where it came " \
                  "from. profile_kind is direct when this show itself is a seed, otherwise proxy. Ids no tool returned " \
                  "are rejected. Saving again replaces the seeds."
      arguments({ entity_ids: string_array("Qloo entity ids from find_on_qloo"),
                  tag_ids: string_array("Qloo tag ids from find_on_qloo"),
                  sources: { type: "object", additionalProperties: { type: "string" },
                             description: "Seed id => where it came from, e.g. \"guest in Ep. 112\" or \"you listed it\"" },
                  profile_kind: { type: "string", enum: %w[direct proxy] } },
                required: %i[entity_ids tag_ids profile_kind])

      def execute(entity_ids: [], tag_ids: [], profile_kind: "proxy", sources: {})
        entity_ids = strings(entity_ids)
        tag_ids = strings(tag_ids)
        log.step("save_taste_seeds", "Saving your taste profile…", input: "#{entity_ids.size} entity and #{tag_ids.size} tag ids") do |step|
          entities, unknown_entities = entity_ids.partition { |id| toolkit.entity(id) }
          tags, unknown_tags = tag_ids.partition { |id| toolkit.tag(id) }
          @rejected = unknown_entities + unknown_tags
          @entities = entities.map { |id| toolkit.entity(id) }.first(Seeds::MAX_ENTITIES)
          @tags = tags.map { |id| toolkit.tag(id) }.first(Seeds::MAX_TAGS)
          @sources = sources.is_a?(Hash) ? sources.transform_keys(&:to_s) : {}
          @kind = profile_kind.to_s == "direct" && own_show_seed? ? "direct" : "proxy"
          save
          toolkit.last_seed_save = { saved: seed_count, rejected: @rejected.size }
          step.warn!("Rejected #{@rejected.size} unknown #{'id'.pluralize(@rejected.size)}") if @rejected.any?
          step.warn!("Fewer than 2 seeds") if seed_count < 2
          step.output_summary = "#{@entities.size} entity and #{@tags.size} tag seeds (#{@kind} profile)"
          message(profile_kind.to_s)
        end
      end

      private

      def seed_count = @entities.size + @tags.size

      def save
        toolkit.seeds = { entities: @entities, tags: @tags }
        report.update!(profile_kind: @kind)
        report.save_section!(:seeds, {
          "entities" => @entities.map { |e| { "id" => e.id, "name" => e.name, "type" => e.type.to_s, "source" => source(e.id) } },
          "tags" => @tags.map { |t| { "id" => t.id, "name" => t.name, "source" => source(t.id) } },
          "unresolved" => toolkit.unresolved
        })
      end

      def source(id)
        (@sources[id].to_s.squish.presence || toolkit.lookup_sources[id] || AGENT_SOURCE).truncate(SOURCE_LIMIT)
      end

      # The show itself on Qloo: the entity the podcaster linked, or a podcast with the show's name.
      def own_show_seed?
        @entities.any? do |e|
          (show.qloo_entity_id.present? && e.id == show.qloo_entity_id) ||
            toolkit.lookup_sources[e.id] == Seeds::SHOW_SOURCE ||
            (e.type == :podcast && Names.same?(e.name, show.title))
        end
      end

      def message(asked)
        text = "Saved #{@entities.size} entity and #{@tags.size} tag seeds (#{@kind} profile)"
        text += "; rejected #{@rejected.size} #{'id'.pluralize(@rejected.size)} no tool returned: #{@rejected.join(', ')}" if @rejected.any?
        text += "."
        text += " Labeled proxy: this show itself isn't among the seeds." if asked == "direct" && @kind == "proxy"
        text += " Fewer than 2 seeds: the report will ask the podcaster for comparable shows." if seed_count < 2
        text
      end
    end
  end
end
