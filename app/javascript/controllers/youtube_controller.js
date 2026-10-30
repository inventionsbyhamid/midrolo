import { Controller } from "@hotwired/stimulus"

// A YouTube video that loads nothing from YouTube until it's played (see app/views/components/_youtube.html.erb).
// The page holds a link to the video on YouTube, for visitors without JavaScript; this turns it into a play button
// that swaps in the privacy-enhanced player, playing, and moves focus into it. The player goes again before Turbo
// caches the page, so coming back shows the poster rather than starting the video over.
export default class extends Controller {
  static targets = ["play"]
  static values = { src: String, title: String, label: String }

  connect() {
    if (this.playTarget instanceof HTMLAnchorElement) this.playTarget.replaceWith(this.button(this.playTarget))
    document.addEventListener("turbo:before-cache", this.reset)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.reset)
  }

  play() {
    if (this.frame) return
    this.frame = document.createElement("iframe")
    this.frame.className = "video-frame"
    this.frame.src = this.srcValue
    this.frame.title = this.titleValue
    this.frame.allow = "autoplay; encrypted-media; picture-in-picture"
    this.frame.allowFullscreen = true
    this.frame.referrerPolicy = "strict-origin-when-cross-origin" // the player won't start without the page's origin
    this.playTarget.hidden = true
    this.element.append(this.frame)
    this.frame.focus()
  }

  reset = () => {
    this.frame?.remove()
    this.frame = null
    this.playTarget.hidden = false
  }

  // The link's poster and caption, on a button.
  button(link) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = link.className
    button.setAttribute("aria-label", this.labelValue)
    button.dataset.youtubeTarget = "play"
    button.dataset.action = "youtube#play"
    button.append(...link.childNodes)
    return button
  }
}
