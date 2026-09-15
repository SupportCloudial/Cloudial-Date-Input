import { api, track } from "lwc";
import LightningModal from "lightning/modal";
import LightningConfirm from "lightning/confirm";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import loadContext from "@salesforce/apex/RecurringPriceIncreaseController.loadContext";
import previewOverlap from "@salesforce/apex/RecurringPriceIncreaseController.previewOverlap";
import saveRuleFields from "@salesforce/apex/RecurringPriceIncreaseController.saveRuleFields";
import enableRules from "@salesforce/apex/RecurringPriceIncreaseController.enableRules";
import enableAndApplyRules from "@salesforce/apex/RecurringPriceIncreaseController.enableAndApplyRules";
import disableRules from "@salesforce/apex/RecurringPriceIncreaseController.disableRules";
import removeRules from "@salesforce/apex/RecurringPriceIncreaseController.removeRules";

const TYPE_PERCENT = "Increase_by_Percentage";
const TYPE_VALUE = "Increase_by_Value";
const CONFIRM_OVERLAP_PREFIX = "CONFIRM_ITERATION_OVERLAP";
const SAVE_TITLE =
  "Saves the rule without enabling it or updating monthly payments.";
const ACTIVATE_RUN_TITLE =
  "Activates and runs the rule on payments using current prices.";
const ACTIVATE_TITLE = "Activates the rule without updating monthly payments.";
const DISABLE_TITLE =
  "Deactivates the rule. Monthly payments stay as they are.";
const REVERT_TITLE =
  "Discards unsaved changes and restores the last saved values.";

const INCREASE_TYPE_OPTIONS = [
  { label: "Increase by Percentage", value: TYPE_PERCENT },
  { label: "Increase by Value", value: TYPE_VALUE }
];

function ymdFromDate(value) {
  if (!value) {
    return null;
  }
  if (typeof value === "string") {
    return value.slice(0, 10);
  }
  try {
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) {
      return null;
    }
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth() + 1).padStart(2, "0");
    const day = String(d.getUTCDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  } catch {
    return null;
  }
}

function todayYmd() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function maxYmd(a, b) {
  if (!a) return b || null;
  if (!b) return a;
  return a >= b ? a : b;
}

function formatMoney(value) {
  if (value == null || value === "") {
    return "";
  }
  const n = Number(value);
  if (Number.isNaN(n)) {
    return String(value);
  }
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });
}

function formatMonth(value) {
  const ymd = ymdFromDate(value);
  if (!ymd) {
    return "";
  }
  const [y, m] = ymd.split("-");
  const monthNames = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec"
  ];
  const idx = Number(m) - 1;
  return monthNames[idx] ? `${monthNames[idx]} ${y}` : ymd;
}

function apexMessage(error) {
  return (
    error?.body?.message ||
    error?.message ||
    (Array.isArray(error?.body)
      ? error.body.map((e) => e.message).join(" ")
      : null) ||
    "Unexpected error"
  );
}

export default class PackageBuilderRecurringPriceIncreaseModal extends LightningModal {
  @api lineIds = [];
  @api isArchived = false;
  @api contractStartDateYmd = null;
  @api readOnly = false;

  increaseTypeOptions = INCREASE_TYPE_OPTIONS;

  @track isLoading = true;
  @track isSaving = false;
  @track isActionBusy = false;
  @track excludedMessage = "";
  @track eligibleLineIds = [];
  @track minStartDateYmd = todayYmd();
  @track frequencyMonths = null;
  @track startDateYmd = null;
  @track increaseType = TYPE_PERCENT;
  @track increaseValue = null;
  @track anyRuleEnabled = false;
  @track previewRows = [];
  @track previewMessage = "";
  @track showPreview = false;

  /** Baseline for Revert (loaded or last Save). */
  _baseline = null;
  @track isDirty = false;

  connectedCallback() {
    this._load();
  }

  renderedCallback() {
    if (this.isLoading) {
      return;
    }
    const freqEl = this.template.querySelector(
      '[data-field="frequencyMonths"]'
    );
    if (
      freqEl &&
      document.activeElement !== freqEl &&
      this.frequencyMonths != null &&
      this.frequencyMonths !== "" &&
      String(freqEl.value || "") === ""
    ) {
      freqEl.value = String(this.frequencyMonths);
    }
    const valueEl = this.template.querySelector('[data-field="increaseValue"]');
    if (
      valueEl &&
      document.activeElement !== valueEl &&
      this.increaseValue != null &&
      this.increaseValue !== "" &&
      String(valueEl.value || "") === ""
    ) {
      valueEl.value = String(this.increaseValue);
    }
  }

