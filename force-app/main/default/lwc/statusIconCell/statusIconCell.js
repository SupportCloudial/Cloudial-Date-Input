import { LightningElement, api } from "lwc";

export default class StatusIconCell extends LightningElement {
  @api value;
  @api showCross;
  /** When `showCross` is true, used as `alternative-text` on the cross icon (falls back to "Ended"). */
  @api showCrossAltText;
  /** When true, shows a currency icon (monthly payment total differs from original). */
  @api showMonthlyPricingIcon;
  /** Optional SLDS icon name (e.g. utility:clock) shown after primary status glyphs. */
  @api entryClockIcon;
  /**
   * `grid` — fixed three slots for alignment when any row can show 2+ icons.
   * `compact` — single centered row when every row has at most one icon.
   */
  @api layoutMode;

  /** Custom SVG URL for cross (end before order start / ended). */
  @api statusCrossIconUrl;
  /** Custom SVG for entry date after order start (replaces clock). */
  @api statusEntryAfterStartUrl;
  /** Custom SVG when line end date is before max end date on the order. */
  @api statusFutureEndBeforeMaxUrl;
  /** Custom SVG for monthly financial adjustment (replaces built-in coin). */
  @api statusMonthlyMoneyIconUrl;
  /** Custom SVG for New product (draft). */
  @api statusNewProductIconUrl;

  /** `c-ers-tooltip` messages (same pattern as Terminate Products toolbar). */
  @api tooltipCross = "";
  @api tooltipReplacement = "";
  @api tooltipNewProduct = "";
  @api tooltipFuturePlusEntry = "";
  @api tooltipFutureXOtherProducts = "";
  @api tooltipMoneyFinancial = "";
  @api tooltipModified = "";

  get hasEntryClock() {
    return typeof this.entryClockIcon === "string" && this.entryClockIcon.trim() !== "";
  }

  get crossAlternativeText() {
    const t = typeof this.showCrossAltText === "string" ? this.showCrossAltText.trim() : "";
    return t || "Ended";
  }

  get hasValue() {
    return this.value !== undefined && this.value !== null && this.value !== "";
  }

  /** New/Modified markers or legacy emoji — not the replacement SVG URL (that renders only in `<img>`). */
  get showPrimaryChangeMarkers() {
    return this.hasValue && !this.isImageUrl;
  }

  get isGridLayout() {
    return this.layoutMode !== "compact";
  }

  get isNewItemMarker() {
    return this.value === "\uD83D\uDFE1";
  }

  get isModifiedMarker() {
    return this.value === "\uD83D\uDFE2";
  }

  get isImageUrl() {
    if (!this.hasValue) return false;
    const v = String(this.value).trim();
    if (!v || v.length < 2) return false;
    if (v === "\uD83D\uDFE1" || v === "\uD83D\uDFE2") return false;
    if (/^https?:\/\//i.test(v)) return true;
    if (v.startsWith("//")) return true;
    if (v.startsWith("/")) return true;
    if (v.startsWith("data:")) return true;
    if (/\.svg(\?|#|$)/i.test(v)) return true;
    if (/\/resource\//i.test(v)) return true;
    return false;
  }

  get showCrossAsImage() {
    return this.showCross === true && this._nonEmptyString(this.statusCrossIconUrl);
  }

  get showCrossAsLightning() {
    return this.showCross === true && !this._nonEmptyString(this.statusCrossIconUrl);
  }

  get showEntryAfterStartImage() {
    return this._nonEmptyString(this.statusEntryAfterStartUrl);
  }

  get showPrimaryReplacementImage() {
    return this.isImageUrl;
  }

  get showPrimaryNewImage() {
    return this._nonEmptyString(this.statusNewProductIconUrl);
  }

  get showFutureEndBeforeMaxImage() {
    if (this.showCross === true) {
      return false;
    }
    return this._nonEmptyString(this.statusFutureEndBeforeMaxUrl);
  }

  get showMoneyImage() {
    return this._nonEmptyString(this.statusMonthlyMoneyIconUrl);
  }

  /**
   * Grid layout: render a slot wrapper only when it has glyphs. Previously every row always
   * rendered four `.status-icon-slot` nodes with min-width, plus an empty primary cluster
   * min-width 4.1rem — that created large dead space before the first visible icon.
   */
  get showGridReplacementSlot() {
    return this.showPrimaryReplacementImage;
  }

  get showGridCrossSlot() {
    return this.showCrossAsImage || this.showCrossAsLightning;
  }

  get showGridPrimaryClusterSlot() {
    return this.showPrimaryChangeMarkers || this.showMoneyImage || this.showPrimaryNewImage;
  }

  get showGridPrimaryAuxSubslot() {
    return this.showMoneyImage || this.showPrimaryNewImage;
  }

  get showGridFutureSlot() {
    return this.showFutureEndBeforeMaxImage || this.showEntryAfterStartImage || this.hasEntryClock;
  }

  _nonEmptyString(s) {
    return typeof s === "string" && s.trim() !== "";
  }
}