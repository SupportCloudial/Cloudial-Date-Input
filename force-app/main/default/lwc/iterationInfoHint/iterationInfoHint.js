import { LightningElement, api } from "lwc";

export default class IterationInfoHint extends LightningElement {
  @api message = "";
  @api iconName = "utility:info";
  @api iconClass = "";

  get iconWrapperClass() {
    return this.iconName === "utility:info"
      ? "iter-info-icon"
      : "iter-attention-icon-wrap";
  }

  get triggerClass() {
    return "ers-tooltip__trigger " + this.iconWrapperClass;
  }
}
