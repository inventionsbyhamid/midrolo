require "rails_helper"

# The blog (R148) in a real browser, at phone and desktop widths, with the fixture posts: nothing scrolls sideways (a
# post's table scrolls in its own box), headings go down one level at a time, every image is labelled, text meets WCAG
# AA contrast, the table of contents jumps to its section and the focus ring shows on a post card. SCREENSHOTS=1 saves
# a full-page screenshot of each to tmp/screenshots/blog (kept out of git).
RSpec.describe "Blog pages", :blog_posts do
  let(:widths) { { "375" => [ 375, 812 ], "1440" => [ 1440, 900 ] } }
  let(:pages) do
    { "index" => "/blog", "post" => "/blog/finding-your-first-sponsor", "short-post" => "/blog/what-to-charge-for-a-midroll" }
  end

  around { |example| Capybara.using_wait_time(10) { example.run } }

  def screenshot(name, width)
    return if ENV["SCREENSHOTS"].blank?

    dir = Rails.root.join("tmp/screenshots/blog")
    FileUtils.mkdir_p(dir)
    page.save_screenshot(dir.join("#{name}-#{width}.png").to_s, full: true)
  end

  it "lays out the index and the posts at 375px and 1440px with ordered headings, labelled images and AA contrast",
     :aggregate_failures do
    pages.each do |name, path|
      widths.each do |width, (w, h)|
        page.driver.resize(w, h)
        visit path
        at = "#{path} at #{width}px"

        expect(page).to have_css("h1")
        expect(horizontal_overflow).to eq(0), "#{at} scrolls sideways"
        expect(heading_levels.count(1)).to eq(1), "#{at} has #{heading_levels.count(1)} h1s"
        expect(skipped_heading_levels).to be_empty, "#{at} skips #{skipped_heading_levels.join(', ')}"
        expect(unlabelled_images).to be_empty, "#{at}: #{unlabelled_images.join('; ')}"
        expect(contrast_failures).to be_empty, "#{at}: #{contrast_failures.join('; ')}"
        screenshot(name, width)
      end
    end
  end

  it "jumps to a section from the table of contents" do
    page.driver.resize(1440, 900)
    visit "/blog/finding-your-first-sponsor"

    within("nav.post-toc") { click_link "Follow up once" }

    expect(evaluate_script("location.hash")).to eq("#follow-up-once")
    top = evaluate_script("document.getElementById('follow-up-once').getBoundingClientRect().top")
    expect(top).to be_between(0, 200)
  end

  it "shows the focus ring on a post card when its link is tabbed to" do
    visit "/blog"
    30.times do
      break if evaluate_script("document.activeElement.classList.contains('post-card-link')")

      page.driver.browser.keyboard.type(:tab)
    end

    expect(evaluate_script("document.activeElement.classList.contains('post-card-link')")).to be(true)
    expect(evaluate_script("getComputedStyle(document.activeElement.closest('.post-card')).outlineStyle")).to eq("solid")
  end
end
