import { api } from "lwc";
import LightningConfirm from "lightning/confirm";
import LightningModal from "lightning/modal";

export default class PackageBuilderMonthlyPaymentsModal extends LightningModal {
  @api recordId;
  @api objectApiName;
  @api orderId;
  @api tabName;

  get effectiveRecordId() {
    return this.orderId || this.recordId;
  }

  get headerLabel() {
    if (this.objectApiName === "Contract") {
      if (this.tabName === "draft") return "Monthly Payments – Draft order";
      return "Monthly Payments – Active order";
    }
    if (this.objectApiName === "Opportunity") {
      return "Monthly Payments – Opportunity";
    }
    return "Monthly Payments";
  }

  async handleClose() {
    const mp = this.template.querySelector("c-monthly-payment-table");
    if (mp?.hasUnsavedMonthlyChanges) {
      const confirmed = await LightningConfirm.open({
        message:
          "You have unsaved changes to monthly payments. Discard them and close?",
        variant: "header",
        label: "Discard unsaved changes?"
      });
      if (!confirmed) {
        return;
      }
      mp.discardUnsavedMonthlyChanges();
    }
    this.close();
  }
}