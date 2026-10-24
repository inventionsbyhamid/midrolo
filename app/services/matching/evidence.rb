module Matching
  # Reads proven evidence ({items: [{show:, episode_title:, published_at:}], count:}) in either form:
  # symbol keys and Times in memory, or string keys and ISO time strings after a jsonb round trip (R34).
  module Evidence
    module_function

    def items(evidence) = Array(value(evidence, :items))

    def count(evidence) = value(evidence, :count).to_i

    def published_at(item)
      time = value(item, :published_at)
      time.is_a?(String) ? Time.zone.parse(time) : time
    rescue ArgumentError
      nil
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
