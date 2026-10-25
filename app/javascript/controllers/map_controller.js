import { Controller } from "@hotwired/stimulus"

// The "where your kind of listener lives" heatmap. MapLibre (~1 MB) and its stylesheet (the stylesheet value, the
// pinned version's CSS) load only when the map nears the viewport, so nothing about the map blocks first paint. Points are [{lat, lng, affinity}]; affinity weights the heat. If MapLibre can't load, WebGL is
// missing, or an error leaves the map unrendered a few seconds later (the style failed), the figure hides
// itself and the server-rendered "Top places" line above it stands alone.
const ERROR_GRACE_MS = 6000
const STYLESHEET_WAIT_MS = 3000

// The ramp runs from the page's plum to the tally amber, so the hottest spot glows like the live lamp.
const HEAT_COLORS = [
  "interpolate", ["linear"], ["heatmap-density"],
  0, "rgba(74, 34, 102, 0)",
  0.15, "rgba(196, 170, 214, 0.55)",
  0.4, "rgba(122, 72, 156, 0.75)",
  0.7, "rgba(74, 34, 102, 0.88)",
  0.9, "rgba(214, 131, 30, 0.92)",
  1, "rgba(243, 167, 18, 0.96)"
]

export default class extends Controller {
  static targets = ["canvas", "status"]
  static values = { points: Array, style: String, stylesheet: String }

  connect() {
    if (this.pointsValue.length === 0) return

    if ("IntersectionObserver" in window) {
      this.observer = new IntersectionObserver((entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return
        this.observer.disconnect()
        this.load()
      }, { rootMargin: "400px 0px" })
      this.observer.observe(this.element)
    } else {
      this.load()
    }
  }

  disconnect() {
    this.observer?.disconnect()
    clearTimeout(this.errorTimer)
    this.errorTimer = null
    this.map?.remove()
    this.map = null
  }

  async load() {
    try {
      const [{ Map: MapLibreMap, NavigationControl, LngLatBounds }] = await Promise.all([import("maplibre-gl"), this.linkStylesheet()])
      if (!this.element.isConnected || this.map) return

      this.ready = false
      this.failed = false
      const bounds = this.pointsValue.reduce((box, p) => box.extend([p.lng, p.lat]), new LngLatBounds())
      this.canvasTarget.replaceChildren() // a restored Turbo snapshot may carry a dead copy of the last map
      this.map = new MapLibreMap({
        container: this.canvasTarget,
        style: this.styleValue,
        bounds,
        fitBoundsOptions: { padding: 40, maxZoom: 8 },
        attributionControl: { compact: true },
        cooperativeGestures: true,
        dragRotate: false,
        pitchWithRotate: false,
        touchPitch: false
      })
      this.map.addControl(new NavigationControl({ showCompass: false }), "top-right")
      // A missing sprite or tile still renders; a failed style never does.
      this.map.on("error", (event) => {
        if (this.ready || this.errorTimer) return
        this.errorTimer = setTimeout(() => { if (!this.ready) this.fail(event.error) }, ERROR_GRACE_MS)
      })
      this.map.on("load", () => this.draw())
    } catch (error) {
      this.fail(error)
    }
  }

  // Adds the MapLibre stylesheet once per page and waits for it briefly; the map still works if it never comes.
  linkStylesheet() {
    if (!this.stylesheetValue) return Promise.resolve()

    let link = [...document.querySelectorAll("link[rel=stylesheet]")].find((l) => l.href === this.stylesheetValue)
    if (link?.sheet) return Promise.resolve()

    if (!link) {
      link = Object.assign(document.createElement("link"), { rel: "stylesheet", href: this.stylesheetValue, crossOrigin: "anonymous" })
      document.head.append(link)
    }
    return new Promise((resolve) => {
      const done = () => { clearTimeout(timer); resolve() }
      const timer = setTimeout(done, STYLESHEET_WAIT_MS)
      link.addEventListener("load", done, { once: true })
      link.addEventListener("error", done, { once: true })
    })
  }

  draw() {
    this.ready = true
    this.map.addSource("listeners", {
      type: "geojson",
      data: {
        type: "FeatureCollection",
        features: this.pointsValue.map((p) => ({
          type: "Feature",
          properties: { affinity: Number(p.affinity) || 0 },
          geometry: { type: "Point", coordinates: [p.lng, p.lat] }
        }))
      }
    })
    this.map.addLayer({
      id: "listeners-heat",
      type: "heatmap",
      source: "listeners",
      paint: {
        "heatmap-weight": ["interpolate", ["linear"], ["get", "affinity"], 0, 0, 1, 1],
        "heatmap-intensity": ["interpolate", ["linear"], ["zoom"], 2, 0.8, 9, 2.5],
        "heatmap-radius": ["interpolate", ["linear"], ["zoom"], 2, 14, 5, 24, 9, 40],
        "heatmap-opacity": 0.9,
        "heatmap-color": HEAT_COLORS
      }
    })
    if (this.hasStatusTarget) this.statusTarget.hidden = true
    // On a phone the expanded credits cover a third of the map; the (i) button still opens them.
    if (this.element.clientWidth < 480) this.element.querySelector(".maplibregl-compact-show")?.classList.remove("maplibregl-compact-show")
  }

  fail(error) {
    if (this.failed) return

    this.failed = true
    console.warn("Midrolo: the map couldn't load, showing the top places in words instead.", error)
    this.map?.remove()
    this.map = null
    this.element.hidden = true
  }
}
