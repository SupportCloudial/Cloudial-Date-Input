import { LightningElement, api } from "lwc";

export default class ers_comboboxColumnType extends LightningElement {
  @api editable;
  @api fieldName;
  @api keyField;
  @api keyFieldValue;
  @api picklistValues;
  @api value;
  @api alignment;
  @api pastStartSplit = false;
  /** When true, show label only (no edit affordance). */
  @api readOnly = false;
  /** When set, overrides blank-value table label (use "" for empty cell). */
  @api blankDisplayLabel;
  editMode = false;

  get displayLabel() {
    const currentValue = this.value;
    if (currentValue == null || currentValue === "") {
      if (this.blankDisplayLabel !== undefined) {
        return this.blankDisplayLabel;
      }
      for (const key in this.picklistValues || {}) {
        if (
          Object.prototype.hasOwnProperty.call(this.picklistValues, key) &&
          (this.picklistValues[key] == null || this.picklistValues[key] === "")
        ) {
          return key;
        }
      }
      return "";
    }
    for (const key in this.picklistValues || {}) {
      if (
        Object.prototype.hasOwnProperty.call(this.picklistValues, key) &&
        this.picklistValues[key] === currentValue
      ) {
        return key;
      }
    }
    return String(currentValue).replace(/_/g, " ");
  }

  get options() {
    let _options = [];
    for (const key in this.picklistValues) {
      if (!Object.prototype.hasOwnProperty.call(this.picklistValues, key)) {
        continue;
      }
      let option = {};
      // option.label = this.picklistValues[key];
      // option.value = key;
      option.label = key;
      option.value = this.picklistValues[key];
      _options.push(option);
    }
    return _options;
  }

  get optionsForRender() {
    const currentValue = this.value;
    return (this.options || []).map((opt) => ({
      ...opt,
      selected: opt.value === currentValue
    }));
  }

  //bump left/right depending on alignment. For center, we will align the grids on a the cell level
  get valueClass() {
    let _valueClass = "slds-col_bump-right slds-align-middle";
    if (this.alignment.includes("right")) {
      _valueClass = "slds-col_bump-left slds-align-middle";
    } else if (this.alignment.includes("center")) {
      _valueClass = "slds-align-middle";
    }
    return _valueClass;
  }

  //if alignment is center, we align the grid to center
  get cellClass() {
    let _cellClass =
      "combobox-view__min-height cell__is-editable slds-grid slds-p-horizontal_x-small";
    if (this.alignment.includes("center")) {
      _cellClass += " slds-grid_align-center";
    }
    return _cellClass;
  }

  handleChange(event) {
    const selectedValue = event?.detail?.value ?? event?.target?.value;
    //We will mimic the standard oncellchange event from lightning datatable
    let draftValue = {};
    let draftValues = [];
    draftValue[this.fieldName] = selectedValue;
    draftValue[this.keyField] = this.keyFieldValue;
    draftValues.push(draftValue);

    const customEvent = CustomEvent("combovaluechange", {
      composed: true,
      bubbles: true,
      cancelable: true,
      detail: {
        draftValues: draftValues
      }
    });
    this.dispatchEvent(customEvent);

    this.editMode = false;
  }

  handleKeyDown(event) {
    const k = event?.key;
    if (k === "Enter" || k === " ") {
      event.preventDefault();
      this.editCombobox();
    }
  }

  editCombobox(event) {
    if (this.readOnly) {
      return;
    }
    if (event) {
      event.stopPropagation?.();
    }
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
    this.editMode = true;
    try {
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- focus combobox after edit mode opens
      requestAnimationFrame(() => {
        const cb = this.template.querySelector(".combobox-editor");
        if (!cb) return;
        try {
          cb.focus();
        } catch {
          /* ignore */
        }
      });
    } catch {
      // Fallback if requestAnimationFrame is unavailable
      const cb = this.template.querySelector(".combobox-editor");
      if (!cb) return;
      try {
        cb.focus();
      } catch {
        /* ignore */
      }
    }
  }

  toggleEditMode() {
    this.editMode = !this.editMode;
  }

  // Note: do not auto-close on blur; the dropdown menu interaction can trigger blur
  // in datatable cells and prevent selecting an option. We close on change instead.
}
