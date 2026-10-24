module Pipeline
  # Which copy of a brand counts (R46, R46a, R48). Re-runs copy each brand onto every new report of a show, and for
  # each show and brand the copy on the newest report counts, with two exceptions:
  # - A copy the plan locks (a Snapshot match past visible_matches_limit, R43) never counts, so a locked brand never
  #   reaches the pipeline or its CSV, and a visible older copy counts instead. The limit is read when the query
  #   runs, so this follows plan changes.
  # - A suggested copy counts only once its report is done, so a re-run in progress (its matches not yet carried
  #   forward) doesn't hide the podcaster's work.
  # The pipeline lists the copies that count past "suggested"; carry-forward copies from them; a report card is
  # editable only when no copy on a newer report counts.
  class Matches
    REPORT_AGE = "(sponsor_matches.report_created_at, sponsor_matches.report_id)".freeze

    # The pipeline page and its CSV: soonest follow-up first (none last), then fit.
    def self.for(user) = new(user).pipeline

    # Brand id => the copy that counts, for those of report's brands whose copy that counts is on a newer report.
    def self.newer_copies(report, brand_entity_ids: nil)
      copies(report, brand_entity_ids).where("#{REPORT_AGE} > (?, ?)", report.created_at, report.id).index_by(&:brand_entity_id)
    end

    # Brand id => the copy that counts among the show's reports before this one.
    def self.earlier_copies(report, brand_entity_ids: nil)
      copies(report, brand_entity_ids).where("#{REPORT_AGE} < (?, ?)", report.created_at, report.id).index_by(&:brand_entity_id)
    end

    # Filtering on report age before the DISTINCT ON keeps the newest eligible copy on that side of the report: the
    # copy that counts when it lies there, and nothing (for newer_copies) when it doesn't.
    def self.copies(report, brand_entity_ids)
      latest = new(report.show.user, show: report.show).latest
      brand_entity_ids ? latest.where(brand_entity_id: brand_entity_ids) : latest
    end
    private_class_method :copies

    def initialize(user, show: nil)
      @user = user
      @show = show
    end

    def pipeline
      table = SponsorMatch.arel_table
      SponsorMatch.from(latest, :sponsor_matches)
                  .where.not(status: "suggested")
                  .includes(:show)
                  .order(table[:follow_up_on].asc.nulls_last, table[:fit_score].desc.nulls_last, :name, :id)
    end

    # The copy that counts for each show and brand, whatever its status.
    def latest
      SponsorMatch.from(ranked, :sponsor_matches)
                  .where(SponsorMatch.unlocked_sql(Entitlements.for(@user).visible_matches_limit))
                  .where("sponsor_matches.status <> 'suggested' OR sponsor_matches.report_status = 'done'")
                  .select("DISTINCT ON (sponsor_matches.show_id, sponsor_matches.brand_entity_id) sponsor_matches.*")
                  .order(Arel.sql("sponsor_matches.show_id, sponsor_matches.brand_entity_id, " \
                                  "sponsor_matches.report_created_at DESC, sponsor_matches.report_id DESC"))
    end

    private

    # Every match on the user's shows (or the one show) with its report's kind, status and age, and its rank in its
    # report. Ranked before any other filter, so each report is counted whole.
    def ranked
      shows = @show ? [ @show.id ] : @user.shows.select(:id)
      SponsorMatch.joins(:report).where(show_id: shows)
                  .select("sponsor_matches.*", "reports.kind AS report_kind", "reports.status AS report_status",
                          "reports.created_at AS report_created_at", "#{SponsorMatch::REPORT_RANK_SQL} AS report_rank")
    end
  end
end
