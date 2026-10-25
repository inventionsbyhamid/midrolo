require "rails_helper"

RSpec.describe BrandHelper do
  def img(html) = Nokogiri::HTML5.fragment(html).at_css("img")

  it "draws the logo lockup as an SVG image, sized by height" do
    logo = img(helper.brand_logo)

    expect(logo["src"]).to match(%r{\A/assets/brand/logo-\h+\.svg\z})
    expect(logo["alt"]).to eq("Midrolo")
    expect(logo["height"]).to eq("28")
    expect(logo["width"]).to eq("136")
    expect(logo["class"].split).to include("brand-logo")
  end

  it "draws the mark alone, square, and the dark-background variants" do
    mark = img(helper.brand_logo(variant: :mark, size: :sm, tone: :dark, alt: ""))

    expect(mark["src"]).to match(%r{\A/assets/brand/mark-dark-\h+\.svg\z})
    expect(mark["alt"]).to eq("")
    expect([ mark["width"], mark["height"] ]).to eq(%w[20 20])
    expect(img(helper.brand_logo(tone: :dark))["src"]).to match(%r{/assets/brand/logo-dark-\h+\.svg\z})
  end

  it "passes extra classes and attributes through" do
    logo = img(helper.brand_logo(size: :lg, class: "mx-auto", data: { test: "x" }))

    expect(logo["class"].split).to include("brand-logo", "mx-auto")
    expect(logo["data-test"]).to eq("x")
    expect(logo["height"]).to eq("40")
  end

  it "rejects an unknown variant, tone or size" do
    expect { helper.brand_logo(variant: :wordmark) }.to raise_error(KeyError)
    expect { helper.brand_logo(tone: :sepia) }.to raise_error(KeyError)
    expect { helper.brand_logo(size: :xl) }.to raise_error(KeyError)
  end

  it "gives email a PNG at an absolute URL, since many mail clients block SVG" do
    logo = img(helper.brand_logo(email: true))

    expect(logo["src"]).to match(%r{\Ahttp://test\.host/assets/brand/logo-email-\h+\.png\z})
    expect([ logo["width"], logo["height"] ]).to eq(%w[136 28])
    expect(logo["alt"]).to eq("Midrolo")
    expect(logo["style"]).to include("display:block")
  end
end
