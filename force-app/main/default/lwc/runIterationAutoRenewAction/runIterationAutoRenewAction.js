import { LightningElement, api } from "lwc";
import LightningConfirm from "lightning/confirm";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import runOrgWide from "@salesforce/apex/IterationAutoRenewManualController.runOrgWide";

export default class RunIterationAutoRenewAction extends LightningElement {
  @api recordId;

  @api
  async invoke() {
    const confirmed = await LightningConfirm.open({
      message:
        "This runs the org-wide Iteration Auto-Renew job (same as the daily schedule). All due iterations across all contracts will be processed. Continue?",
      variant: "header",
      label: "Run Iteration Auto-Renew?",
      theme: "warning"
    });
    if (!confirmed) {
      return;
    }

    try {
      const jobId = await runOrgWide();
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Iteration Auto-Renew started",
          message:
            "Batch Job Id: {0}. When finished, check Last Auto Renew Result on affected Contracts.",
          messageData: [jobId],
          variant: "success",
          mode: "sticky"
        })
      );
    } catch (error) {
      const message =
        error?.body?.message ||
        error?.message ||
        "Unable to start Iteration Auto-Renew.";
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Iteration Auto-Renew failed",
          message,
          variant: "error",
          mode: "sticky"
        })
      );
    }
  }
}
