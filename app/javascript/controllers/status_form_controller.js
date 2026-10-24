import { Controller } from "@hotwired/stimulus"

// The pipeline form on a sponsor match card (sponsor_matches/_status_form).
//
//   <form data-controller="status-form" data-action="turbo:before-morph-attribute->status-form#keepOpen">
//     <select data-action="status-form#submit">
//
// The status saves as soon as it changes. The server answers with a Turbo Stream that morphs the form in place,
// so the select keeps focus and the "Saved" live region stays the same element. The server renders the notes
// panel closed unless one of its fields has an error; keepOpen stops that morph, or a report page refresh, from
// closing a panel the podcaster has open.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }

  keepOpen(event) {
    const { attributeName, mutationType } = event.detail
    if (event.target.localName === "details" && attributeName === "open" && mutationType === "remove") {
      event.preventDefault()
    }
  }
}
