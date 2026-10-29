# The Midrolo logo (app/assets/images/brand): the lockup or the mark alone, for light or dark backgrounds, as an
# SVG <img> sized by height. email: true gives the lockup's PNG copy (bin/rails brand:build) at an absolute URL instead,
# because many mail clients block SVG and a message has no page to resolve a path against.
module BrandHelper
  VARIANTS = { logo: BrandMark::LOGO_RATIO, mark: 1 }.freeze
  TONES = { light: "", dark: "-dark" }.freeze
  HEIGHTS = { sm: 20, md: 28, lg: 40 }.freeze
  EMAIL_STYLE = "display:block;border:0;outline:none;".freeze

  def brand_logo(variant: :logo, tone: :light, size: :md, email: false, alt: APP_NAME, **options)
    height = HEIGHTS.fetch(size)
    width = (height * VARIANTS.fetch(variant)).round
    suffix = TONES.fetch(tone)
    options = options.merge(alt: alt, width: width, height: height)
    if email
      image_tag(image_url("brand/logo-email.png", host: root_url), **options, style: EMAIL_STYLE)
    else
      image_tag("brand/#{variant}#{suffix}.svg", **options, class: class_names("brand-logo", options[:class]))
    end
  end
end
