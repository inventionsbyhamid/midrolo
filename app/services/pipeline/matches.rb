module Pipeline
  # The podcaster's pipeline (R46): every brand moved past "suggested" on any of their shows, one entry per show and
  # brand. Re-runs copy a brand onto each new report, so the copy on the newest report that has it is the one that
  # counts, and moving it back to "suggested" there takes it off the pipeline. A suggested copy counts only once its
  # report is done, so a re-run in progress (its matches not yet carried forward) doesn't empty the pipeline.
  # Ordered by follow-up date (soonest first, none last), then fit.
  class Matches
    def self.for(user) = new(user).relation

    def initialize(user)
      @user = user
    end

    def relation
      matches = SponsorMatch.arel_table
      SponsorMatch.from(latest_per_brand, :sponsor_matches)
                  .where.not(status: "suggested")
                  .includes(:show)
                  .order(matches[:follow_up_on].asc.nulls_last, matches[:fit_score].desc.nulls_last, :name, :id)
    end

    private

    def latest_per_brand
      mine = SponsorMatch.joins(:report).where(show_id: @user.shows.select(:id))
      mine.where.not(status: "suggested").or(mine.where(reports: { status: "done" }))
          .select("DISTINCT ON (sponsor_matches.show_id, sponsor_matches.brand_entity_id) sponsor_matches.*")
          .order("sponsor_matches.show_id", "sponsor_matches.brand_entity_id",
                 Report.arel_table[:created_at].desc, Report.arel_table[:id].desc)
    end
  end
end
