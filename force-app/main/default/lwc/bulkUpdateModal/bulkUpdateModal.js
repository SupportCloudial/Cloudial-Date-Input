import { api, track, wire } from "lwc";
import LightningModal from "lightning/modal";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getOrderItemTerminationReasonPicklistOptions from "@salesforce/apex/PackageBuilderController.getOrderItemTerminationReasonPicklistOptions";
import getOrderMovedToPicklistOptions from "@salesforce/apex/PackageBuilderController.getOrderMovedToPicklistOptions";
import { isPeriodicLike } from "c/accessTypePolicy";

export default class BulkUpdateModal extends LightningModal {
  /** "edit" (default) or "terminate" */
  @api mode = "edit";
  @api accessTypeOptions = [];
  /** ISO date string YYYY-MM-DD or null — Contract.EndDate */
  @api contractEndDate = null;
  /** Order Lease_Termination_Notice_Months__c picklist value "1".."6" */
  @api noticeMonths = null;
  /** Access_Type__c for each selected row (contract bulk only) */
  @api selectedAccessTypes = [];
  /** EndDate/End_date__c values for each selected product row. */
  @api selectedProductEndDates = [];
  /** EntryDate/Entry_Date__c/ServiceDate values for each selected product row. Used to compute the
   *  Exit Date lower bound (= max of order start date and the latest selected entry date) so users
   *  cannot terminate before any selected line's entry date.
   */
  @api selectedProductEntryDates = [];
  /** YYYY-MM-DD upper bound for Exit Date (latest selected product end); null when open-ended. */
  @api exitDateMaxYmd = null;
  /** Show Moved To field only on full termination condition */
  @api showMovedToField = false;
  /** Current Order.Moved_To__c (pre-populates Moved To combobox) */
  @api movedToDefault = null;
  /** Fallback threshold source when Contract.EndDate is blank */
  @api orderStartDate = null;
  /** Current Order.Early_Termination_Fee__c shown as read-only context in terminate flow */
  @api currentPenaltyAmount = null;
  @api isContractContext = false;
  @api isOpportunityContext = false;
  /** Async callback invoked with the result payload before closing. */
  @api saveCallback = null;

  // Edit-mode fields
  accessType = "";
  unitPrice = null;
  entryDate = "";
  endDate = "";
  accessTypeTouched = false;
  unitPriceTouched = false;
  entryDateTouched = false;
  endDateTouched = false;

  // Terminate-mode fields
  exitDate = "";
  terminationReason = "";
  penaltyAmount = null;
  movedTo = "";

  @track isSaving = false;

  terminationReasonOptions = [];
  movedToOptions = [];

  @wire(getOrderItemTerminationReasonPicklistOptions)
  wiredTerminationPicklist({ data, error }) {
    if (data) {
      this.terminationReasonOptions = data.map((row) => ({
        label: row.label,
        value: row.value
      }));
    } else if (error) {
      console.error("Termination picklist load error", error);
    }
  }

  @wire(getOrderMovedToPicklistOptions)
  wiredMovedToPicklist({ data, error }) {
    if (data) {
      this.movedToOptions = data.map((row) => ({
        label: row.label,
        value: row.value
      }));
    } else if (error) {
      console.error("Moved To picklist load error", error);
    }
  }

  connectedCallback() {
    const defaultMovedTo = String(this.movedToDefault || "").trim();
    if (defaultMovedTo && !this.movedTo) {
      this.movedTo = defaultMovedTo;
    }
  }

  get isEditMode() {
    return this.mode === "edit";
  }

  get isTerminateMode() {
    return this.mode === "terminate";
  }

  get modalTitle() {
    return this.isTerminateMode
      ? "Terminate Selected Products"
      : "Bulk Edit Selected Products";
  }

  get showEditEndDate() {
    return this.isOpportunityContext || this.isContractContext;
  }

  get applyDisabled() {
    return this.isSaving;
  }

