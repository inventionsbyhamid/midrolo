import { Controller } from "@hotwired/stimulus"

// Filtering and sorting of the sponsor match rows (reports/sections/_matches).
//   list targets: the top list, then the rest inside the Show all <details> (the more target). Sorting keeps the
//     top list at its first size and puts the rest after it.
//   toolbar target: the filters. They need JS, so they start hidden and show only while the full list is open;
//     closing it clears them.
//   chip targets: toggle buttons (aria-pressed) with data-group ("tier" or "proven") and data-value. Pressed chips
//     in one group widen the match (any of them); groups narrow it (all of them).
//   category target: a <select> of categories, "" for all of them.
//   item targets: the rows, with data-category, data-tier, data-tier-rank, data-proven, data-fit, data-position.
//   sort target: a <select> with "fit" (server order) or "tier" (easiest to land first, then fit).
// A link to a row inside the closed full list (#sponsor_match_12, from the pipeline) opens it.
// State lives in the DOM (aria-pressed, the selects, details[open]), so a page-refresh morph that resets it stays
// consistent.
export default class extends Controller {
  static targets = ["chip", "item", "list", "sort", "category", "status", "empty", "clear", "toolbar", "more"]

  connect() {
    this.topSize = this.hasListTarget ? this.listTargets[0].children.length : 0
    this.resync = () => { this.expanded(); this.sort(); this.apply() }
    this.reveal = () => this.revealHash()
    window.addEventListener("turbo:morph", this.resync)
    window.addEventListener("hashchange", this.reveal)
    this.revealHash()
    this.expanded()
    this.apply()
  }

  disconnect() {
    window.removeEventListener("turbo:morph", this.resync)
    window.removeEventListener("hashchange", this.reveal)
  }

  // The full list opened or closed (its toggle event): show the filters, or put them back as they started.
  expanded() {
    if (!this.hasMoreTarget) return

    const open = this.moreTarget.open
    if (this.hasToolbarTarget) this.toolbarTarget.hidden = !open
    if (!open) this.reset()
  }

  toggle(event) {
    const chip = event.currentTarget
    chip.setAttribute("aria-pressed", chip.getAttribute("aria-pressed") === "true" ? "false" : "true")
    this.apply()
  }

  clear() {
    this.chipTargets.forEach((chip) => chip.setAttribute("aria-pressed", "false"))
    if (this.hasCategoryTarget) this.categoryTarget.value = ""
    this.apply()
  }

  reset() {
    if (this.hasSortTarget && this.sortTarget.value !== "fit") {
      this.sortTarget.value = "fit"
      this.sort()
    }
    this.clear()
  }

  sort() {
    if (!this.hasListTarget) return

    const byTier = this.hasSortTarget && this.sortTarget.value === "tier"
    const number = (item, key) => Number(item.dataset[key]) || 0
    const ordered = [...this.itemTargets].sort((a, b) =>
      byTier
        ? number(a, "tierRank") - number(b, "tierRank") || number(b, "fit") - number(a, "fit") || number(a, "position") - number(b, "position")
        : number(a, "position") - number(b, "position"))
    const lists = this.listTargets
    if (lists.length === 1) {
      lists[0].append(...ordered)
    } else {
      lists[0].append(...ordered.slice(0, this.topSize))
      lists[lists.length - 1].append(...ordered.slice(this.topSize))
    }
  }

  apply() {
    const category = this.hasCategoryTarget ? this.categoryTarget.value : ""
    const tiers = this.pressed("tier")
    const provenOnly = this.pressed("proven").length > 0

    let shown = 0
    this.itemTargets.forEach((item) => {
      const visible = (category === "" || item.dataset.category === category) &&
        (tiers.length === 0 || tiers.includes(item.dataset.tier)) &&
        (!provenOnly || item.dataset.proven === "true")
      item.hidden = !visible
      if (visible) shown += 1
    })

    const total = this.itemTargets.length
    const filtering = category !== "" || tiers.length > 0 || provenOnly
    if (this.hasStatusTarget) this.statusTarget.textContent = `Showing ${shown} of ${total}`
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
    if (this.hasClearTarget) this.clearTarget.hidden = !filtering
  }

  pressed(group) {
    return this.chipTargets
      .filter((chip) => chip.dataset.group === group && chip.getAttribute("aria-pressed") === "true")
      .map((chip) => chip.dataset.value)
  }

  // Opens the full list when the URL points at a row inside it.
  revealHash() {
    if (!this.hasMoreTarget || this.moreTarget.open) return

    const id = decodeURIComponent(window.location.hash.slice(1))
    const target = id && document.getElementById(id)
    if (target && this.moreTarget.contains(target)) {
      this.moreTarget.open = true
      target.scrollIntoView()
    }
  }
}
