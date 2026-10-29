class FitSearch
  # Starts a brand member's fit search: checks the kill switch, the member's daily searches (User::Brands) and, for a
  # free or promo account, its share of today's Qloo calls, then saves the search and queues FitSearchJob. Raises
  # Refused with a message the brand can read; ActiveRecord::RecordInvalid for bad input.
  class Start
    PAUSED_MESSAGE = "Searches are paused right now. Try again later.".freeze

    class Refused < StandardError; end

    def self.call(...) = new(...).call

    # attributes: query, website, categories, budget (whole dollars per episode, or blank).
    def initialize(member:, attributes:)
      @member = member
      @user = member.user
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      raise Refused, PAUSED_MESSAGE if AppSettings.runs_paused?
      raise Refused, daily_limit_message if @user.brand_searches_today >= @user.brand_daily_search_limit(@member)
      raise Refused, Run::FREE_BUSY_MESSAGE if Entitlements.for(@user).capped_taste? && Taste::CallGuard.new.capped_spent?

      search = FitSearch.create!(user: @user, brand: @member.brand, query: @attributes[:query].to_s.squish,
                                 website: website, categories: Categories.known(@attributes[:categories]),
                                 budget_cents: budget_cents, status: "queued")
      FitSearchJob.perform_later(search.id)
      search
    end

    private

    def website
      value = @attributes[:website].to_s.strip.first(200)
      Brand.normalize_domain(value) ? value : @member.brand.domain
    end

    # Whole dollars per episode; blank, zero or junk means no budget.
    def budget_cents
      dollars = Integer(@attributes[:budget].to_s.delete(",$ ").presence || "0", 10)
      dollars.positive? ? [ dollars, 1_000_000 ].min * 100 : nil
    rescue ArgumentError
      nil
    end

    def daily_limit_message
      limit = @user.brand_daily_search_limit(@member)
      more = @member.verified? ? "" : " Verify your work email to run more."
      "You've run #{limit} searches in the last 24 hours, the most a day.#{more}"
    end
  end
end
