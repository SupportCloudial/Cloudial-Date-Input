import { api, LightningElement } from "lwc";

const HINT_STYLE_ID = "pb-hide-lni-date-format-hint-global";
let _inputIdSeq = 0;

/**
 * Date field for Package Builder. Fixed dd.mm.yyyy display with a hidden native
 * date input so min/max disable out-of-range days in the calendar.
 * Values are YYYY-MM-DD; parents format for display elsewhere.
 */
export default class PackageBuilderLocaleDateInput extends LightningElement {
  @api value;
  @api min;
  @api max;
  @api label = "";
  @api required = false;
  @api disabled = false;
  @api variant;
  @api inputClass = "";

  displayText = "";
  _hintRefAttached = false;
  _lastCommittedValue = "";
  _displayInputId = `pb-locale-date-display-${++_inputIdSeq}`;

  get displayInputId() {
    return this._displayInputId;
  }

  get displayAriaLabel() {
    return this.label || "Date";
  }

  get showLabel() {
    return this.resolvedVariant !== "label-hidden" && !!this.label;
  }

  get resolvedVariant() {
    const v = this.variant;
    return v != null && v !== "" ? v : undefined;
  }

  get formElementClass() {
    const parts = ["slds-form-element", "pb-locale-date"];
    if (this.resolvedVariant === "label-hidden") {
      parts.push("slds-form-element_stacked");
    }
    return parts.join(" ");
  }

  get displayInputClass() {
    const tokens = ["slds-input", "pb-native-date-input"];
    const extra = String(this.inputClass || "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    return [...tokens, ...extra].join(" ");
  }

  connectedCallback() {
    this._attachGlobalDateFormatHintHide();
    this._hintRefAttached = true;
    this._lastCommittedValue = (this.value || "").trim();
    this._syncDisplayFromValue(this._lastCommittedValue);
  }

  renderedCallback() {
    const v = (this.value || "").trim();
    if (v && this._isYmdInAllowedRange(v)) {
      this._lastCommittedValue = v;
      this._syncDisplayFromValue(v);
      this._syncNativeInputValue(v);
    } else if (v && !this._isYmdInAllowedRange(v)) {
      this._syncNativeInputValue(this._lastCommittedValue || "");
      this._syncDisplayFromValue(this._lastCommittedValue || "");
    } else if (!v) {
      this._lastCommittedValue = "";
      this._syncNativeInputValue("");
      this._syncDisplayFromValue("");
    }
    this._clearNativeValidity();
  }

  _ymdFromApi(value) {
    if (value == null || value === "") {
      return "";
    }
    return String(value).trim().slice(0, 10);
  }

  /** Fixed display: dd.mm.yyyy */
  _ymdToDisplay(ymd) {
    if (!ymd) {
      return "";
    }
    const [y, m, d] = this._ymdFromApi(ymd).split("-");
    if (!y || !m || !d) {
      return "";
    }
    return `${d}.${m}.${y}`;
  }

  _syncDisplayFromValue(ymd) {
    this.displayText = this._ymdToDisplay(ymd);
  }

  _isYmdInAllowedRange(ymd) {
    const v = this._ymdFromApi(ymd);
    if (!v) {
      return true;
    }
    const min = this._ymdFromApi(this.min);
    const max = this._ymdFromApi(this.max);
    if (min && v < min) {
      return false;
    }
    if (max && v > max) {
      return false;
    }
    return true;
  }

  _nativeInput() {
    return this.template.querySelector('[data-id="native-picker"]');
  }

  _clearNativeValidity() {
    const inp = this._nativeInput();
    if (!inp) {
      return;
    }
    inp.setCustomValidity("");
  }

  _syncNativeInputValue(ymd) {
    const inp = this._nativeInput();
    if (!inp) {
      return;
    }
    inp.value = ymd || "";
    this._clearNativeValidity();
  }

  _openPicker() {
    if (this.disabled) {
      return;
    }
    const inp = this._nativeInput();
    if (!inp) {
      return;
    }
    if (typeof inp.showPicker === "function") {
      try {
        inp.showPicker();
        return;
      } catch {
        // Already open, unsupported, or blocked by browser — ignore.
      }
    }
    inp.style.pointerEvents = "auto";
    inp.focus();
    inp.click();
    inp.style.pointerEvents = "none";
  }

  handleControlClick() {
    this._openPicker();
  }

  handleDisplayKeydown(event) {
    if (this.disabled) {
      return;
    }
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this._openPicker();
    }
  }

  disconnectedCallback() {
    if (this._hintRefAttached) {
      this._detachGlobalDateFormatHintHide();
      this._hintRefAttached = false;
    }
  }

  _attachGlobalDateFormatHintHide() {
    if (typeof window === "undefined" || typeof document === "undefined")
      return;
    window._pbHideLniDateFmtRef =
      (Number(window._pbHideLniDateFmtRef) || 0) + 1;
    if (window._pbHideLniDateStyleEl) return;
    const style = document.createElement("style");
    style.id = HINT_STYLE_ID;
    style.textContent =
      "[data-date-format].slds-form-element__help{display:none!important;}";
    document.head.appendChild(style);
    window._pbHideLniDateStyleEl = style;
  }

  _detachGlobalDateFormatHintHide() {
    if (typeof window === "undefined" || typeof document === "undefined")
      return;
    window._pbHideLniDateFmtRef = Math.max(
      0,
      (Number(window._pbHideLniDateFmtRef) || 1) - 1
    );
    if (window._pbHideLniDateFmtRef > 0) return;
    const el = window._pbHideLniDateStyleEl;
    if (el?.parentNode) {
      el.parentNode.removeChild(el);
    }
    window._pbHideLniDateStyleEl = null;
  }

  handleChange(event) {
    const incoming = (event.target?.value ?? "").trim();

    if (incoming && !this._isYmdInAllowedRange(incoming)) {
      event.stopPropagation();
      event.preventDefault();
      const restore = this._lastCommittedValue || "";
      this._syncNativeInputValue(restore);
      this._syncDisplayFromValue(restore);
      return;
    }

    const v = incoming;
    if (v) {
      this._lastCommittedValue = v;
    } else {
      this._lastCommittedValue = "";
    }
    this._syncDisplayFromValue(this._lastCommittedValue);

    // Parents listen for our custom change (detail.value). Stop the native
    // input change from bubbling so handlers are not cleared by a second event.
    event.stopPropagation();
    event.preventDefault();

    this.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { value: v }
      })
    );
  }
}
