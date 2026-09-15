import { LightningElement, api } from "lwc";

export default class Ers_booleanColumnType extends LightningElement {
  @api editable;
  @api fieldName;
  @api keyField;
  @api keyFieldValue;
  @api value;

  get checked() {
    return this.value === true;
  }

  get isDisabled() {
    return !this.editable;
  }

  get inputId() {
    const key = this.keyFieldValue != null ? String(this.keyFieldValue) : "row";
    return `pb-temporary-${key}`;
  }

  handleChange(event) {
    if (!this.editable) {
      return;
    }
    const nextChecked = event.target.checked === true;
    const draftValue = {
      [this.fieldName]: nextChecked,
      [this.keyField]: this.keyFieldValue
    };

    this.dispatchEvent(
      new CustomEvent("cellchange", {
        composed: true,
        bubbles: true,
        cancelable: true,
        detail: {
          draftValues: [draftValue]
        }
      })
    );
  }
}
