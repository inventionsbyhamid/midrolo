module Research
  module Tools
    class FindOnQloo < Base
      calls_qloo!

      MAX_NAMES = Seeds::MAX_LOOKUP_NAMES
      MAX_TOPICS = Seeds::MAX_LOOKUP_TOPICS

      description "Looks names and topics up on Qloo: up to #{MAX_NAMES} names (this show, comparable shows, guests, " \
                  "artists, brands) and up to #{MAX_TOPICS} topic phrases. Returns the matching Qloo entities and taste " \
                  "tags with their ids, for use as seeds."
      arguments({ names: string_array("Shows, people, artists or brands to find", max: MAX_NAMES),
                  topics: string_array("Topic phrases to match to taste tags", max: MAX_TOPICS) })

      def execute(names: [], topics: [])
        names = strings(names).first(MAX_NAMES)
        topics = strings(topics).first(MAX_TOPICS)
        return "Give at least one name or topic to look up." if names.empty? && topics.empty?

        result = Seeds.from_lookup(toolkit, names: names, topics: topics)
        toolkit.record_lookup(result)
        digest(result)
      end

      private

      def digest(result)
        if result[:entities].empty? && result[:tags].empty?
          return "Nothing matched on Qloo for #{Untrusted.wrap((result[:unresolved].presence || [ 'those' ]).join(', '))}. " \
                 "Try other names (comparable shows, guests) or broader topics."
        end

        sources = result[:sources]
        lines = []
        lines << "Entities:" if result[:entities].any?
        result[:entities].each { |e| lines << "- #{e.name} (#{e.id}) #{e.type.to_s.tr('_', ' ')}: #{sources[e.id]}" }
        lines << "Tags:" if result[:tags].any?
        result[:tags].each { |t| lines << "- #{t.name} (#{t.id}): #{sources[t.id]}" }
        lines << "Not found: #{Untrusted.wrap(result[:unresolved].join(', '))}" if result[:unresolved].any?
        lines.join("\n")
      end
    end
  end
end
