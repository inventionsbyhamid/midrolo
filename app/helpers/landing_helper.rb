# The landing page's copy that depends on the day or on what's set (lane L9). Every method starts with landing_.
module LandingHelper
  # Audacy Creator Lab, the marketplace that began as Podcorn, closes on this day (research/podcorn-research.md).
  CREATOR_LAB_CLOSES = Date.new(2026, 11, 1)

  # "... closes November 1." until that day, "... closed November 1." from then on, so the line is never wrong.
  def landing_creator_lab_line(today = Date.current)
    verb = today >= CREATOR_LAB_CLOSES ? "closed" : "closes"
    "Audacy Creator Lab (formerly Podcorn) #{verb} #{CREATOR_LAB_CLOSES.strftime('%B %-d')}."
  end

  # What a brand gets while Midrolo is in its trial, from the limits the code enforces (User::Brands).
  def landing_brand_allowances
    searches = User::Brands::DAILY_SEARCHES
    requests = User::Brands::DAILY_REQUESTS
    [ "#{searches[:unverified]} fit searches a day, #{searches[:verified]} with a verified work email",
      "#{requests[:unverified]} requests a day, or #{requests[:verified]} once your work email is verified",
      "Save shows and message podcasters directly",
      "No commission on any deal" ]
  end

  # "1,034 podcasts", "2,310 sponsor reads", "412 brands": the catalog's counts, each left out at zero.
  def landing_catalog_facts(facts)
    { podcasts: "podcast", sponsor_reads: "sponsor read", brands: "brand" }.filter_map do |key, noun|
      count = facts[key].to_i
      "#{number_with_delimiter(count)} #{noun.pluralize(count)}" if count.positive?
    end
  end
end
