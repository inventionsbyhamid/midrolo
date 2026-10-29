import { Controller } from "@hotwired/stimulus"

// A photo field that uploads straight to storage when the form is saved (R149), with a progress bar. A file of the
// wrong type or size is refused as soon as it's picked, before anything is sent; the server checks again either way.
// Active Storage (application.js) does the upload and fires direct-upload:* events on the input; this only shows them.
//
//   <div data-controller="upload" data-upload-max-bytes-value="5242880" data-upload-types-value='["image/png"]'>
//     <input type="file" data-upload-target="input" data-direct-upload-url="/uploads"
//            data-action="change->upload#check direct-upload:start->upload#start direct-upload:progress->upload#progress
//                         direct-upload:error->upload#fail direct-upload:end->upload#finish">
//     <progress data-upload-target="bar" max="100" hidden></progress>
//     <p data-upload-target="status" aria-live="polite"></p>
//   </div>
export default class extends Controller {
  static targets = ["input", "bar", "status"]
  static values = { maxBytes: Number, types: Array }

  check() {
    const file = this.inputTarget.files[0]
    this.reset()
    if (!file) return

    if (this.typesValue.length && !this.typesValue.includes(file.type)) {
      this.refuse("Choose a JPEG, PNG or WebP image.")
    } else if (this.maxBytesValue && file.size > this.maxBytesValue) {
      this.refuse(`That photo is ${this.megabytes(file.size)}. Choose one of ${this.megabytes(this.maxBytesValue)} or less.`)
    } else {
      this.say("Uploads when you save.")
    }
  }

  start() {
    this.barTarget.value = 0
    this.barTarget.hidden = false
    this.say("Uploading…")
  }

  progress(event) {
    const percent = Math.round(event.detail.progress)
    this.barTarget.value = percent
    this.say(`Uploading… ${percent}%`)
  }

  // Shown here instead of Active Storage's alert().
  fail(event) {
    event.preventDefault()
    this.barTarget.hidden = true
    this.say("The upload didn't finish. Check your connection and save again.", true)
  }

  finish() {
    this.barTarget.value = 100
    this.say("Uploaded. Saving…")
  }

  // private

  refuse(message) {
    this.inputTarget.value = ""
    this.say(message, true)
  }

  reset() {
    this.barTarget.hidden = true
    this.say("")
  }

  say(message, problem = false) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("upload-problem", problem)
  }

  megabytes(bytes) {
    return `${(bytes / 1048576).toFixed(bytes < 10485760 ? 1 : 0).replace(/\.0$/, "")} MB`
  }
}
