import { Controller } from "@hotwired/stimulus"

// Where YouTube's player connects first, as lite-youtube-embed warms them: the player's page, the scripts it fetches
// from google.com, its images and the ad hosts it checks. Connections only: nothing is fetched until play.
const ORIGINS = [
  "https://www.youtube-nocookie.com",
  "https://www.google.com",
  "https://i.ytimg.com",
  "https://googleads.g.doubleclick.net",
  "https://static.doubleclick.net"
]

// A YouTube video that loads nothing from YouTube until it's played, in a large dialog (see
// app/views/components/_youtube.html.erb). The page holds a link to the video on YouTube, for visitors without
// JavaScript; this turns it into a play button. The first time the visitor points at, touches or focuses it, the
// browser connects to YouTube's hosts ahead of the click (never on page view). Pressing it puts the privacy-enhanced
// player, playing, in the dialog, which dialog_controller then opens; when the dialog closes, or before Turbo caches
// the page, the player goes, so playback stops and the next open starts afresh.
export default class extends Controller {
  static targets = ["play", "frame"]
  static values = { src: String, title: String, label: String }

  connect() {
    if (this.playTarget instanceof HTMLAnchorElement) this.playTarget.replaceWith(this.button(this.playTarget))
    document.addEventListener("turbo:before-cache", this.stop)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.stop)
  }

  // Once: the links stay in the head until Turbo moves to another page, which drops them.
  warm() {
    if (this.warmed) return
    this.warmed = true
    for (const href of ORIGINS) {
      if (document.head.querySelector(`link[rel="preconnect"][href="${href}"]`)) continue
      document.head.append(Object.assign(document.createElement("link"), { rel: "preconnect", href }))
    }
  }

  play() {
    const frame = document.createElement("iframe")
    frame.className = "video-frame"
    frame.src = this.srcValue
    frame.title = this.titleValue
    frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen"
    frame.allowFullscreen = true
    frame.referrerPolicy = "strict-origin-when-cross-origin" // the player won't start without the page's origin
    this.frameTarget.replaceChildren(frame)
  }

  stop = () => {
    this.frameTarget.replaceChildren()
  }

  // The link's poster and caption, on a button that warms the connections, then plays and opens the dialog.
  button(link) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = link.className
    button.setAttribute("aria-label", this.labelValue)
    button.setAttribute("aria-haspopup", "dialog")
    button.dataset.youtubeTarget = "play"
    button.dataset.action = "pointerover->youtube#warm focusin->youtube#warm touchstart->youtube#warm:passive " +
      "youtube#play dialog#open"
    button.append(...link.childNodes)
    return button
  }
}
