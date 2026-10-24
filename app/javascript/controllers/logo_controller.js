import { Controller } from "@hotwired/stimulus"

// A logo or artwork tile: the image sits over the initials, and an image that fails to load is removed so the
// initials show. Wired as data-action="error->logo#fallback" on the img, with no inline handler, so it survives a
// strict CSP. An image that already failed before Stimulus connected is caught when its target connects.
export default class extends Controller {
  static targets = ["image"]

  imageTargetConnected(image) {
    // decode() rejects for a broken image and resolves for a loaded one (SVGs without a size included).
    if (image.complete) image.decode().catch(() => image.remove())
  }

  fallback(event) {
    event.currentTarget.remove()
  }
}
