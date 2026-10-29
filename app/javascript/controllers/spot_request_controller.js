import { Controller } from "@hotwired/stimulus"

// Request a spot (review BR-12): picking a slot from the show's rate card puts its price in the budget when the budget
// is empty or still holds the last slot's price, and a budget under the picked slot's price gets a soft note. The
// request still sends either way: the show decides.
export default class extends Controller {
  static targets = ["budget", "note"]

  connect() {
    this.check()
  }

  pick(event) {
    const price = event.target.dataset.price
    if (price && (this.budgetTarget.value === "" || this.budgetTarget.value === this.filled)) {
      this.budgetTarget.value = price
      this.filled = price
    }
    this.check()
  }

  check() {
    if (!this.hasNoteTarget || !this.hasBudgetTarget) return

    const slot = this.element.querySelector("input[type=radio][data-price]:checked")
    const price = slot ? Number(slot.dataset.price) : NaN
    const budget = Number(this.budgetTarget.value.replace(/[^0-9.]/g, ""))
    const under = this.budgetTarget.value.trim() !== "" && price > 0 && budget < price
    this.noteTarget.hidden = !under
    this.noteTarget.textContent = under ? `That's under their ${slot.dataset.label.toLowerCase()} price of $${price}. You can still ask.` : ""
  }
}
