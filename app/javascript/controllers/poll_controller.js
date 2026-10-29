import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Waits on something the server is still making (a show being added to the catalog), without a socket: after delay,
// loads url into the closest <turbo-frame>. The answer replaces this element, and carries a new poll only while there is
// more to wait for, so polling stops by itself. With visit set, reloads the whole page at once instead (the thing it
// waited for is ready).
//
//   <turbo-frame id="adding_podcasts">
//     ...
//     <div data-controller="poll" data-poll-url-value="/podcasts/adding?ids=a,b&n=2" hidden></div>
//   </turbo-frame>
export default class extends Controller {
  static values = { url: String, delay: { type: Number, default: 3000 }, visit: Boolean }

  connect() {
    if (this.visitValue) {
      Turbo.visit(window.location.href, { action: "replace" })
      return
    }
    this.timer = setTimeout(() => this.load(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  load() {
    const frame = this.element.closest("turbo-frame")
    if (frame && this.urlValue) frame.src = this.urlValue
  }
}
