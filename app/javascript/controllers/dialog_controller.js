import { Controller } from "@hotwired/stimulus"

// Drives a native <dialog> (see app/views/components/_dialog.html.erb).
// showModal() gives us Escape-to-close and a focus trap: the page behind
// becomes inert. On top of that we return focus to the opener, close on a
// backdrop click, and close before Turbo caches the page.
export default class extends Controller {
  static targets = ["dialog"]
  static values = { open: Boolean }

  connect() {
    this.dialogTarget.addEventListener("close", this.restoreFocus)
    this.dialogTarget.addEventListener("click", this.closeOnBackdrop)
    document.addEventListener("turbo:before-cache", this.close)
    if (this.openValue) this.open()
  }

  disconnect() {
    this.dialogTarget.removeEventListener("close", this.restoreFocus)
    this.dialogTarget.removeEventListener("click", this.closeOnBackdrop)
    document.removeEventListener("turbo:before-cache", this.close)
  }

  open(event) {
    if (this.dialogTarget.open) return
    this.opener = event?.currentTarget ?? document.activeElement
    this.dialogTarget.showModal()
  }

  // Also runs for Escape, which the browser turns into a "close" event.
  close = () => {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  restoreFocus = () => {
    if (this.opener?.isConnected) this.opener.focus()
    this.opener = null
  }

  // A click whose target is the <dialog> itself, outside its box, landed on the backdrop.
  // Keyboard-triggered clicks report (0, 0) but never target the dialog, so they pass through.
  closeOnBackdrop = (event) => {
    if (event.target !== this.dialogTarget) return
    const box = this.dialogTarget.getBoundingClientRect()
    const inside = event.clientX >= box.left && event.clientX <= box.right &&
      event.clientY >= box.top && event.clientY <= box.bottom
    if (!inside) this.close()
  }
}
