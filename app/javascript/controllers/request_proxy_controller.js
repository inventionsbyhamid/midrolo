import { Controller } from "@hotwired/stimulus"

// A second "Request a spot" (the podcast page's sidebar) that works the page's one real control in the hero
// (podcasts/_request: a dialog opener for a brand member, a link otherwise). It shows only when that control exists,
// and takes its label ("Request a spot", "Open your request"), so both buttons always say the same thing.
export default class extends Controller {
  connect() {
    const control = this.control()
    if (!control) return
    this.element.textContent = control.textContent.trim()
    this.element.hidden = false
  }

  open(event) {
    const control = this.control()
    if (!control) return
    event.preventDefault()
    control.click()
  }

  control() {
    return document.querySelector("#request :is(a[href], button)")
  }
}
