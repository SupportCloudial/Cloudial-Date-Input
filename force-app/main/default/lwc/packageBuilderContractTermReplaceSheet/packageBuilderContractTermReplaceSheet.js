import { api, LightningElement, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import addReplacementProduct from "@salesforce/apex/AddPackageProductController.addReplacementProduct";
import ValueLabel from "@salesforce/label/c.PackageBuilderTbl_Value";

export default class PackageBuilderContractTermReplaceSheet extends LightningElement {
  @api isOpen = false;
  @api orderId;
  @api replacedOrderItemId;
  @api replacedPricebookEntryId;
  @api orderStartDate;
  @api orderEndDate;
  /** YYYY-MM-DD: default entry date = max(contract commercial start, replaced line entry/original start); min still orderStartDate (Order_Start_Date__c only when set). */
  @api defaultEntryDateYmd;
  @api defaultCpiDateYmd;
  @api defaultQuantity;

  @track entryDateStr = "";
  @track quantityInput = "";
  @track notesVal = "";
  @track isSaving = false;

  _lastSheetFocused = false;

  labels = {
    value: ValueLabel
  };

  get valueLabel() {
    return this.labels.value;
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

  /** YYYY-MM-DD floor for entry date (= order Order_Start_Date__c). Undefined when unset so lightning-input omits min. */
  get entryDateMinYmd() {
    const v = (this.orderStartDate || "").trim();
    return v || undefined;
  }

  renderedCallback() {
    if (!this.isOpen) {
      this._lastSheetFocused = false;
      this.isSaving = false;
      return;
    }
    if (!this._lastSheetFocused) {
      this._applyDefaultsFromApis();
      this._lastSheetFocused = true;
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- focus close after sheet open
      requestAnimationFrame(() => {
        const el = this.template.querySelector("[data-pb-ctr-sheet-close]");
        if (el) {
          el.focus();
        }
      });
    }
  }

  _applyDefaultsFromApis() {
    const fromDefault = (this.defaultEntryDateYmd || "").trim();
    const fromOrderStart = (this.orderStartDate || "").trim();
    if (fromDefault) {
      this.entryDateStr = fromDefault;
    } else if (fromOrderStart) {
      this.entryDateStr = fromOrderStart;
    } else {
      const t = new Date();
      this.entryDateStr = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(
        t.getDate()
      ).padStart(2, "0")}`;
    }
    const dq = Number(this.defaultQuantity);
    this.quantityInput = String(Number.isFinite(dq) ? dq : 1);
    this.notesVal = "";
  }

  handleBackdropClick() {
    if (!this.isSaving) {
      this.handleClose();
    }
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
    this.entryDateStr = event.detail?.value ?? "";
  }

  handleQtyChange(event) {
    this.quantityInput = event.detail?.value ?? "";
  }

  handleNotesChange(event) {
    this.notesVal = event.detail?.value ?? "";
  }

  handleSave() {
    const entry = (this.entryDateStr || "").trim();
    if (!entry) {
      this._toast("Error", "Start date is required.", "error");
      return;
    }
    const qtyNum = Number(this.quantityInput);
    if (!Number.isFinite(qtyNum) || qtyNum < 0) {
      this._toast(
        "Error",
        `Enter a valid ${this.valueLabel.toLowerCase()} (0 or greater).`,
        "error"
      );
      return;
    }
    const replacedQty = Number(this.defaultQuantity);
    if (
      Number.isFinite(replacedQty) &&
      replacedQty > 0 &&
      qtyNum === replacedQty
    ) {
      this._toast(
        "Error",
        `Replacement ${this.valueLabel.toLowerCase()} must differ from the replaced line ${this.valueLabel.toLowerCase()}.`,
        "error"
      );
      return;
    }
    const os = (this.orderStartDate || "").trim();
    if (os && entry < os) {
      this._toast(
        "Error",
        "Start date cannot be before the contract start date.",
        "error"
      );
      return;
    }

    this.isSaving = true;
    addReplacementProduct({
      productEntryId: this.replacedPricebookEntryId,
      orderId: this.orderId,
      replacedOrderItemId: this.replacedOrderItemId,
      periodStartStr: entry,
      periodEndStr: null,
      cpiDateStr: this.defaultCpiDateYmd || null,
      replacementQuantity: qtyNum,
      replacementDescription: (this.notesVal || "").trim() || null,
      openEndedReplacement: true
    })
      .then((msg) => {
        const err = String(msg || "").trim();
        if (err) {
          this._toast(
            "Error",
            this._normalizeContractTermErrorMessage(err),
            "error"
          );
        } else {
          this._toast("Success", "Contract term replaced.", "success");
          this.dispatchEvent(new CustomEvent("complete"));
        }
      })
      .catch((e) => {
        this._toast(
          "Error",
          this._normalizeContractTermErrorMessage(this._reduceError(e)),
          "error"
        );
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
    if (!error) {
      return "Error";
    }
    if (typeof error.body?.message === "string") {
      return error.body.message;
    }
    return "Error";
  }

  _normalizeContractTermErrorMessage(message) {
    const msg = String(message || "").trim();
    if (!msg) {
      return msg;
    }
    const valueWord = this.valueLabel.toLowerCase();
    return msg
      .replace(
        /entry date cannot be before the order start date\./i,
        "Start date cannot be before the contract start date."
      )
      .replace(
        /entry date cannot be after the order end date\./i,
        "Start date cannot be after the contract end date."
      )
      .replace(
        /product start date cannot be earlier than the order start date\./i,
        "Product start date cannot be earlier than the contract start date."
      )
      .replace(
        /period end date cannot be before the order start date\./i,
        "Period end date cannot be before the contract start date."
      )
      .replace(
        /product start date cannot be after the order end date\./i,
        "Product start date cannot be after the contract end date."
      )
      .replace(
        /quantity must be zero or greater\./i,
        `${valueWord} must be zero or greater.`
      );
  }
}
