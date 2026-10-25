module Entitlements
  # A user's work counted against their plan, by kind (:snapshot, :agent or :pitch). done counts finished work only:
  # a failed or needs_input report and a failed pitch never use quota. in_flight counts fresh work still queued or
  # running (not stale), which gates reserve (R53, R61). Quotas are per user, across all their shows. No user, no usage.
  class Usage
    def initialize(user)
      @user = user
    end

    # Done since a time (or all time), and for reports optionally only those of one spend bucket.
    def done(kind, since: nil, bucket: nil)
      scope = kind == :pitch ? pitches.counted : reports(kind, bucket).done
      scope = scope.where(created_at: since..) if since
      scope.count
    end

    def in_flight(kind, bucket: nil)
      (kind == :pitch ? pitches.in_flight : reports(kind, bucket).live).count
    end

    private

    def reports(kind, bucket)
      return Report.none unless @user

      scope = Report.where(show_id: @user.shows.select(:id), kind: kind.to_s)
      bucket ? scope.where(spend_bucket: bucket.to_s) : scope
    end

    def pitches
      return Pitch.none unless @user

      Pitch.where(sponsor_match_id: SponsorMatch.where(show_id: @user.shows.select(:id)).select(:id))
    end
  end
end
