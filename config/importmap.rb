# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# MapLibre GL for the report heatmap: one exact version from jsdelivr's ESM build (it loads its shared chunk and
# worker from the same folder). Not preloaded: map_controller imports it only when a map scrolls into view.
# map_controller links the matching stylesheet from the same folder (ReportsHelper#maplibre_stylesheet_url).
pin "maplibre-gl", to: "https://cdn.jsdelivr.net/npm/maplibre-gl@6.12.0/dist/maplibre-gl.mjs", preload: false