  get hasEligibleLines() {
    return !this.isLoading && this.eligibleLineIds.length > 0;
  }

  get isBusy() {
    return this.isLoading || this.isSaving || this.isActionBusy;
  }

  get isSaveDisabled() {
    return this.isBusy || !this.eligibleLineIds.length || this.readOnly;
  }

  get isApplyDisabled() {
    return this.isSaveDisabled;
  }

  get activateRunTitle() {
    return ACTIVATE_RUN_TITLE;
  }

  get saveTitle() {
    return SAVE_TITLE;
  }

  get revertTitle() {
    return REVERT_TITLE;
  }

  get toggleButtonLabel() {
    return this.anyRuleEnabled ? "Disable" : "Activate";
  }

  get toggleTitle() {
    return this.anyRuleEnabled ? DISABLE_TITLE : ACTIVATE_TITLE;
  }

  get isRevertDisabled() {
    return this.isBusy || this.readOnly || !this.isDirty;
  }

  get isToggleDisabled() {
    return this.isBusy || this.readOnly || !this.eligibleLineIds.length;
  }

  get isRemoveDisabled() {
    return (
      this.isBusy ||
      this.readOnly ||
      !this.eligibleLineIds.length ||
      !this.anyRuleEnabled
    );
  }

  get increaseValueLabel() {
    return this.increaseType === TYPE_VALUE
      ? "Increase amount"
      : "Increase percent";
  }

  get increaseValueStep() {
    return this.increaseType === TYPE_VALUE ? "0.01" : "any";
  }

  get previewTableRows() {
    return (this.previewRows || []).map((row, idx) => ({
      key: `${row.lineId || "row"}-${row.overlapMonth || idx}-${idx}`,
      productName: row.productName || "",
      overlapMonthLabel: formatMonth(row.overlapMonth),
      listPriceLabel: formatMoney(row.listPrice),
      afterIterationLabel: formatMoney(row.afterIteration),
      afterRecurringLabel: formatMoney(row.afterRecurring),
      finalPriceLabel: formatMoney(row.finalPrice)
    }));
  }

  get hasPreviewRows() {
    return this.showPreview && this.previewTableRows.length > 0;
  }

  handleFieldChange(event) {
    const host = event.currentTarget || event.target;
    const field = host?.dataset?.field || event.target?.dataset?.field;
    // Native inputs: prefer target.value (fires on input). lightning-*: detail.value.
    let value =
      event.target?.value !== undefined && event.target?.tagName === "INPUT"
        ? event.target.value
        : event.detail?.value;
    if (value === undefined || value === null || value === "") {
      const live = this._readLiveFieldValue(host);
      if (live !== undefined) {
        value = live;
      } else if (event.target?.value !== undefined) {
        value = event.target.value;
      }
    }
    if (field === "frequencyMonths") {
      this.frequencyMonths = value === "" || value == null ? null : value;
    } else if (field === "startDate") {
      this.startDateYmd = value || null;
    } else if (field === "increaseType") {
      this.increaseType = value;
    } else if (field === "increaseValue") {
      this.increaseValue = value === "" || value == null ? null : value;
    }
    this.showPreview = false;
    this.previewRows = [];
    this.previewMessage = "";
    this._refreshDirty();
  }

  handleRevert() {
    if (this.isRevertDisabled || !this._baseline) {
      return;
    }
    this.frequencyMonths = this._baseline.frequencyMonths;
    this.startDateYmd = this._baseline.startDateYmd;
    this.increaseType = this._baseline.increaseType;
    this.increaseValue = this._baseline.increaseValue;
    this.showPreview = false;
    this.previewRows = [];
    this.previewMessage = "";
    this._syncDomFromState();
    this._refreshDirty();
  }

  async handleSave() {
    if (this.isSaveDisabled) {
      return;
    }
    const draft = this._prepareDraft();
    if (!draft) {
      return;
    }

    this.isSaving = true;
    try {
      await this._saveFieldsOnly(draft);
    } catch (e) {
      this._toast("Error", apexMessage(e), "error");
    } finally {
      this.isSaving = false;
    }
  }

