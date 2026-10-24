import { Controller } from "@hotwired/stimulus"

// WAI-ARIA tabs: role="tab" buttons (tab targets) control role="tabpanel" panels (panel targets) in the same
// order. Arrow keys, Home and End move between tabs; only the selected tab is in the tab order.
// The server renders the first tab selected. A page-refresh morph resets that, so the choice is restored after it.
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.index = Math.max(0, this.tabTargets.findIndex((tab) => tab.getAttribute("aria-selected") === "true"))
    this.restore = () => this.show(this.index)
    window.addEventListener("turbo:morph", this.restore)
  }

  disconnect() {
    window.removeEventListener("turbo:morph", this.restore)
  }

  select(event) {
    this.show(this.tabTargets.indexOf(event.currentTarget))
  }

  navigate(event) {
    const last = this.tabTargets.length - 1
    const moves = { ArrowRight: this.index + 1, ArrowLeft: this.index - 1, Home: 0, End: last }
    if (!(event.key in moves)) return

    event.preventDefault()
    const next = (moves[event.key] + this.tabTargets.length) % this.tabTargets.length
    this.show(next)
    this.tabTargets[next].focus()
  }

  show(index) {
    if (index < 0 || index >= this.tabTargets.length) return

    this.index = index
    this.tabTargets.forEach((tab, i) => {
      tab.setAttribute("aria-selected", i === index ? "true" : "false")
      tab.tabIndex = i === index ? 0 : -1
    })
    this.panelTargets.forEach((panel, i) => { panel.hidden = i !== index })
  }
}
