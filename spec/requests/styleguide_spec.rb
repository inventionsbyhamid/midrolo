require "rails_helper"

RSpec.describe "Styleguide" do
  def banner = "Demo mode — showing sample data (no API keys configured)."

  def layouts = %w[application marketing app kit print]

  # Everything the layout renders before <main>: the page chrome, not the styleguide body.
  def chrome_before_main = response.body.split('id="main"').first

  def draw_routes_as(env)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(env))
    Rails.application.reload_routes!
  end

  after do
    allow(Rails).to receive(:env).and_call_original
    Rails.application.reload_routes!
  end

  context "in development" do
    before { draw_routes_as("development") }

    it "renders every component" do
      get "/styleguide"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "btn-primary", "btn-secondary", "btn-ghost", "btn-danger",
        "badge-neutral", "badge-success", "badge-warning", "badge-danger", "badge-accent",
        'role="meter"', 'class="stat', 'class="card', 'class="empty-state', 'class="skeleton',
        'class="demo-banner', 'class="flash', 'data-controller="dialog"', 'data-controller="clipboard"'
      )
    end

    it "wraps every layout in the shared head, skip link and Podcast Index credit" do
      layouts.each do |layout|
        get "/styleguide", params: { layout: layout }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(
          '<meta name="viewport"', "fonts.googleapis.com", 'href="#main"', 'id="main"',
          "Podcast data from Podcast Index"
        ), "layout #{layout} is missing shared chrome"
      end
    end

    it "shows the demo banner in every layout only when demo mode is on" do
      original = Rails.configuration.x.demo_mode

      layouts.each do |layout|
        Rails.configuration.x.demo_mode = false
        get "/styleguide", params: { layout: layout }
        expect(chrome_before_main).not_to include(banner), "layout #{layout} shows the banner outside demo mode"

        Rails.configuration.x.demo_mode = true
        get "/styleguide", params: { layout: layout }
        expect(chrome_before_main).to include(banner), "layout #{layout} has no demo banner"
      end
    ensure
      Rails.configuration.x.demo_mode = original
    end

    it "puts the page's content_for(:meta) in the head instead of the default meta" do
      get "/styleguide"

      expect(response.body).to include('<meta property="og:description" content="Tokens, type and components for Midrolo.">')
      expect(response.body).not_to include(UiHelper::DEFAULT_DESCRIPTION)
    end
  end

  context "in production" do
    before { draw_routes_as("production") }

    it "is not routed" do
      get "/styleguide"

      expect(response).to have_http_status(:not_found)
    end
  end
end
