namespace :brand do
  desc "Draw the favicon set, the email logo and og.png from the brand SVGs with libvips (see lib/brand_build.rb)"
  task build: :environment do
    BrandBuild.call
    puts "Wrote public/icon.svg, favicon.ico, apple-touch-icon.png, icon-192.png, icon-512.png, " \
         "app/assets/images/brand/logo-email.png and app/assets/images/og.png"
  end
end
