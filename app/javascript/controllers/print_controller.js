import { Controller } from "@hotwired/stimulus"

// The media kit's "Print or save as PDF" button. What prints is decided by the @media print rules in kit.css, which
// need no JS: every taste list prints from a print-only copy.
export default class extends Controller {
  print() {
    window.print()
  }
}
