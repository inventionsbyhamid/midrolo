import { Controller } from "@hotwired/stimulus"

// Submits the form shortly after the user stops typing, for live search.
//
//   <form data-controller="autosubmit" data-autosubmit-delay-value="300">
//     <input type="search" data-action="input->autosubmit#queue">
//   </form>
//
// Enter submits immediately (the form's normal behaviour) and cancels any pending submit.
export default class extends Controller {
  static values = { delay: { type: Number, default: 300 } }

  disconnect() {
    clearTimeout(this.timer)
  }

  queue() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.requestSubmit(), this.delayValue)
  }

  submit() {
    clearTimeout(this.timer)
  }
}
