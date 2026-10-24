module Matching
  # proven_evidence items are Hashes with symbol keys {show:, episode_title:, published_at: Time}.
  Candidate = Data.define(:entity, :affinity, :proven_evidence, :shared_tag_count, :category_match)
end
