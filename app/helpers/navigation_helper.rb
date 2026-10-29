# The site header's links (lane L9), for components/_nav. A link is [label, href], or [label, href, count] for a link
# that shows how many things wait behind it (the Inbox's unread conversations). Every method starts with nav_.
module NavigationHelper
  # Where "For brands" goes: the landing page's brand section.
  FOR_BRANDS_PATH = "/#for-brands".freeze

  # Visitors: Podcasts, For brands, Blog (once a post is published, R148) and Pricing.
  def nav_visitor_links
    [ [ "Podcasts", podcasts_path ], [ "For brands", FOR_BRANDS_PATH ], ([ "Blog", blog_path ] if blog_listed?),
      [ "Pricing", pricing_path ] ].compact
  end

  # Signed in: Podcasts, Your shows, Inbox with its unread count, Brand for a brand's member, and Account. The
  # podcaster's workspace (layouts/app) adds Pipeline after Your shows.
  def nav_member_links(pipeline: false, user: (current_user if user_signed_in?))
    return nav_visitor_links unless user

    [ [ "Podcasts", podcasts_path ], [ "Your shows", shows_path ], ([ "Pipeline", pipeline_path ] if pipeline),
      [ "Inbox", inbox_path, inbox_unread_count(user) ], ([ "Brand", brand_root_path ] if user.brand_member?),
      [ "Account", account_path ] ].compact
  end

  # The marketing layout's links: the visitor's, or the member's once signed in.
  def nav_site_links = user_signed_in? ? nav_member_links : nav_visitor_links

  # "Inbox" with its count: a badge for the eye and "3 unread" for a screen reader. Plain text without a count.
  def nav_label(label, count = nil)
    return label unless count.to_i.positive?

    safe_join([ label, tag.span(count > 99 ? "99+" : count.to_s, class: "nav-count", aria: { hidden: true }),
                tag.span("#{count} unread", class: "sr-only") ], " ")
  end
end
