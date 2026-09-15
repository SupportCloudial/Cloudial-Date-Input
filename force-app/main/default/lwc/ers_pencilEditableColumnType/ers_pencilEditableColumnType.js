import { LightningElement, api } from "lwc";

export default class Ers_pencilEditableColumnType extends LightningElement {
  @api editable;
  @api fieldName;
  @api keyField;
  @api keyFieldValue;
  @api value;
  @api inputType = "number";
  @api pastStartSplit = false;
  @api step = "any";
  @api alignment;
  /** Task 4: MP price projection info on Product's Price. */
  @api showPriceProjectionInfo;
  @api tooltipPriceProjection = "";

  editMode = false;
  editorValue = "";
  _ignoreBlur = false;
  _committing = false;

  get isCellEditable() {
    if (this.editable === false || this.editable === "false") {
      return false;
    }
    return this.editable === true || this.editable === "true";
  }

  get readOnlyRole() {
    return this.isCellEditable ? "button" : undefined;
  }

  get readOnlyTabIndex() {
    return this.isCellEditable ? "0" : undefined;
  }

  get readOnlyAriaLabel() {
    return this.isCellEditable ? "Edit value" : undefined;
  }

  get nativeInputType() {
    return this.inputType === "currency"
      ? "number"
      : this.inputType || "number";
  }

  get displayValue() {
    if (this.value === null || this.value === undefined || this.value === "") {
      return "";
    }
    if (this.inputType === "currency") {
      const n = Number(this.value);
      if (Number.isNaN(n)) return String(this.value);
      return (
        n.toLocaleString(undefined, {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2
        }) + "₪"
      );
    }
    return String(this.value);
  }

  get valueClass() {
    let cls = "slds-col_bump-right slds-align-middle";
    if (this.alignment && String(this.alignment).includes("right")) {
      cls = "slds-col_bump-left slds-align-middle";
    } else if (this.alignment && String(this.alignment).includes("center")) {
      cls = "slds-align-middle";
    }
    return cls;
  }

  get cellClass() {
    let cls =
      "combobox-view__min-height cell__is-editable slds-grid slds-p-horizontal_x-small";
    if (this.alignment && String(this.alignment).includes("center")) {
      cls += " slds-grid_align-center";
    }
    return cls;
  }

  get showPriceProjectionInfoIcon() {
    return this.showPriceProjectionInfo === true;
  }

  get priceProjectionTooltip() {
    const t =
      typeof this.tooltipPriceProjection === "string"
        ? this.tooltipPriceProjection.trim()
        : "";
    return t || "Monthly Payment price info";
  }

  _beginEditMode() {
    const v = this.value;
    this.editorValue =
      v === null || v === undefined || v === "" ? "" : String(v);
    this._ignoreBlur = true;
    this.editMode = true;
    // eslint-disable-next-line @lwc/lwc/no-async-operation -- focus input after edit mode opens
    requestAnimationFrame(() => {
      const input = this.template.querySelector(".pencil-editor");
      if (input) {
        try {
          input.focus();
          input.select?.();
        } catch {
          /* ignore */
        }
      }
      this._ignoreBlur = false;
    });
  }

  handlePencilClick(event) {
    event?.stopPropagation?.();
    if (!this.isCellEditable) return;
    const evt = new CustomEvent("fieldpencilclick", {
      composed: true,
      bubbles: true,
      cancelable: true,
      detail: {
        fieldName: this.fieldName,
        keyField: this.keyField,
        keyFieldValue: this.keyFieldValue
      }
    });
    this.dispatchEvent(evt);
    if (evt.defaultPrevented) {
      return;
    }
    if (this.pastStartSplit === true || this.pastStartSplit === "true") {
      return;
    }
    this._beginEditMode();
  }

  handleKeyDown(event) {
    const k = event?.key;
    if (k === "Enter" || k === " ") {
      event.preventDefault();
      this.handlePencilClick(event);
    }
  }

  handleEditorInput(event) {
    this.editorValue = event.target?.value ?? "";
  }

  handleEditorKeyDown(event) {
    event.stopPropagation();
    const k = event?.key;
    if (k === "Enter") {
      event.preventDefault();
      this._commitEdit();
    } else if (k === "Escape") {
      event.preventDefault();
      this.editMode = false;
    }
  }

  handleEditorBlur() {
    if (this._ignoreBlur || !this.editMode) {
      return;
    }
    this._commitEdit();
  }

  _commitEdit() {
    if (!this.editMode || this._committing) {
      return;
    }
    this._committing = true;
    const raw = this.editorValue;
    const draftValue = {
      [this.fieldName]: raw === "" ? null : raw,
      [this.keyField]: this.keyFieldValue
    };
    this.dispatchEvent(
      new CustomEvent("combovaluechange", {
        composed: true,
        bubbles: true,
        cancelable: true,
        detail: { draftValues: [draftValue] }
      })
    );
    this.editMode = false;
    this._committing = false;
  }
}