  async handleActivateAndRun() {
    if (this.isApplyDisabled) {
      return;
    }
    const draft = this._prepareDraft();
    if (!draft) {
      return;
    }

    this.isSaving = true;
    try {
      const preview = await previewOverlap({
        lineIds: this.eligibleLineIds,
        draftJson: JSON.stringify(draft)
      });
      if (preview?.hasOverlap) {
        this.previewRows = preview.rows || [];
        this.previewMessage = preview.message || "";
        this.showPreview = true;
        const confirmed = await LightningConfirm.open({
          label: "Confirm iteration overlap?",
          message:
            (preview.message ||
              "A recurring step falls in the same month as an Iteration period start. Iteration applies first, then recurring.") +
            " Apply anyway?",
          variant: "header"
        });
        if (!confirmed) {
          return;
        }
        await this._activateAndRun(draft, true);
      } else {
        this.showPreview = false;
        this.previewRows = [];
        this.previewMessage = "";
        await this._activateAndRun(draft, false);
      }
    } catch (e) {
      const message = apexMessage(e);
      if (message && message.includes(CONFIRM_OVERLAP_PREFIX)) {
        this._toast(
          "Warning",
          "Iteration overlap detected. Review the preview and confirm to apply.",
          "warning"
        );
        try {
          const preview = await previewOverlap({
            lineIds: this.eligibleLineIds,
            draftJson: JSON.stringify(draft)
          });
          this.previewRows = preview?.rows || [];
          this.previewMessage = preview?.message || message;
          this.showPreview = true;
        } catch {
          this.previewMessage = message;
          this.showPreview = true;
        }
      } else {
        this._toast("Error", message, "error");
      }
    } finally {
      this.isSaving = false;
    }
  }

  _prepareDraft() {
    const active = this.template.activeElement;
    if (active && typeof active.blur === "function") {
      active.blur();
    }
    return this._buildDraft();
  }

