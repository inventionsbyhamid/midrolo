# Lane L8's view helpers (build spec section 10: one module per lane, match_ prefix): a report's shows with a similar
# audience and the sponsor proof on its matches, and the podcast page's Audience section and Qloo similar shows, both
# read from the show's latest report (Podcast#taste_report), never from Qloo on a page view.
module MatchingHelper
  PAGE_SIMILAR_LIMIT = 6
  BRAND_CATEGORY_LIMIT = 5
  # Brands named under each similar show in the report.
  SHOW_SPONSOR_NAMES = 3
  # Brands listed under "Brands that already sponsor shows like yours", the most proven first.
  TOP_SPONSORS = 8

  # ---- The report ----

  # Whether this page may show a report's Qloo similar shows: always on the owner's report, and on a public sample only
  # to a signed-in person (build spec section 10). A broadcast renders the owner's report, so it never asks who's in.
  def match_similar_visible?(read_only) = !read_only || match_signed_in?

  # Whether a person is signed in. A render outside a request (ApplicationController.render) has no session, so it
  # counts as a visitor.
  def match_signed_in?
    user_signed_in?
  rescue Devise::MissingWarden
    false
  end

  # The report's similar shows and their sponsors (Matching::SimilarShows), once per report per render: the similar
  # section and every match row's proof read it.
  def match_similar_shows(report)
    @match_similar_shows ||= {}
    @match_similar_shows[report.id] ||= Matching::SimilarShows.for(report)
  end

  # This match's brand among the brands that sponsor shows like this one (a Matching::SimilarShows::Sponsor), or nil.
  # The matches section asks for its report's similar shows before its rows, so a row adds no queries; a row rendered on
  # its own shows no proof.
  def match_proof(match)
    @match_similar_shows&.dig(match.report_id)&.proof_for(match)
  end

  # The row's evidence chips (ReportsHelper#evidence_chips) with the proof second, still at most MAX_CHIPS.
  def match_evidence_chips(match, read_only)
    chips = evidence_chips(match)
    proof = match_proof(match)
    chips.insert([ chips.size, 1 ].min, match_proof_line(proof, read_only)) if proof
    chips.first(ReportsHelper::MAX_CHIPS)
  end

  # "Sponsors 3 shows with your audience" ("this audience" on a public sample).
  def match_proof_line(proof, read_only)
    "Sponsors #{pluralize(proof.podcasts.size, 'show')} with #{read_only ? 'this' : 'your'} audience"
  end

  def match_proven?(match) = proven_sponsor?(match) || match_proof(match).present?

  # Where a podcast's or a brand's public page is (lane L3's /podcasts/:slug and /brands/:slug).
  def match_podcast_path(podcast) = podcast_path(podcast)

  def match_brand_path(brand) = public_brand_path(brand.slug)

  # The podcast's title linked to its page.
  def match_podcast_link(podcast) = link_to(podcast.title, match_podcast_path(podcast), class: "link")

  # "Sponsored by A, B and C" for a similar show, linked to the brands' pages; nil with none.
  def match_show_sponsors(item)
    names = item.brands.first(SHOW_SPONSOR_NAMES).map { |brand| link_to(brand.name, match_brand_path(brand), class: "link") }
    more = item.brands.size - names.size
    names << "#{more} more" if more.positive?
    safe_join([ "Sponsored by ", and_list(names) ]) if names.any?
  end

  # ---- The podcast page ----

  # The podcast's latest owner or sample report (Podcast#taste_report), once per podcast per render: the Audience
  # section and the similar shows both read it.
  def match_taste_report(podcast)
    @match_taste_reports ||= {}
    return @match_taste_reports[podcast.id] if @match_taste_reports.key?(podcast.id)

    @match_taste_reports[podcast.id] = podcast.taste_report
  end

  # The sidebar's similar shows: those the catalog has first (each with its page), in Qloo's order.
  def match_page_similar(report)
    match_similar_shows(report).items.each_with_index.sort_by { |item, index| [ item.podcast ? 0 : 1, index ] }
                               .map(&:first).first(PAGE_SIMILAR_LIMIT)
  end

  # The report's audience lists as ReportsHelper#audience_groups gives them, without the brands its show's kit hides.
  def match_audience_groups(report)
    hidden = Array(report.show.media_kit&.hidden_brand_ids).map(&:to_s)
    audience_groups(report.audience).map do |key, label, items|
      [ key, label, key == "brands" ? items.reject { |item| hidden.include?(item["id"].to_s) } : items ]
    end.select { |_, _, items| items.any? }
  end

  # The brand categories a full report's matches come from most, the commonest first (a Snapshot locks most of its
  # matches, so it has none to show). One query.
  def match_brand_categories(report)
    return [] unless report.agent?

    SponsorMatch.where(report_id: report.id).where.not(category: [ nil, "" ]).group(:category)
                .order(Arel.sql("COUNT(*) DESC"), :category).limit(BRAND_CATEGORY_LIMIT).count.keys
                .filter_map { |name| category_label(name) }
  end

  # The report's age and gender leans, when it has any.
  def match_leans(report)
    leans = report.demographics
    leans if leans.is_a?(Hash) && (leans["age"].present? || leans["gender"].present?)
  end

  # Where the section's data came from: "From the show's Midrolo report, Oct 28." or "From a Midrolo sample report, ...".
  def match_report_source(report)
    from = report.show.verified? ? "the show's #{APP_NAME} report" : "a #{APP_NAME} sample report"
    date = report.finished_at || report.updated_at
    "From #{from}, #{date.year == Time.current.year ? date.strftime('%b %-d') : date.strftime('%b %-d, %Y')}."
  end
end
