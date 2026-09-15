import { LightningElement, api, wire, track } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import { RefreshEvent } from "lightning/refresh";
import getContractContext from "@salesforce/apex/TerminateContractController.getContractContext";
import terminateContract from "@salesforce/apex/TerminateContractController.terminateContract";

const REASONS = [
  { label: "Price - Competitors", value: "Price - Competitors" },
  {
    label: "Reduction/End of Company Activities",
    value: "⁠Reduction/End of Company Activities"
  },
  {
    label: "Merger with Another Company",
    value: "Merger with Another Company"
  },
  {
    label: "Transition to Independent Leasing",
    value: "⁠Transition to Independent Leasing"
  },
  { label: "Dissatisfaction", value: "Dissatisfaction" },
  { label: "Optimization Process", value: "Optimization Process" },
  {
    label: "Temporary Contract / Mediation",
    value: "Temporary Contract / Mediation"
  },
  {
    label: "No Relevant Solution for New Needs (Location/Mix/Needs)",
    value: "No Relevant Solution for New Needs (Location/Mix/Needs)"
  },
  { label: "Other", value: "Other" },
  { label: "Moved To Other Location", value: "Moved To Other Location" }
];

export default class TerminateContractAction extends LightningElement {
  @api recordId;

  @track loading = true;
  @track saving = false;
  @track hasError = false;
  @track errorMessage = "";
  @track successResult;
  @track showErrorScreen = false;

  contractInfo;
  terminationDate;
  terminationReason;
  earlyTerminationFee;
  reasonOptions = REASONS;

  @wire(getContractContext, { contractId: "$recordId" })
  wiredContract({ data, error }) {
    if (data) {
      this.contractInfo = data;
      this.terminationDate = data.existingTerminationDate;
      this.terminationReason = data.existingTerminationReason;
      this.earlyTerminationFee = data.existingEarlyTerminationFee;
      this.hasError = false;
      this.errorMessage = "";
      this.showErrorScreen = false;
      this.loading = false;
    } else if (error) {
      this.loading = false;
      this.errorMessage = this.normalizeError(error);
      this.showErrorScreen = true;
    }
  }

  get showInputForm() {
    return !this.loading && !this.successResult && !this.showErrorScreen;
  }

  get terminateButtonLabel() {
    return this.saving ? "Terminating..." : "Terminate Contract";
  }

  get showFeeField() {
    if (!this.terminationDate || !this.contractInfo?.lastTerminationDate) {
      return false;
    }
    return (
      new Date(this.terminationDate) <
      new Date(this.contractInfo.lastTerminationDate)
    );
  }

  handleDateChange(event) {
    this.terminationDate = event.detail?.value;
    this.hasError = false;
    this.errorMessage = "";
  }

  handleReasonChange(event) {
    this.terminationReason = event.detail.value;
    this.hasError = false;
    this.errorMessage = "";
  }

  handleFeeChange(event) {
    const value = event.detail.value;
    this.earlyTerminationFee =
      value === "" || value === null ? null : Number(value);
    this.hasError = false;
    this.errorMessage = "";
  }

  async handleTerminate() {
    if (!this.terminationDate || !this.terminationReason) {
      this.hasError = true;
      this.errorMessage =
        "Please provide Contract Termination Date and Termination Reason.";
      return;
    }
    if (
      this.showFeeField &&
      (this.earlyTerminationFee === null ||
        this.earlyTerminationFee === undefined)
    ) {
      this.hasError = true;
      this.errorMessage =
        "Please provide the termination fee as selected contract termination date is before last termination date.";
      return;
    }

    this.saving = true;
    this.hasError = false;
    this.errorMessage = "";
    this.showErrorScreen = false;

    try {
      const result = await terminateContract({
        contractId: this.recordId,
        terminationDate: this.terminationDate,
        terminationReason: this.terminationReason,
        earlyTerminationFee: this.earlyTerminationFee
      });
      this.successResult = result;
      await this.refreshBackgroundData();
    } catch (error) {
      this.errorMessage = this.normalizeError(error);
      this.showErrorScreen = true;
    } finally {
      this.saving = false;
    }
  }

  async handleClose() {
    if (this.successResult) {
      await this.refreshBackgroundData();
    }
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  handlePreviousFromError() {
    this.showErrorScreen = false;
    this.hasError = false;
    this.errorMessage = "";
  }

  async refreshBackgroundData() {
    const recordsToRefresh = [{ recordId: this.recordId }];
    if (this.successResult?.activeOrderId) {
      recordsToRefresh.push({ recordId: this.successResult.activeOrderId });
    }
    await notifyRecordUpdateAvailable(recordsToRefresh);
    this.dispatchEvent(new RefreshEvent());
  }

  normalizeError(error) {
    if (
      Array.isArray(error?.body?.output?.errors) &&
      error.body.output.errors.length > 0
    ) {
      return error.body.output.errors.map((e) => e.message).join(", ");
    }
    if (
      Array.isArray(error?.body?.pageErrors) &&
      error.body.pageErrors.length > 0
    ) {
      return error.body.pageErrors.map((e) => e.message).join(", ");
    }
    if (Array.isArray(error?.body?.fieldErrors)) {
      const fieldMsgs = [];
      Object.values(error.body.fieldErrors).forEach((errs) => {
        errs.forEach((e) => fieldMsgs.push(e.message));
      });
      if (fieldMsgs.length > 0) {
        return fieldMsgs.join(", ");
      }
    }
    if (error?.body?.message) {
      return error.body.message;
    }
    if (Array.isArray(error?.body) && error.body.length > 0) {
      return error.body.map((e) => e.message).join(", ");
    }
    if (error?.message) {
      return error.message;
    }
    return "An unexpected error occurred while terminating the contract.";
  }
}
