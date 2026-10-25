import { Controller } from "@hotwired/stimulus"

// The media kit's "Print or save as PDF" button. What prints is decided by the @media print rules in kit.css.
// A closed <details> (See all tastes) prints closed, so every one in the kit opens for printing, however it was
// started (this button or the browser's own Print), and closes again after.
export default class extends Controller {
  connect() {
    this.expand = () => {
      this.opened = [...document.querySelectorAll(".kit-sheet details:not([open])")]
      this.opened.forEach((details) => { details.open = true })
    }
    this.restore = () => {
      this.opened?.forEach((details) => { details.open = false })
      this.opened = []
    }
    window.addEventListener("beforeprint", this.expand)
    window.addEventListener("afterprint", this.restore)
  }

  disconnect() {
    window.removeEventListener("beforeprint", this.expand)
    window.removeEventListener("afterprint", this.restore)
  }

  print() {
    window.print()
  }
}
