import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Closes the gap between rendering something still in progress and its Turbo Stream subscription going live: each
// time the <turbo-cable-stream-source> inside connects (the first time, and after a dropped connection), fetch the
// current state once from url, a Turbo Stream response. A broadcast sent before the subscription existed is caught
// this way; later ones arrive on the stream.
//
//   <div data-controller="stream-catchup" data-stream-catchup-url-value="/sponsor_matches/1/pitch?pitch_id=2">
//     <turbo-cable-stream-source ...></turbo-cable-stream-source>
//     <div id="pitch_2">...</div>
//   </div>
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.source = this.element.querySelector("turbo-cable-stream-source")
    if (!this.source) return

    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.source, { attributes: true, attributeFilter: ["connected"] })
    this.sync()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  async sync() {
    if (!this.source.hasAttribute("connected")) return

    const response = await fetch(this.urlValue, { headers: { Accept: "text/vnd.turbo-stream.html" } })
    if (response.ok && this.element.isConnected) Turbo.renderStreamMessage(await response.text())
  }
}