  async handleToggleActivation() {
    if (this.isToggleDisabled) {
      return;
    }
    if (this.anyRuleEnabled) {
      await this.handleDisable();
      return;
    }
    const draft = this._prepareDraft();
    if (!draft) {
      return;
    }
    this.isActionBusy = true;
    try {
      await this._activateOnly(draft);
      this.anyRuleEnabled = true;
    } catch (e) {
      this._toast("Error", apexMessage(e), "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async handleDisable() {
    if (this.isToggleDisabled || !this.anyRuleEnabled) {
      return;
    }
    const confirmed = await LightningConfirm.open({
      label: "Disable recurring price increase?",
      message:
        "Disable the rule but keep values. Monthly payments stay as-is. Re-enable with Activate or Activate and Run.",
      variant: "header"
    });
    if (!confirmed) {
      return;
    }
    this.isActionBusy = true;
    try {
      const result = await disableRules({
        lineIds: this.eligibleLineIds,
        isArchived: this.isArchived === true
      });
      this.anyRuleEnabled = false;
      this._toast("Success", result?.message || "Rule disabled.", "success");
    } catch (e) {
      this._toast("Error", apexMessage(e), "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async handleRemove() {
    if (this.isRemoveDisabled) {
      return;
    }
    const confirmed = await LightningConfirm.open({
      label: "Remove recurring price increase?",
      message:
        "Disable and clear rule values. Monthly payments stay as-is and will not consult the rule going forward.",
      variant: "header",
      theme: "error"
    });
    if (!confirmed) {
      return;
    }
    this.isActionBusy = true;
    try {
      const result = await removeRules({
        lineIds: this.eligibleLineIds,
        isArchived: this.isArchived === true
      });
      this._toast("Success", result?.message || "Rule removed.", "success");
      this.close({ saved: true, action: "remove" });
    } catch (e) {
      this._toast("Error", apexMessage(e), "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async _load() {
    this.isLoading = true;
    try {
      const result = await loadContext({
        lineIds: this.lineIds || [],
        isArchived: this.isArchived === true
      });
      if (result?.archivedBlocked) {
        this._toast(
          "Error",
          result.excludedMessage ||
            "Recurring price increase cannot be edited on archived orders.",
          "error"
        );
        this.close({ saved: false });
        return;
      }
      this.excludedMessage = result?.excludedMessage || "";
      this.eligibleLineIds = result?.eligibleLineIds || [];
      this.anyRuleEnabled = result?.anyRuleEnabled === true;
      const loadedMin = ymdFromDate(result?.minStartDate) || todayYmd();
      this.minStartDateYmd = maxYmd(
        loadedMin,
        maxYmd(todayYmd(), this.contractStartDateYmd)
      );
      if (!this.eligibleLineIds.length) {
        this._toast(
          "Error",
          this.excludedMessage || "No Monthly or Periodic products selected.",
          "error"
        );
        this.close({ saved: false });
        return;
      }
      if (this.excludedMessage) {
        this._toast("Info", this.excludedMessage, "info");
      }
      this.frequencyMonths =
        result?.frequencyMonths != null ? result.frequencyMonths : null;
      this.startDateYmd = maxYmd(
        ymdFromDate(result?.startDate) || this.minStartDateYmd,
        this.minStartDateYmd
      );
      this.increaseType = result?.increaseType || TYPE_PERCENT;
      if (this.increaseType === TYPE_VALUE) {
        this.increaseValue =
          result?.increaseAmount != null ? result.increaseAmount : null;
      } else {
        this.increaseValue = this._percentForDisplay(result?.increasePercent);
      }
      this._captureBaseline();
      this._refreshDirty();
    } catch (e) {
      this._toast("Error", apexMessage(e), "error");
      this.close({ saved: false });
    } finally {
      this.isLoading = false;
    }
  }

  _captureBaseline() {
    this._baseline = {
      frequencyMonths:
        this.frequencyMonths != null && this.frequencyMonths !== ""
          ? String(this.frequencyMonths)
          : null,
      startDateYmd: this.startDateYmd || null,
      increaseType: this.increaseType || TYPE_PERCENT,
      increaseValue:
        this.increaseValue != null && this.increaseValue !== ""
          ? String(this.increaseValue)
          : null
    };
  }

  _refreshDirty() {
    if (!this._baseline) {
      this.isDirty = false;
      return;
    }
    const freq =
      this.frequencyMonths != null && this.frequencyMonths !== ""
        ? String(this.frequencyMonths)
        : null;
    const val =
      this.increaseValue != null && this.increaseValue !== ""
        ? String(this.increaseValue)
        : null;
    this.isDirty =
      freq !== this._baseline.frequencyMonths ||
      (this.startDateYmd || null) !== this._baseline.startDateYmd ||
      (this.increaseType || TYPE_PERCENT) !== this._baseline.increaseType ||
      val !== this._baseline.increaseValue;
  }

  _syncDomFromState() {
    const freqEl = this.template.querySelector(
      '[data-field="frequencyMonths"]'
    );
    if (freqEl) {
      freqEl.value =
        this.frequencyMonths != null ? String(this.frequencyMonths) : "";
    }
    const valueEl = this.template.querySelector('[data-field="increaseValue"]');
    if (valueEl) {
      valueEl.value =
        this.increaseValue != null ? String(this.increaseValue) : "";
    }
  }

  _percentForDisplay(raw) {
    if (raw == null || raw === "") {
      return null;
    }
    const n = Number(raw);
    if (Number.isNaN(n)) {
      return null;
    }
    return Math.abs(n) <= 1 ? n * 100 : n;
  }

  _readLiveFieldValue(el) {
    if (!el) {
      return undefined;
    }
    // lightning-input keeps typed digits in the inner <input> until blur/change;
    // host .value can still be the stale bound property (often null).
    try {
      const native = el.shadowRoot?.querySelector("input, textarea, select");
      if (native && native.value !== undefined && native.value !== null) {
        const raw = String(native.value).trim();
        if (raw !== "") {
          return raw;
        }
      }
    } catch {
      // Closed shadow or unsupported host - fall through to el.value.
    }
    if (el.value !== undefined && el.value !== null && el.value !== "") {
      return el.value;
    }
    if (typeof el.getValue === "function") {
      const viaGetter = el.getValue();
      if (viaGetter !== undefined && viaGetter !== null && viaGetter !== "") {
        return viaGetter;
      }
    }
    return undefined;
  }

  _syncFormFromDom() {
    const freqEl = this.template.querySelector(
      '[data-field="frequencyMonths"]'
    );
    if (freqEl) {
      const freqRaw =
        freqEl.value !== undefined &&
        freqEl.value !== null &&
        freqEl.value !== ""
          ? freqEl.value
          : this._readLiveFieldValue(freqEl);
      if (freqRaw !== undefined && freqRaw !== null && freqRaw !== "") {
        this.frequencyMonths = freqRaw;
      }
    }
    const valueEl = this.template.querySelector('[data-field="increaseValue"]');
    if (valueEl) {
      const valueRaw =
        valueEl.value !== undefined &&
        valueEl.value !== null &&
        valueEl.value !== ""
          ? valueEl.value
          : this._readLiveFieldValue(valueEl);
      if (valueRaw !== undefined && valueRaw !== null && valueRaw !== "") {
        this.increaseValue = valueRaw;
      }
    }
    const typeEl = this.template.querySelector('[data-field="increaseType"]');
    if (typeEl && typeEl.value) {
      this.increaseType = typeEl.value;
    }
    const startEl = this.template.querySelector('[data-field="startDate"]');
    if (startEl) {
      const startVal =
        this._readLiveFieldValue(startEl) ??
        startEl.value ??
        startEl.getValue?.();
      if (startVal) {
        this.startDateYmd = startVal;
      }
    }
  }

  _toPositiveInt(value) {
    if (value === null || value === undefined || value === "") {
      return null;
    }
    const raw = String(value).trim().replace(",", ".");
    if (!raw) {
      return null;
    }
    const n = Number(raw);
    if (!Number.isFinite(n) || n <= 0) {
      return null;
    }
    // Accept 3 / "3" / "3.0"; reject 3.5 (tolerate float noise)
    const whole = Math.round(n);
    if (Math.abs(n - whole) > 1e-9) {
      return null;
    }
    return whole;
  }

  _buildDraft() {
    this._syncFormFromDom();
    const freqEl = this.template.querySelector(
      '[data-field="frequencyMonths"]'
    );
    const freqRaw =
      freqEl && freqEl.value !== undefined && freqEl.value !== null
        ? freqEl.value
        : this.frequencyMonths;
    this.frequencyMonths = freqRaw;
    const freq = this._toPositiveInt(freqRaw);
    if (freq == null) {
      this._toast(
        "Error",
        "Frequency must be a positive whole number of months.",
        "error"
      );
      return null;
    }
    if (!this.startDateYmd) {
      this._toast("Error", "Start date is required.", "error");
      return null;
    }
    if (this.startDateYmd < this.minStartDateYmd) {
      this._toast(
        "Error",
        `Start date must be on or after ${this.minStartDateYmd} (max of today and contract/opportunity start).`,
        "error"
      );
      return null;
    }
    if (
      this.increaseType !== TYPE_PERCENT &&
      this.increaseType !== TYPE_VALUE
    ) {
      this._toast("Error", "Increase type is required.", "error");
      return null;
    }
    if (
      this.increaseValue === null ||
      this.increaseValue === undefined ||
      this.increaseValue === ""
    ) {
      this._toast("Error", "Increase value is required.", "error");
      return null;
    }
    const valueNum = Number(this.increaseValue);
    if (!Number.isFinite(valueNum)) {
      this._toast("Error", "Increase value must be a number.", "error");
      return null;
    }

    const draft = {
      frequencyMonths: Number(freq),
      startDate: this.startDateYmd,
      increaseType: this.increaseType,
      increasePercent: null,
      increaseAmount: null
    };
    if (this.increaseType === TYPE_PERCENT) {
      draft.increasePercent = valueNum;
    } else {
      draft.increaseAmount = valueNum;
    }
    return draft;
  }

  async _saveFieldsOnly(draft) {
    const result = await saveRuleFields({
      lineIds: this.eligibleLineIds,
      draftJson: JSON.stringify(draft),
      isArchived: this.isArchived === true
    });
    const skipped = (result?.skippedMessages || []).join(" ");
    const message = [result?.message, skipped].filter(Boolean).join(" ");
    this._captureBaseline();
    this._refreshDirty();
    this._toast(
      "Success",
      message || "Recurring price increase rule saved.",
      "success"
    );
  }

  async _activateOnly(draft) {
    const result = await enableRules({
      lineIds: this.eligibleLineIds,
      draftJson: JSON.stringify(draft),
      isArchived: this.isArchived === true
    });
    const skipped = (result?.skippedMessages || []).join(" ");
    const message = [result?.message, skipped].filter(Boolean).join(" ");
    this._captureBaseline();
    this._refreshDirty();
    this._toast(
      "Success",
      message || "Recurring price increase activated.",
      "success"
    );
  }

  async _activateAndRun(draft, confirmOverlap) {
    const result = await enableAndApplyRules({
      lineIds: this.eligibleLineIds,
      draftJson: JSON.stringify(draft),
      isArchived: this.isArchived === true,
      confirmOverlap: confirmOverlap === true
    });
    const skipped = (result?.skippedMessages || []).join(" ");
    const message = [result?.message, skipped].filter(Boolean).join(" ");
    this._toast(
      "Success",
      message || "Recurring price increase activated and applied.",
      "success"
    );
    this.close({ saved: true, action: "apply", result });
  }

  _toast(title, message, variant) {
    const toast = { title, message, variant };
    if (variant === "success" || variant === "info" || variant === "warning") {
      toast.mode = "dismissable";
    }
    this.dispatchEvent(new ShowToastEvent(toast));
  }
}
