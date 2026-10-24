import { Controller } from "@hotwired/stimulus"

// Client-side filtering and sorting of the sponsor match cards.
//   chip targets: toggle buttons (aria-pressed) with data-group ("category", "tier" or "proven") and data-value.
//     Pressed chips in one group widen the match (any of them); groups narrow it (all of them).
//   item targets: the cards, with data-category, data-tier, data-tier-rank, data-proven, data-fit, data-position.
//   sort target: a <select> with "fit" (server order) or "tier" (easiest to land first, then fit).
// State lives in the DOM (aria-pressed, the select), so a page-refresh morph that resets it stays consistent.
export default class extends Controller {
  static targets = ["chip", "item", "list", "sort", "status", "empty", "clear"]

  connect() {
    this.resync = () => { this.sort(); this.apply() }
    window.addEventListener("turbo:morph", this.resync)
    this.apply()
  }

  disconnect() {
    window.removeEventListener("turbo:morph", this.resync)
  }

  toggle(event) {
    const chip = event.currentTarget
    chip.setAttribute("aria-pressed", chip.getAttribute("aria-pressed") === "true" ? "false" : "true")
    this.apply()
  }

  clear() {
    this.chipTargets.forEach((chip) => chip.setAttribute("aria-pressed", "false"))
    this.apply()
  }

  sort() {
    if (!this.hasListTarget) return

    const byTier = this.hasSortTarget && this.sortTarget.value === "tier"
    const number = (item, key) => Number(item.dataset[key]) || 0
    const ordered = [...this.itemTargets].sort((a, b) =>
      byTier
        ? number(a, "tierRank") - number(b, "tierRank") || number(b, "fit") - number(a, "fit") || number(a, "position") - number(b, "position")
        : number(a, "position") - number(b, "position"))
    this.listTarget.append(...ordered)
  }

  apply() {
    const categories = this.pressed("category")
    const tiers = this.pressed("tier")
    const provenOnly = this.pressed("proven").length > 0

    let shown = 0
    this.itemTargets.forEach((item) => {
      const visible = (categories.length === 0 || categories.includes(item.dataset.category)) &&
        (tiers.length === 0 || tiers.includes(item.dataset.tier)) &&
        (!provenOnly || item.dataset.proven === "true")
      item.hidden = !visible
      if (visible) shown += 1
    })

    const total = this.itemTargets.length
    const filtering = categories.length + tiers.length > 0 || provenOnly
    if (this.hasStatusTarget) this.statusTarget.textContent = `Showing ${shown} of ${total}`
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
    if (this.hasClearTarget) this.clearTarget.hidden = !filtering
  }

  pressed(group) {
    return this.chipTargets
      .filter((chip) => chip.dataset.group === group && chip.getAttribute("aria-pressed") === "true")
      .map((chip) => chip.dataset.value)
  }
}