  get applyLabel() {
    return this.isSaving ? "Saving..." : "Apply to Selected";
  }

  get showTerminationReason() {
    if (!this.isTerminateMode) return false;
    // Order / contract: termination reason is always collected. Opportunity bulk terminate only
    // persists end date from this modal, so keep the reason field aligned with early-exit only.
    if (this.isOpportunityContext) {
      return this._computeIsEarlyExit(this.exitDate).isEarlyExit;
    }
    return true;
  }

  get showPenaltyAmount() {
    return false;
  }

  get showCurrentPenaltyAmount() {
    return false;
  }

  _todayIso() {
    return new Date().toISOString().split("T")[0];
  }

  _normalizeToYyyyMmDd(input) {
    if (!input) return null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(input)) {
      return input;
    }
    const parsed = new Date(input);
    if (Number.isNaN(parsed.getTime())) return null;
    return parsed.toISOString().split("T")[0];
  }

  get hasPeriodicSelectedAccessType() {
    const types = Array.isArray(this.selectedAccessTypes)
      ? this.selectedAccessTypes
      : [];
    return types.some((accessType) => isPeriodicLike(accessType));
  }

  /** Fee fields removed from terminate product UI — no fee-related hint. */
  get terminateFieldsHiddenHint() {
    return "";
  }

  /** Lower bound for Exit Date in terminate mode: max(orderStartDate, latest selected entry date). */
  get exitDateMinYmd() {
    if (!this.isTerminateMode) return null;
    const entryDates = Array.isArray(this.selectedProductEntryDates)
      ? this.selectedProductEntryDates
      : [];
    const candidates = [this.orderStartDate, ...entryDates]
      .map((d) => this._normalizeToYyyyMmDd(d))
      .filter((d) => !!d);
    if (!candidates.length) return null;
    return candidates.reduce((acc, d) => (d > acc ? d : acc));
  }

  /** Upper bound: latest selected product End Date; null when any selected line is open-ended. */
  get exitDateMaxYmdForPicker() {
    if (!this.isTerminateMode) return null;
    return this.exitDateMaxYmd || null;
  }

  /** True when exit date is strictly before product end (or today if end is blank) for any selected row. */
  _computeIsEarlyExit(exitDateStr) {
    const result = { isEarlyExit: false };
    if (!exitDateStr) {
      return result;
    }

    const normalizedExitDate = this._normalizeToYyyyMmDd(exitDateStr);
    if (!normalizedExitDate) {
      return result;
    }

    const todayIso = this._todayIso();
    const selectedEndDates = Array.isArray(this.selectedProductEndDates)
      ? this.selectedProductEndDates
      : [];
    if (selectedEndDates.length > 0) {
      result.isEarlyExit = selectedEndDates.some((endDate) => {
        const normalizedEndDate = this._normalizeToYyyyMmDd(endDate);
        const compareDate = normalizedEndDate || todayIso;
        return normalizedExitDate < compareDate;
      });
      return result;
    }

    result.isEarlyExit = normalizedExitDate < todayIso;
    return result;
  }

  handleAccessTypeChange(event) {
    this.accessTypeTouched = true;
    this.accessType = event.detail.value;
  }

  handleUnitPriceChange(event) {
    this.unitPriceTouched = true;
    this.unitPrice = event.detail.value;
  }

  handleEntryDateChange(event) {
    this.entryDateTouched = true;
    this.entryDate = event.detail?.value ?? event.target?.value;
  }

  handleEndDateChange(event) {
    this.endDateTouched = true;
    this.endDate = event.detail?.value ?? event.target?.value;
  }

  handleExitDateChange(event) {
    this.exitDate = event.detail?.value ?? event.target?.value;
  }

  handleTerminationReasonChange(event) {
    this.terminationReason = event.detail.value;
  }

  handlePenaltyAmountChange(event) {
    this.penaltyAmount = event.detail.value;
  }

  handleMovedToChange(event) {
    this.movedTo = event.detail.value;
  }

  get currentPenaltyAmountDisplay() {
    const n = Number(this.currentPenaltyAmount);
    return Number.isFinite(n) ? n : 0;
  }

  async handleApply() {
    let payload;

    if (this.isEditMode) {
      const hasUnitPrice =
        this.unitPriceTouched &&
        this.unitPrice !== null &&
        this.unitPrice !== undefined &&
        String(this.unitPrice).trim() !== "";
      payload = {
        accessType:
          this.accessTypeTouched && this.accessType ? this.accessType : null,
        unitPrice: hasUnitPrice ? Number(this.unitPrice) : null,
        entryDate:
          this.entryDateTouched && this.entryDate ? this.entryDate : null,
        endDate: this.endDateTouched && this.endDate ? this.endDate : null
      };
    } else {
      // Terminate mode
      if (!String(this.exitDate || "").trim()) {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Required field",
            message: "Exit Date is required.",
            variant: "error"
          })
        );
        return;
      }
      // Lower-bound guard (defense-in-depth — picker also enforces min).
      const minIso = this.exitDateMinYmd;
      const exitIso = this._normalizeToYyyyMmDd(this.exitDate);
      if (minIso && exitIso && exitIso < minIso) {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Invalid Exit Date",
            message: `Exit Date cannot be earlier than ${minIso} (the latest of the Contract Start Date and selected products' Start Dates).`,
            variant: "error"
          })
        );
        return;
      }
      const maxIso = this.exitDateMaxYmdForPicker;
      if (maxIso && exitIso && exitIso > maxIso) {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Invalid Exit Date",
            message: `Exit Date cannot be later than ${maxIso} (the latest selected product end date).`,
            variant: "error"
          })
        );
        return;
      }
      const showTerminationReason = this.showTerminationReason;
      if (showTerminationReason && !this.terminationReason) {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Required field",
            message: "Termination Reason is required.",
            variant: "error"
          })
        );
        return;
      }
      payload = {
        exitDate: this.exitDate || null,
        showExitFields: showTerminationReason,
        terminationReason: showTerminationReason
          ? this.terminationReason
          : null,
        penaltyAmount: null,
        movedTo: this.showMovedToField ? this.movedTo || null : null
      };
    }

    if (typeof this.saveCallback === "function") {
      this.isSaving = true;
      try {
        await this.saveCallback(payload);
        this.close(payload);
      } catch (e) {
        if (e?.pbSkipModalErrorToast) {
          return;
        }
        const msg = this._reduceErrorMessage(e);
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Error",
            message: msg,
            variant: "error"
          })
        );
      } finally {
        this.isSaving = false;
      }
    } else {
      this.close(payload);
    }
  }

  handleCancel() {
    this.close(null);
  }

  _reduceErrorMessage(error) {
    try {
      if (!error) return "Save failed.";
      if (typeof error === "string" && error.trim()) return error;
      const body = error.body;
      if (typeof body === "string" && body.trim()) return body;
      if (body?.message) return body.message;
      // UI API / Apex errors
      const firstOutputError = body?.output?.errors?.length
        ? body.output.errors[0]?.message
        : null;
      if (firstOutputError) return firstOutputError;
      const firstFieldErrorKey = body?.output?.fieldErrors
        ? Object.keys(body.output.fieldErrors)[0]
        : null;
      const firstFieldError =
        firstFieldErrorKey &&
        body.output.fieldErrors[firstFieldErrorKey]?.length
          ? body.output.fieldErrors[firstFieldErrorKey][0]?.message
          : null;
      if (firstFieldError) return firstFieldError;
      // LDS array form
      if (Array.isArray(body) && body.length && body[0]?.message)
        return body[0].message;
      if (error.message) return error.message;
      // Last resort: stringify so we never lose server context.
      try {
        const asJson = JSON.stringify(error);
        if (asJson && asJson !== "{}") return asJson;
      } catch {
        // ignore
      }
      return "Save failed.";
    } catch {
      return "Save failed.";
    }
  }
}
