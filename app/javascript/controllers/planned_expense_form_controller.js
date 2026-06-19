import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["recurring", "recurrenceFields", "recurrenceType", "intervalFields", "dayOfMonthFields", "timesPerMonthFields"]

  connect() {
    this.update()
  }

  update() {
    const recurring = this.recurringTarget.checked
    this.toggle(this.recurrenceFieldsTarget, recurring)

    if (!recurring) return

    const recurrenceType = this.recurrenceTypeTarget.value
    this.toggle(this.intervalFieldsTarget, recurrenceType === "interval")
    this.toggle(this.dayOfMonthFieldsTarget, recurrenceType === "day_of_month")
    this.toggle(this.timesPerMonthFieldsTarget, recurrenceType === "times_per_month")
  }

  toggle(element, visible) {
    element.classList.toggle("hidden", !visible)
  }
}
