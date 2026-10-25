# The public pages (Task 19, R78): the landing page (for everyone; signed-in visitors get "Go to my shows" in the
# header), pricing, about, privacy, terms, the sitemap and robots.txt. Nothing here needs a session.
class PagesController < ApplicationController
  layout "marketing"

  def home
    @samples = Samples.reports
    @match_counts = Samples.match_counts(@samples)
    @hero_sample = @samples.first
    @hero_matches = @hero_sample ? @hero_sample.sponsor_matches.first(3) : []
  end

  def pricing; end
  def about; end
  def privacy; end
  def terms; end

  def robots; end

  def sitemap
    @samples = Samples.reports
    @kit_slugs = Show.with_public_kit.order(:slug).pluck(:slug)
  end

  private

  # Landing and legal pages must open for anyone, in any browser (a link in an email, a crawler).
  def any_browser? = true
end
