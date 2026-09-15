import { LightningElement, api } from "lwc";

export default class Ers_dateColumnType extends LightningElement {
  @api editable;
  @api fieldName;
  @api keyField;
  @api keyFieldValue;
  @api value;
  /** When true, empty cells show nothing instead of "-". */
  @api hideEmptyDash = false;
  /** Optional hover text (c-ers-tooltip); only on read-only date value, not the edit icon. */
  @api tooltipMessage = "";
  editMode = false;

  get isCellEditable() {
    return this.editable === true || this.editable === "true";
  }

  get hasEndDateTooltip() {
    return !!(this.tooltipMessage && String(this.tooltipMessage).trim());
  }

  /**
   * Custom datatable cells (standardCellLayout: false) often do not put cellAttributes.class on td;
   * paint warning background on the cell root instead.
   */
  get dateCellRootClass() {
    const parts = ["date-cell", "slds-p-vertical_xx-small", "slds-p-horizontal_x-small"];
    if (this.isCellEditable) {
      parts.push("date-cell--editable");
    }
    if (this.hasEndDateTooltip) {
      parts.push("date-cell--warn-before-order-start");
    }
    return parts.join(" ");
  }

  get dateEditorWrapperClass() {
    return this.hasEndDateTooltip
      ? "date-editor-wrap date-cell--warn-before-order-start"
      : "date-editor-wrap";
  }

  get showEditor() {
    return this.isCellEditable && this.editMode;
  }

  get hasValue() {
    return !!this.value;
  }

  get showDashWhenEmpty() {
    return !this.hasValue && !this.hideEmptyDash;
  }

  get editorValue() {
    if (!this.value) return null;
    if (typeof this.value === "string") {
      return this.value.length >= 10 ? this.value.substring(0, 10) : this.value;
    }
    const d = new Date(this.value);
    if (Number.isNaN(d.getTime())) return null;
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  editDate() {
    if (!this.isCellEditable) return;
    this.editMode = true;
    requestAnimationFrame(() => {
      const input = this.template.querySelector("lightning-input.date-editor");
      if (input) input.focus();
    });
  }

  handleKeyDown(event) {
    const k = event?.key;
    if (k === "Enter" || k === " ") {
      event.preventDefault();
      this.editDate();
      return;
    }
    if (k === "Escape") {
      this.editMode = false;
    }
  }

  handleDateChange(event) {
    const nextValue = event.detail?.value ?? event.target?.value ?? "";
    const draftValue = {
      [this.fieldName]: nextValue,
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
    this.editMode = false;
  }

  handleDateBlur() {
    this.editMode = false;
  }
}