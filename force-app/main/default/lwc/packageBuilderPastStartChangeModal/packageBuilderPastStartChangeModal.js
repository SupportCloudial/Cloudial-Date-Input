import { api, LightningElement, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import addPastStartSplitLine from "@salesforce/apex/AddPackageProductController.addPastStartSplitLine";
import { pastStartNewLineRequiresEndDate } from "c/accessTypePolicy";
import ValueLabel from "@salesforce/label/c.PackageBuilderTbl_Value";
import AccessType from "@salesforce/label/c.PackageBuilder_AccessType";

import EndDate from "@salesforce/label/c.PackageBuilderTbl_EndDate";

export default class PackageBuilderPastStartChangeModal extends LightningElement {
  /** quantity | accessType */
  @api mode = "accessType";
  @api isOpen = false;
  @api orderId;
  @api replacedOrderItemId;
  @api replacedPricebookEntryId;
  /** YYYY-MM-DD min = line start + 1 */
  @api entryDateMinYmd;
  /** YYYY-MM-DD max = line end */
  @api entryDateMaxYmd;
  @api defaultEntryDateYmd;
  /** YYYY-MM-DD default for new line end (access type mode) */
  @api defaultEndDateYmd;
  /** YYYY-MM-DD max for new line end (order/contract end) */
  @api orderEndDateYmd;
  @api defaultQuantity;
  /** Display only for accessType mode */
  @api currentAccessType;
  @api flippedAccessType;
  @api showAccessTypePicker = false;
  @api accessTypePickerOptions = [];
  @api defaultPickerAccessType;

  @track entryDateStr = "";
  @track endDateStr = "";
  @track quantityInput = "";
  @track selectedAccessType = "";
  @track isSaving = false;

  _lastOpen = false;
  _accessTypeGuardFired = false;

  labels = {
    value: ValueLabel,
    accessType: AccessType,
    endDate: EndDate
  };

  get isQuantityMode() {
    return this.mode === "quantity";
  }

  get isAccessTypeMode() {
    return this.mode === "accessType";
  }

  get showAccessTypePickerUi() {
    return this.isAccessTypeMode && this.showAccessTypePicker === true;
  }

  get effectiveNewAccessType() {
    if (this.showAccessTypePickerUi) {
      return (
        this.selectedAccessType ||
        this.defaultPickerAccessType ||
        ""
      ).trim();
    }
    return (this.flippedAccessType || "").trim();
  }

  get normalizedCurrentAccessType() {
    return (this.currentAccessType || "").trim();
  }

  /** True when Access Type mode lacks enough data to change type safely. */
  get accessTypeContextInvalid() {
    if (!this.isAccessTypeMode) {
      return false;
    }
    if (!this.normalizedCurrentAccessType) {
      return true;
    }
    if (this.showAccessTypePickerUi) {
      const opts = Array.isArray(this.accessTypePickerOptions)
        ? this.accessTypePickerOptions
        : [];
      return opts.length === 0;
    }
    return !this.effectiveNewAccessType;
  }

  get showFlipAccessTypeSentence() {
    return (
      this.isAccessTypeMode &&
      !this.showAccessTypePickerUi &&
      !this.accessTypeContextInvalid
    );
  }

  get isNewLinePeriodicLike() {
    return pastStartNewLineRequiresEndDate(this.effectiveNewAccessType);
  }

  get showEndDateField() {
    return this.isAccessTypeMode && this.isNewLinePeriodicLike;
  }

  get modalTitle() {
    return this.isQuantityMode ? "Change Quantity" : "Change Access Type";
  }

  get valueLabel() {
    return this.labels.value;
  }

  get endDateLabel() {
    return this.labels.endDate;
  }

  get endDateMinYmd() {
    return (this.entryDateStr || this.entryDateMinYmd || "").trim() || null;
  }

  get endDateMaxYmd() {
    return (this.orderEndDateYmd || "").trim() || null;
  }

  get backdropClass() {
    return `pb-ctr-sheet-backdrop${this.isOpen ? " is-open" : ""}`;
  }

  get sheetClass() {
    return `pb-ctr-sheet${this.isOpen ? " is-open" : ""}`;
  }

  get ariaHidden() {
    return this.isOpen ? "false" : "true";
  }

  renderedCallback() {
    if (!this.isOpen) {
      this._lastOpen = false;
      this._accessTypeGuardFired = false;
      this.isSaving = false;
      return;
    }
    if (!this._lastOpen) {
      this._applyDefaults();
      this._lastOpen = true;
      if (this._guardInvalidAccessTypeContext()) {
        return;
      }
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- focus close button after modal open
      requestAnimationFrame(() => {
        const el = this.template.querySelector("[data-pb-past-start-close]");
        if (el) el.focus();
      });
    }
  }

  _guardInvalidAccessTypeContext() {
    if (!this.accessTypeContextInvalid || this._accessTypeGuardFired) {
      return this.accessTypeContextInvalid;
    }
    this._accessTypeGuardFired = true;
    this._toast(
      "Error",
      "Cannot change access type: missing current or target access type for this product. Close and try again, or refresh Package Builder.",
      "error"
    );
    this.handleClose();
    return true;
  }

  _applyDefaults() {
    const fromDefault = (this.defaultEntryDateYmd || "").trim();
    const fromMin = (this.entryDateMinYmd || "").trim();
    if (fromDefault) {
      this.entryDateStr = fromDefault;
    } else if (fromMin) {
      this.entryDateStr = fromMin;
    } else {
      const t = new Date();
      this.entryDateStr = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(
        t.getDate()
      ).padStart(2, "0")}`;
    }
    const dq = Number(this.defaultQuantity);
    this.quantityInput = String(Number.isFinite(dq) ? dq : 1);
    this.selectedAccessType =
      (this.defaultPickerAccessType || "").trim() ||
      (this.flippedAccessType || "").trim();
    this.endDateStr = this.isNewLinePeriodicLike
      ? (this.defaultEndDateYmd || "").trim()
      : "";
  }

  handleBackdropClick() {
    if (!this.isSaving) this.handleClose();
  }

  handleClose() {
    this.dispatchEvent(new CustomEvent("close"));
  }

  handleKeydown(event) {
    if (!this.isOpen) return;
    if (event.key === "Escape" && !this.isSaving) {
      event.preventDefault();
      this.handleClose();
    }
  }

  handleEntryChange(event) {
    const next = (event.detail?.value ?? event.target?.value ?? "").trim();
    if (next || !this.entryDateStr) {
      this.entryDateStr = next;
    }
  }

  handleEndDateChange(event) {
    const next = (event.detail?.value ?? event.target?.value ?? "").trim();
    if (next || !this.endDateStr) {
      this.endDateStr = next;
    }
  }

  handleQtyChange(event) {
    this.quantityInput = event.detail?.value ?? "";
  }

  handleAccessTypePickerChange(event) {
    this.selectedAccessType = event.detail?.value ?? "";
    if (!pastStartNewLineRequiresEndDate(this.effectiveNewAccessType)) {
      this.endDateStr = "";
    } else if (!this.endDateStr) {
      this.endDateStr = (this.defaultEndDateYmd || "").trim();
    }
  }

  handleSave() {
    if (this.isAccessTypeMode && this.accessTypeContextInvalid) {
      this._toast(
        "Error",
        "Cannot change access type: missing current or target access type for this product.",
        "error"
      );
      return;
    }

    const entry = (this.entryDateStr || "").trim();
    if (!entry) {
      this._toast("Error", "Start date is required.", "error");
      return;
    }
    const minY = (this.entryDateMinYmd || "").trim();
    const maxY = (this.entryDateMaxYmd || "").trim();
    if (minY && entry < minY) {
      this._toast("Error", `Start date must be on or after ${minY}.`, "error");
      return;
    }
    if (maxY && entry > maxY) {
      this._toast("Error", `Start date cannot be after ${maxY}.`, "error");
      return;
    }

    if (this.isAccessTypeMode && !this.effectiveNewAccessType) {
      this._toast("Error", "Access type is required.", "error");
      return;
    }

    let endParam = null;
    if (this.showEndDateField) {
      const end = (this.endDateStr || "").trim();
      if (!end) {
        this._toast("Error", "End date is required for the new line.", "error");
        return;
      }
      if (end < entry) {
        this._toast("Error", "End date cannot be before start date.", "error");
        return;
      }
      const orderEnd = (this.orderEndDateYmd || "").trim();
      if (orderEnd && end > orderEnd) {
        this._toast("Error", `End date cannot be after ${orderEnd}.`, "error");
        return;
      }
      endParam = end;
    }

    let qtyParam = null;
    if (this.isQuantityMode) {
      const qtyNum = Number(this.quantityInput);
      if (!Number.isFinite(qtyNum) || qtyNum < 0) {
        this._toast(
          "Error",
          `Enter a valid ${this.valueLabel.toLowerCase()} (0 or greater).`,
          "error"
        );
        return;
      }
      qtyParam = qtyNum;
    }

    const replacementAccessTypeStr = this.isAccessTypeMode
      ? this.showAccessTypePickerUi
        ? this.effectiveNewAccessType
        : null
      : null;

    this.isSaving = true;
    addPastStartSplitLine({
      productEntryId: this.replacedPricebookEntryId,
      orderId: this.orderId,
      replacedOrderItemId: this.replacedOrderItemId,
      periodStartStr: entry,
      periodEndStr: endParam,
      replacementQuantity: qtyParam,
      splitMode: this.mode,
      replacementAccessTypeStr
    })
      .then((msg) => {
        const err = String(msg || "").trim();
        if (err) {
          this._toast("Error", err, "error");
        } else {
          this._toast("Success", "Product updated.", "success");
          this.dispatchEvent(new CustomEvent("complete"));
        }
      })
      .catch((e) => {
        this._toast("Error", this._reduceError(e), "error");
      })
      .finally(() => {
        this.isSaving = false;
      });
  }

  _toast(title, message, variant) {
    const toast = { title, message, variant };
    if (variant === "success" || variant === "info" || variant === "warning") {
      toast.mode = "dismissable";
    }
    this.dispatchEvent(new ShowToastEvent(toast));
  }

  _reduceError(error) {
    if (!error) return "Error";
    if (typeof error.body?.message === "string") return error.body.message;
    return "Error";
  }
}
