import { Controller } from "@hotwired/stimulus"

// The media kit's "Print or save as PDF" button. What prints is decided by the @media print rules in kit.css.
export default class extends Controller {
  print() {
    window.print()
  }
}
