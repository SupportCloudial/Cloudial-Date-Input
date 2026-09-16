/* eslint-disable @salesforce/lightning/prefer-i18n-service -- Intl is required to infer locale date order and normalize localized digits without converting the public date value. */
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

const ISO_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const DISPLAY_FORMATS = new Set([
  "locale",
  "DD.MM.YYYY",
  "DD/MM/YYYY",
  "MM/DD/YYYY",
  "YYYY-MM-DD"
]);

function validIso(value) {
  const match = String(value || "").match(ISO_PATTERN);
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12 || day < 1) {
    return false;
  }
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [
    31,
    leapYear ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31
  ];
  return day <= daysInMonth[month - 1];
}

function replaceParameter(message, value) {
  return String(message).replace("{0}", value);
}

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
    const candidate = String(nextValue || "").trim();
    this._value = validIso(candidate) ? candidate : "";
    this._draftValue = undefined;
    this._showError = false;
  }

  @api
  get min() {
    return this._min;
  }

  set min(nextValue) {
    const candidate = String(nextValue || "").trim();
    this._min = validIso(candidate) ? candidate : "";
  }

  @api
  get max() {
    return this._max;
  }

  set max(nextValue) {
    const candidate = String(nextValue || "").trim();
    this._max = validIso(candidate) ? candidate : "";
  }

  @api
  get displayFormat() {
    return this._displayFormat;
  }

  set displayFormat(nextValue) {
    this._displayFormat = DISPLAY_FORMATS.has(nextValue) ? nextValue : "locale";
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
    return this.variant !== "label-hidden" && Boolean(this.label);
  }

  get directionValue() {
    return this.direction === "ltr" || this.direction === "rtl"
      ? this.direction
      : null;
  }

  get effectiveLocale() {
    const candidate = this.locale || salesforceLocale;
    try {
      Intl.DateTimeFormat(candidate).resolvedOptions();
      return candidate;
    } catch {
      return salesforceLocale;
    }
  }

  get validationMessage() {
    if (this.disabled || this.readOnly) {
      return "";
    }
    if (this._customValidityMessage) {
      return this._customValidityMessage;
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
      return replaceParameter(
        this.messageWhenRangeUnderflow || rangeUnderflowLabel,
        this.formatIsoValue(this.min)
      );
    }
    if (this.max && parsedValue > this.max) {
      return replaceParameter(
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
    const nextValue = validIso(event.target.value) ? event.target.value : "";
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
      picker.showPicker();
    } else {
      picker?.click();
    }
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
    if (!validIso(isoValue)) {
      return "";
    }
    const [year, month, day] = isoValue.split("-");
    switch (this.displayFormat) {
      case "DD.MM.YYYY":
        return `${day}.${month}.${year}`;
      case "DD/MM/YYYY":
        return `${day}/${month}/${year}`;
      case "MM/DD/YYYY":
        return `${month}/${day}/${year}`;
      case "YYYY-MM-DD":
        return isoValue;
      default: {
        const date = new Date(0);
        date.setUTCHours(0, 0, 0, 0);
        date.setUTCFullYear(Number(year), Number(month) - 1, Number(day));
        return new Intl.DateTimeFormat(this.effectiveLocale, {
          day: "2-digit",
          month: "2-digit",
          year: "numeric",
          timeZone: "UTC"
        }).format(date);
      }
    }
  }

  parseDisplayValue(displayValue) {
    const text = String(displayValue || "").trim();
    if (!text) {
      return "";
    }

    let order;
    let normalizedText = text;
    switch (this.displayFormat) {
      case "DD.MM.YYYY":
        order = ["day", "month", "year"];
        break;
      case "DD/MM/YYYY":
        order = ["day", "month", "year"];
        break;
      case "MM/DD/YYYY":
        order = ["month", "day", "year"];
        break;
      case "YYYY-MM-DD":
        order = ["year", "month", "day"];
        break;
      default:
        order = this.localeDateOrder;
        normalizedText = this.normalizeLocaleDigits(text);
    }

    const values = normalizedText.match(/\d+/g);
    if (!values || values.length !== 3) {
      return null;
    }
    const parts = Object.fromEntries(order.map((part, index) => [part, values[index]]));
    const normalized = `${String(parts.year).padStart(4, "0")}-${String(parts.month).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}`;
    return validIso(normalized) ? normalized : null;
  }

  get localeDateOrder() {
    const sample = new Date(Date.UTC(2006, 10, 22));
    return new Intl.DateTimeFormat(this.effectiveLocale, {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      timeZone: "UTC"
    })
      .formatToParts(sample)
      .filter((part) => ["day", "month", "year"].includes(part.type))
      .map((part) => part.type);
  }

  normalizeLocaleDigits(value) {
    const formatter = new Intl.NumberFormat(this.effectiveLocale, {
      useGrouping: false
    });
    return [...value]
      .map((character) => {
        const index = Array.from({ length: 10 }, (_, digit) =>
          formatter.format(digit)
        ).indexOf(character);
        return index >= 0 ? String(index) : character;
      })
      .join("");
  }
}
