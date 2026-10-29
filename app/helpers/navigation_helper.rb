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

  # Signed in, one nav per side (review G-2), with the side switch (components/_side_switch) beside it:
  #   podcaster  Podcasts, Your shows, Inbox with its unread count, Account; the podcaster's workspace (layouts/app)
  #              adds Pipeline after Your shows
  #   brand      Dashboard, Find podcasts, Saved, Inbox with the brand side's unread count, Podcasts, Account
  # side defaults to nav_side: the side the person last worked on.
  def nav_member_links(pipeline: false, user: (current_user if user_signed_in?), side: nil)
    return nav_visitor_links unless user
    return nav_brand_links(user) if (side || nav_side(user)) == :brand

    [ [ "Podcasts", podcasts_path ], [ "Your shows", shows_path ], ([ "Pipeline", pipeline_path ] if pipeline),
      [ "Inbox", inbox_path, inbox_unread_count(user) ], [ "Account", account_path ] ].compact
  end

  def nav_brand_links(user)
    [ [ "Dashboard", brand_root_path ], [ "Find podcasts", new_brand_search_path ], [ "Saved", brand_saved_podcasts_path ],
      [ "Inbox", brand_inbox_path, inbox_unread_count(user, side: :brand) ], [ "Podcasts", podcasts_path ],
      [ "Account", account_path ] ]
  end

  # :brand when the person last worked as a brand (User#last_role) and still belongs to one, else :podcaster.
  def nav_side(user = current_user)
    user&.last_role == "brand" && user.brand_member? ? :brand : :podcaster
  end

  # aria-current for one of the nav's links (review G-4): "page" on its own page, "true" for the one link whose
  # section holds this page. Only the closest section is marked, so /brand/inbox marks Inbox, not also Dashboard; a
  # link to a "new" page owns its section (Find podcasts marks every search page).
  def nav_current_in(href, hrefs)
    return "page" if current_page?(href)
    return nil unless nav_section_of?(href)

    best = hrefs.select { |other| nav_section_of?(other) }.max_by { |other| nav_section(other).length }
    "true" if best == href
  end

  # The marketing layout's links: the visitor's, or the member's once signed in.
  def nav_site_links = user_signed_in? ? nav_member_links : nav_visitor_links

  # "/brand/searches/new" stands for "/brand/searches".
  def nav_section(href) = href.to_s.delete_suffix("/new")

  def nav_section_of?(href)
    section = nav_section(href)
    section.start_with?("/") && !section.include?("#") && section != "/" &&
      (request.path == section || request.path.start_with?("#{section}/"))
  end

  # "Inbox" with its count: a badge for the eye and "3 unread" for a screen reader. Plain text without a count.
  def nav_label(label, count = nil)
    return label unless count.to_i.positive?

    safe_join([ label, tag.span(count > 99 ? "99+" : count.to_s, class: "nav-count", aria: { hidden: true }),
                tag.span("#{count} unread", class: "sr-only") ], " ")
  end
end
