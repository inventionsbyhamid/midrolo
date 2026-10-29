module Sponsors
  # Puts brands.sponsor_mentions_count right for every brand whose count drifted. Sponsors::Record recounts the brands a
  # scan touches, but deleting a podcast or an episode removes its mentions with delete_all, which skips the counter
  # cache (code review L9). One UPDATE; returns how many brands it corrected. The daily sponsors sweep
  # (Sponsors::SweepJob) runs it, and so does `bin/rails sponsors:recount`.
  module Recount
    module_function

    def call
      Brand.connection.update(<<~SQL.squish, "Sponsors::Recount")
        UPDATE brands SET sponsor_mentions_count = counts.mentions, updated_at = CURRENT_TIMESTAMP
        FROM (
          SELECT brands.id, COUNT(sponsor_mentions.id) AS mentions FROM brands
          LEFT JOIN sponsor_mentions ON sponsor_mentions.brand_id = brands.id
          GROUP BY brands.id
        ) AS counts
        WHERE counts.id = brands.id AND brands.sponsor_mentions_count <> counts.mentions
      SQL
    end
  end
end
