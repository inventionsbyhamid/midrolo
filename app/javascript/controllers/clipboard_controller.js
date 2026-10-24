import { Controller } from "@hotwired/stimulus"

// Copies the source target's text (or an input's value) and shows "Copied"
// on the label target for 2 seconds.
//
//   <div data-controller="clipboard">
//     <pre data-clipboard-target="source">...</pre>
//     <button type="button" data-action="clipboard#copy">
//       <span data-clipboard-target="label" aria-live="polite">Copy email</span>
//     </button>
//   </div>
export default class extends Controller {
  static targets = ["source", "label"]
  static values = { copiedText: { type: String, default: "Copied" } }

  disconnect() {
    clearTimeout(this.timer)
  }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.text)
    } catch {
      this.selectSource() // no clipboard access (old browser, http): leave it selected for Ctrl+C
      return
    }
    this.showCopied()
  }

  get text() {
    const source = this.sourceTarget
    const isField = source instanceof HTMLInputElement || source instanceof HTMLTextAreaElement
    return isField ? source.value : source.innerText.trim()
  }

  showCopied() {
    if (!this.hasLabelTarget) return
    this.originalLabel ??= this.labelTarget.textContent
    this.labelTarget.textContent = this.copiedTextValue
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.reset(), 2000)
  }

  reset() {
    this.labelTarget.textContent = this.originalLabel
  }

  selectSource() {
    const source = this.sourceTarget
    if (source.select) return source.select()
    const range = document.createRange()
    range.selectNodeContents(source)
    window.getSelection().removeAllRanges()
    window.getSelection().addRange(range)
  }
}
