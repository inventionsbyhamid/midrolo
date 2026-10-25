# Fonts for the share images (ShareImages), which libvips draws from SVG: librsvg sets each <text> with Pango, and
# ShareImages::Renderer measures text with vips_text, also Pango. Pango finds fonts through fontconfig, so point
# fontconfig at the Archivo cuts bundled in vendor/fonts (its fonts.conf also includes the system's config, for fallback
# glyphs). On macOS Pango would ask Core Text instead, which can't see them, so ask for its fontconfig backend; that is
# already the only one on Linux. Both are read when the process first draws text, so they're set at boot.
#
# This renders the same on a Mac (Homebrew vips) and in a Debian container (libvips42 pulls in librsvg, Pango and
# fontconfig), with no system font install. A container that installs the fonts itself can set its own
# FONTCONFIG_FILE: neither variable is overridden.
ENV["FONTCONFIG_FILE"] ||= Rails.root.join("vendor/fonts/fonts.conf").to_s
ENV["PANGOCAIRO_BACKEND"] ||= "fc"
