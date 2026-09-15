import { LightningElement, api } from "lwc";

export default class ErsIconActionWithTooltip extends LightningElement {
  @api iconName = "utility:delete";
  /** When set, renders this image URL instead of `lightning-icon` (custom SVG actions). */
  @api iconSrc = "";
  @api actionName = "";
  @api keyField = "LineItemId";
  @api keyFieldValue;
  @api disabled = false;
  @api tooltip = "";
  @api alternativeText = "Action";
  @api variant = "bare";
  @api size = "small";
  @api hidden = false;

  get showButton() {
    return !this.hidden;
  }

  get useImageIcon() {
    return typeof this.iconSrc === "string" && this.iconSrc.trim() !== "";
  }

  get ariaDisabled() {
    return this.disabled ? "true" : "false";
  }

  get buttonClass() {
    return this.disabled ? "ers-action-btn ers-action-btn--disabled" : "ers-action-btn";
  }

  handleClick() {
    if (this.disabled) return;
    this.dispatchEvent(
      new CustomEvent("rowaction", {
        composed: true,
        bubbles: true,
        cancelable: true,
        detail: {
          action: { name: this.actionName },
          row: { [this.keyField]: this.keyFieldValue }
        }
      })
    );
  }
}