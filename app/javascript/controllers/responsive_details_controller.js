import { Controller } from "@hotwired/stimulus"

// A <details> rendered open server-side (so it is usable without JS and on desktop).
// On small screens it starts collapsed.
export default class extends Controller {
  static values = { minWidth: { type: Number, default: 1024 } }

  connect() {
    if (!window.matchMedia(`(min-width: ${this.minWidthValue}px)`).matches) this.element.removeAttribute("open")
  }
}
