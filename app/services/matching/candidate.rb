module Matching
  # proven_evidence is {items: [...], count: Integer}: items are the 3 most recent sponsor reads, newest first,
  # each a symbol-keyed Hash {show:, episode_title:, published_at: Time}; count is every read found.
  Candidate = Data.define(:entity, :affinity, :proven_evidence, :shared_tag_count, :category_match)
  Candidate::NO_EVIDENCE = { items: [].freeze, count: 0 }.freeze
end
