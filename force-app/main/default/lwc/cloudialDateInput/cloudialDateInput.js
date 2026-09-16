import { api, LightningElement } from "lwc";
import { FlowAttributeChangeEvent } from "lightning/flowSupport";
import salesforceLocale from "@salesforce/i18n/locale";
import badInputLabel from "@salesforce/label/c.CloudialDateInput_BadInput";
import defaultFieldLabel from "@salesforce/label/c.CloudialDateInput_Label";
import openCalendarLabel from "@salesforce/label/c.CloudialDateInput_OpenCalendar";
import requiredLabel from "@salesforce/label/c.CloudialDateInput_Required";
import rangeOverflowLabel from "@salesforce/label/c.CloudialDateInput_RangeOverflow";
import rangeUnderflowLabel from "@salesforce/label/c.CloudialDateInput_RangeUnderflow";
import valueMissingLabel from "@salesforce/label/c.CloudialDateInput_ValueMissing";
import {
  formatIsoDate,
  normalizeDisplayFormat,
  normalizeIso,
  parseDisplayDate,
  replaceMessageParameter,
  resolveLocale
} from "./dateValue";

export default class CloudialDateInput extends LightningElement {
  _value = "";
  _min = "";
  _max = "";
  _displayFormat = "locale";
  _draftValue;
  _customValidityMessage = "";
  _showError = false;

  @api label = defaultFieldLabel;
  @api name = "";
  @api placeholder = "";
  @api fieldLevelHelp = "";
  @api required = false;
  @api disabled = false;
  @api readOnly = false;
  @api variant = "standard";
  @api direction = "";
  @api locale = "";
  @api messageWhenValueMissing = valueMissingLabel;
  @api messageWhenBadInput = badInputLabel;
  @api messageWhenRangeUnderflow = rangeUnderflowLabel;
  @api messageWhenRangeOverflow = rangeOverflowLabel;

  @api
  get value() {
    return this._value;
  }

  set value(nextValue) {
    this._value = normalizeIso(nextValue);
    this._draftValue = undefined;
    this._showError = false;
  }

  @api
  get min() {
    return this._min;
  }

  set min(nextValue) {
    this._min = normalizeIso(nextValue);
  }

  @api
  get max() {
    return this._max;
  }

  set max(nextValue) {
    this._max = normalizeIso(nextValue);
  }

  @api
  get displayFormat() {
    return this._displayFormat;
  }

  set displayFormat(nextValue) {
    this._displayFormat = normalizeDisplayFormat(nextValue);
    this._draftValue = undefined;
  }

  get displayValue() {
    return this._draftValue !== undefined
      ? this._draftValue
      : this.formatIsoValue(this._value);
  }

  get pickerDisabled() {
    return this.disabled || this.readOnly;
  }

  get rootClass() {
    return `slds-form-element${this.hasVisibleError ? " slds-has-error" : ""}`;
  }

  get showLabel() {
    return Boolean(this.label);
  }

  get labelClass() {
    return `slds-form-element__label${
      this.variant === "label-hidden" ? " slds-assistive-text" : ""
    }`;
  }

  get showFieldLevelHelp() {
    return this.variant !== "label-hidden" && Boolean(this.fieldLevelHelp);
  }

  get directionValue() {
    return this.direction === "ltr" || this.direction === "rtl"
      ? this.direction
      : null;
  }

  get effectiveLocale() {
    return resolveLocale(this.locale, salesforceLocale);
  }

  get validationMessage() {
    if (this.disabled || this.readOnly) {
      return "";
    }
    return this._customValidityMessage || this.internalValidationMessage;
  }

  get internalValidationMessage() {
    if (this.disabled || this.readOnly) {
      return "";
    }
    const text = String(this._draftValue ?? this.displayValue).trim();
    if (!text) {
      return this.required
        ? this.messageWhenValueMissing || valueMissingLabel
        : "";
    }

    const parsedValue = this.parseDisplayValue(text);
    if (!parsedValue) {
      return this.messageWhenBadInput || badInputLabel;
    }
    if (this.min && parsedValue < this.min) {
      return replaceMessageParameter(
        this.messageWhenRangeUnderflow || rangeUnderflowLabel,
        this.formatIsoValue(this.min)
      );
    }
    if (this.max && parsedValue > this.max) {
      return replaceMessageParameter(
        this.messageWhenRangeOverflow || rangeOverflowLabel,
        this.formatIsoValue(this.max)
      );
    }
    return "";
  }

  get hasVisibleError() {
    return this._showError && Boolean(this.validationMessage);
  }

  get ariaInvalid() {
    return this.hasVisibleError ? "true" : "false";
  }

  get errorDescriptionId() {
    return this.hasVisibleError ? "date-error" : null;
  }

  get openCalendarText() {
    return openCalendarLabel;
  }

  get requiredText() {
    return requiredLabel;
  }

  handleInput(event) {
    if (this.pickerDisabled) {
      return;
    }
    this._draftValue = event.target.value;
    this._showError = false;
  }

  handleBlur() {
    if (this.pickerDisabled) {
      return;
    }
    this.validateAndCommitDraft();
  }

  handleKeyDown(event) {
    if (!this.pickerDisabled && event.key === "Enter") {
      event.preventDefault();
      this.validateAndCommitDraft();
    }
  }

  validateAndCommitDraft() {
    const parsedValue = this.parseDisplayValue(this._draftValue ?? this.displayValue);
    this._showError = true;
    if (parsedValue === null || this.validationMessage) {
      return;
    }
    this.commitValue(parsedValue);
  }

  handlePickerChange(event) {
    event.stopPropagation();
    if (this.pickerDisabled) {
      return;
    }
    const nextValue = normalizeIso(event.target.value);
    this._draftValue = this.formatIsoValue(nextValue);
    this._showError = true;
    if (this.validationMessage) {
      return;
    }
    this.commitValue(nextValue);
  }

  handlePickerButtonClick() {
    if (this.pickerDisabled) {
      return;
    }
    const picker = this.template.querySelector('[data-id="native-picker"]');
    if (typeof picker?.showPicker === "function") {
      try {
        picker.showPicker();
        return;
      } catch {
        // Browser or security policy blocked showPicker; use click fallback.
      }
    }
    picker?.click();
  }

  commitValue(nextValue) {
    const changed = nextValue !== this._value;
    this._value = nextValue;
    this._draftValue = undefined;
    this._showError = false;
    if (!changed) {
      return;
    }
    this.dispatchEvent(new FlowAttributeChangeEvent("value", nextValue));
    this.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { value: nextValue }
      })
    );
  }

  @api
  checkValidity() {
    return !this.validationMessage;
  }

  @api
  validate() {
    const errorMessage = this.internalValidationMessage;
    return errorMessage
      ? { isValid: false, errorMessage }
      : { isValid: true };
  }

  @api
  reportValidity() {
    this._showError = true;
    return this.checkValidity();
  }

  @api
  setCustomValidity(message) {
    this._customValidityMessage = String(message || "");
  }

  @api
  focus() {
    this.template.querySelector('[data-id="display-input"]')?.focus();
  }

  formatIsoValue(isoValue) {
    return formatIsoDate(
      isoValue,
      this.displayFormat,
      this.effectiveLocale
    );
  }

  parseDisplayValue(displayValue) {
    return parseDisplayDate(
      displayValue,
      this.displayFormat,
      this.effectiveLocale
    );
  }
}
