import getMonthlyPayments from "@salesforce/apex/PackageBuilderService.getMonthlyPayments";
import ensureMonthlyPaymentsForLineItems from "@salesforce/apex/PackageBuilderService.ensureMonthlyPaymentsForLineItems";
import updateDiscount from "@salesforce/apex/PackageBuilderService.updateDiscountWithEnteredPercentages";
import applyBulkAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.applyBulkAdjustment";
import applyIndividualAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.applyIndividualAdjustment";
import previewIndividualAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.previewIndividualAdjustment";
import { onError, subscribe, unsubscribe } from "lightning/empApi";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { getRecord } from "lightning/uiRecordApi";
import { api, LightningElement, track, wire } from "lwc";
import packageBuilderRecurringPriceIncreaseModal from "c/packageBuilderRecurringPriceIncreaseModal";

import allProducts from "@salesforce/label/c.cp_allProducts";
import allTime from "@salesforce/label/c.cp_allTime";
import emptyPaymentsMessage from "@salesforce/label/c.PackageBuilder_MonthlyPayments_Empty";
import emptyPaymentsHint from "@salesforce/label/c.PackageBuilder_MonthlyPayments_EmptyHint";
import endDate_label from "@salesforce/label/c.cp_oppDiscount_endDate";
import finalPrice from "@salesforce/label/c.cp_finalPrice";
import helpText from "@salesforce/label/c.cp_HelpText";
import listPrice from "@salesforce/label/c.cp_listPrice";
import priceAdj from "@salesforce/label/c.cp_OppTable_PriceAdj";
import startDate_label from "@salesforce/label/c.cp_oppDiscount_startDate";
import adjustmentAdd from "@salesforce/label/c.MonthlyPayment_Adjustment_Add";
import adjustmentAddHelp from "@salesforce/label/c.MonthlyPayment_Adjustment_AddHelp";
import adjustmentAction from "@salesforce/label/c.MonthlyPayment_Adjustment_Action";
import adjustmentCalculatingPreview from "@salesforce/label/c.MonthlyPayment_Adjustment_CalculatingPreview";
import adjustmentCancel from "@salesforce/label/c.MonthlyPayment_Adjustment_Cancel";
import adjustmentConfirm from "@salesforce/label/c.MonthlyPayment_Adjustment_Confirm";
import adjustmentEnteredAdjustment from "@salesforce/label/c.MonthlyPayment_Adjustment_EnteredAdjustment";
import adjustmentExistingAdjustment from "@salesforce/label/c.MonthlyPayment_Adjustment_ExistingAdjustment";
import adjustmentFinalPriceAfter from "@salesforce/label/c.MonthlyPayment_Adjustment_FinalPriceAfter";
import adjustmentOriginalPrice from "@salesforce/label/c.MonthlyPayment_Adjustment_OriginalPrice";
import adjustmentPreviewTitle from "@salesforce/label/c.MonthlyPayment_AdjustmentPreview_Title";
import adjustmentPriceBefore from "@salesforce/label/c.MonthlyPayment_Adjustment_PriceBefore";
import adjustmentRecurringAddWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_RecurringAddWarning";
import adjustmentRecurringReplaceWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_RecurringReplaceWarning";
import adjustmentReplace from "@salesforce/label/c.MonthlyPayment_Adjustment_Replace";
import adjustmentReplaceHelp from "@salesforce/label/c.MonthlyPayment_Adjustment_ReplaceHelp";
import adjustmentResultingAdjustment from "@salesforce/label/c.MonthlyPayment_Adjustment_ResultingAdjustment";
import adjustmentSelectedAction from "@salesforce/label/c.MonthlyPayment_Adjustment_SelectedAction";
import adjustmentStaleError from "@salesforce/label/c.MonthlyPayment_Adjustment_StaleError";
import adjustmentAmountAddHelp from "@salesforce/label/c.MonthlyPayment_Adjustment_AmountAddHelp";
import adjustmentAmountPreviewTitle from "@salesforce/label/c.MonthlyPayment_AdjustmentAmountPreview_Title";
import adjustmentAmountRecurringAddWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_AmountRecurringAddWarning";
import adjustmentAmountReplaceHelp from "@salesforce/label/c.MonthlyPayment_Adjustment_AmountReplaceHelp";
import adjustmentBulkAddWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_BulkAddWarning";
import adjustmentBulkStaleError from "@salesforce/label/c.MonthlyPayment_Adjustment_BulkStaleError";
import adjustmentMixedEditError from "@salesforce/label/c.MonthlyPayment_Adjustment_MixedEditError";
import { isUsageBased as isUsageBasedAccessType } from "c/accessTypePolicy";

function discountFromSf(raw) {
  const n = Number(raw);
  if (raw == null || raw === "" || Number.isNaN(n)) {
    return 0;
  }
  return Math.abs(n) < 1 ? n * 100 : n;
}

function discountToSf(displayPercent) {
  const n = Number(displayPercent);
  if (Number.isNaN(n)) {
    return 0;
  }
  return n;
}

function normalizePercent(value) {
  const n = Number(value);
  if (Number.isNaN(n)) {
    return 0;
  }
  return Math.round(n * 100) / 100;
}

function roundMoney(value) {
  const n = Number(value);
  if (Number.isNaN(n)) {
    return 0;
  }
  return Math.round(n * 100) / 100;
}

/** Usage Based amount from server; ListPrice__c distinguishes unset (null) vs explicit zero. */
function usageFinalFromPayment(payment) {
  const lp = payment?.ListPrice__c;
  if (lp == null || lp === "") {
    return null;
  }
  const n = parseFloat(lp);
  if (Number.isFinite(n)) {
    return roundMoney(n);
  }
  const fp = parseFloat(payment?.FinalPrice__c);
  if (Number.isFinite(fp)) {
    return roundMoney(fp);
  }
  return null;
}

function paymentIsUsageBased(payment) {
  return (
    isUsageBasedAccessType(payment?.Access_Type__c) ||
    isUsageBasedAccessType(payment?.OrderItem__r?.Access_Type__c) ||
    isUsageBasedAccessType(payment?.OpportunityLineItem__r?.Access_Type__c)
  );
}

function recurringPricingApplies(payment) {
  const monthStart = payment?.Start_date__c
    ? new Date(payment.Start_date__c)
    : null;
  if (!monthStart || Number.isNaN(monthStart.getTime())) {
    return false;
  }
  const paymentMonth = new Date(
    monthStart.getFullYear(),
    monthStart.getMonth(),
    1
  );
  const orderItem = payment?.OrderItem__r;
  if (orderItem?.Recurring_Price_Increase_Enabled__c === true) {
    const startDate = orderItem.Recurring_Increase_Start_Date__c
      ? new Date(orderItem.Recurring_Increase_Start_Date__c)
      : null;
    if (startDate && !Number.isNaN(startDate.getTime())) {
      const ruleMonth = new Date(
        startDate.getFullYear(),
        startDate.getMonth(),
        1
      );
      return paymentMonth >= ruleMonth;
    }
  }
  const oppLine = payment?.OpportunityLineItem__r;
  if (oppLine?.Recurring_Price_Increase_Enabled__c === true) {
    const startDate = oppLine.Recurring_Increase_Start_Date__c
      ? new Date(oppLine.Recurring_Increase_Start_Date__c)
      : null;
    if (startDate && !Number.isNaN(startDate.getTime())) {
      const ruleMonth = new Date(
        startDate.getFullYear(),
        startDate.getMonth(),
        1
      );
      return paymentMonth >= ruleMonth;
    }
  }
  return false;
}

export default class MonthlyPaymentTable extends LightningElement {
  @track monthlyPayments = [];
  @track filteredMonthlyPayments = [];
  @api recordId;
  @api productsDate = [];
  @api readOnly = false;
  /** Concluded Terms (active) tab: standard columns read-only; Usage Based columns stay editable. */
  @api concludedTermsActiveTab = false;
  @api showPriceOptimizerFields = false;
  @api priceChangeMode = false;
  @api contractStartDateYmd = null;
  @api contractEndDateYmd = null;
  /** When true, recurring rule modal is blocked (archived / previous-order context). */
  @api isArchived = false;

  deskPriceInput = "";
  productPriceInput = "";
  discountAmountInput = "";
  _priceFieldsInitialized = false;
  _linkedProductPriceBaseline = null;
  _linkedDeskPriceBaseline = null;

  get showLinkedPriceFields() {
    return (
      this.showPriceOptimizerFields &&
      this.canEdit &&
      this.hasSingleProductSelection
    );
  }

  get hasSingleProductSelection() {
    return (
      Array.isArray(this.selectedProducts) && this.selectedProducts.length === 1
    );
  }

  get showOptimizerAdjustmentField() {
    return !this.showLinkedPriceFields;
  }

  get selectedQuantityForPriceFields() {
    const meta = (this.selectedLineItemMeta || [])[0];
    return Number(meta?.deskcount ?? 0) || 0;
  }

  get canEdit() {
    return !this.readOnly;
  }

  get showGlobalReadOnlyBanner() {
    return this.readOnly && !this.concludedTermsActiveTab;
  }

  get showBulkOptimizer() {
    return this._hasStandardSelectedProducts();
  }

  _hasStandardSelectedProducts() {
    for (const id of this.selectedProducts || []) {
      if (!this._isUsageBasedProductId(id)) {
        return true;
      }
    }
    return false;
  }

  _isUsageBasedProductId(productId) {
    const norm = this._normalizeLineItemId(productId);
    const meta = this._selectionMetaByNormId.get(norm);
    if (isUsageBasedAccessType(meta?.accessType)) {
      return true;
    }
    return false;
  }

  _standardColumnReadOnly(productId) {
    return (
      this.readOnly ||
      (this.concludedTermsActiveTab && !this._isUsageBasedProductId(productId))
    );
  }

  _todayYmd() {
    const d = new Date();
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  /** Usage Based: locked only when payment month is before the current calendar month. */
  _isUsageBasedPastPaymentMonth(startDate) {
    const monthStart = this._parseYmd(startDate);
    if (!monthStart) {
      return false;
    }
    const today = new Date();
    const startYm = monthStart.getFullYear() * 12 + (monthStart.getMonth() + 1);
    const todayYm = today.getFullYear() * 12 + (today.getMonth() + 1);
    return startYm < todayYm;
  }

  _isUsageBasedFinalPriceEditable(cell) {
    if (!cell?.usageBased || this.readOnly || !cell) {
      return false;
    }
    return !this._isUsageBasedPastPaymentMonth(cell.startDate);
  }

  @track selectedProducts = [];
  _selectedLineItemIds = [];
  _selectionMetaByNormId = new Map();

  @api
  get selectedLineItemIds() {
    return this._selectedLineItemIds;
  }
  set selectedLineItemIds(value) {
    const ids = Array.isArray(value) ? value : [];
    this._selectedLineItemIds = [...new Set(ids.filter((id) => !!id))];
    this.selectedProducts = [...this._selectedLineItemIds];
    if (this.showPriceOptimizerFields && this.selectedProducts.length === 1) {
      this._initLinkedPriceFields();
    }
    if (Array.isArray(this.monthlyPayments) && this.monthlyPayments.length) {
      this.applySelectionFilter();
    }
  }

  @api
  get selectedLineItemMeta() {
    return [...this._selectionMetaByNormId.values()];
  }
  set selectedLineItemMeta(value) {
    const next = new Map();
    (Array.isArray(value) ? value : []).forEach((item) => {
      const id = item?.id;
      if (!id) {
        return;
      }
      const norm = this._normalizeLineItemId(id);
      next.set(norm, {
        id,
        displayName: item.displayName || item.name || String(id),
        deskcount: Number(item.deskcount ?? item.deskCount ?? 0) || 0,
        unitPrice: Number(item.unitPrice ?? item.UnitPrice ?? 0) || 0,
        totalPrice: Number(item.totalPrice ?? item.TotalPrice ?? 0) || 0,
        accessType: item.accessType || item.Access_Type__c || ""
      });
    });
    this._selectionMetaByNormId = next;
  }

  get hasSelection() {
    return (
      Array.isArray(this.selectedProducts) && this.selectedProducts.length > 0
    );
  }

  get showRecurringPriceIncreaseButton() {
    // Hide on fully read-only views (e.g. Closed Won Opportunity). Keep on
    // Contract Concluded Terms where standard columns are view-only but rules still apply.
    return this.hasSelection && !this.showGlobalReadOnlyBanner;
  }

  _normalizeLineItemId(id) {
    if (id == null || id === "") {
      return "";
    }
    const s = String(id).trim();
    return s.length === 18 ? s.slice(0, 15) : s;
  }

  _isLineItemSelected(roomId, selectedProducts) {
    const normRoom = this._normalizeLineItemId(roomId);
    if (!normRoom) {
      return false;
    }
    for (const id of selectedProducts || []) {
      if (this._normalizeLineItemId(id) === normRoom) {
        return true;
      }
    }
    return false;
  }

  get hasMatchingPaymentsForSelection() {
    if (!this.hasSelection) {
      return false;
    }
    if (
      !Array.isArray(this.monthlyPayments) ||
      this.monthlyPayments.length === 0
    ) {
      return false;
    }
    for (const monthYear of this.monthlyPayments) {
      for (const p of monthYear.data || []) {
        if (this._isLineItemSelected(p.room, this.selectedProducts)) {
          return true;
        }
      }
    }
    return false;
  }

  get showPaymentsWorkspace() {
    return this.hasMatchingPaymentsForSelection;
  }

  @track _isLoadingPayments = false;

  get isLoadingPayments() {
    return this._isLoadingPayments;
  }

  get showEmptyState() {
    return (
      this.hasSelection &&
      !this._isLoadingPayments &&
      !this.hasMatchingPaymentsForSelection
    );
  }

  customLabels = {
    startDate_label,
    endDate_label,
    listPrice,
    priceAdj,
    helpText,
    finalPrice,
    allProducts,
    allTime,
    emptyPaymentsMessage,
    emptyPaymentsHint,
    adjustmentAdd,
    adjustmentAddHelp,
    adjustmentAction,
    adjustmentCalculatingPreview,
    adjustmentCancel,
    adjustmentConfirm,
    adjustmentEnteredAdjustment,
    adjustmentExistingAdjustment,
    adjustmentFinalPriceAfter,
    adjustmentOriginalPrice,
    adjustmentPreviewTitle,
    adjustmentPriceBefore,
    adjustmentRecurringAddWarning,
    adjustmentRecurringReplaceWarning,
    adjustmentReplace,
    adjustmentReplaceHelp,
    adjustmentResultingAdjustment,
    adjustmentSelectedAction,
    adjustmentStaleError,
    adjustmentAmountAddHelp,
    adjustmentAmountPreviewTitle,
    adjustmentAmountRecurringAddWarning,
    adjustmentAmountReplaceHelp,
    adjustmentBulkAddWarning,
    adjustmentBulkStaleError,
    adjustmentMixedEditError
  };

  @track adjustmentPreview = null;
  @track adjustmentPreviewLoading = false;
  adjustmentAction = "Replace";
  bulkAdjustmentAction = "Replace";
  _pendingIndividualCell = null;

  get showAdjustmentPreview() {
    return this.adjustmentPreviewLoading || this.adjustmentPreview != null;
  }

  get showAdjustmentPreviewInitialLoading() {
    return this.adjustmentPreviewLoading && this.adjustmentPreview == null;
  }

  get showAdjustmentPreviewRefreshing() {
    return this.adjustmentPreviewLoading && this.adjustmentPreview != null;
  }

  get adjustmentPreviewPanelClass() {
    return this.showAdjustmentPreviewRefreshing
      ? "adjustment-preview-panel adjustment-preview-panel_refreshing"
      : "adjustment-preview-panel";
  }

  get adjustmentActionOptions() {
    return [
      { label: this.customLabels.adjustmentReplace, value: "Replace" },
      { label: this.customLabels.adjustmentAdd, value: "Add" }
    ];
  }

  get adjustmentActionHelp() {
    if (this.adjustmentPreview?.inputType === "Amount") {
      return this.adjustmentAction === "Add"
        ? this.customLabels.adjustmentAmountAddHelp
        : this.customLabels.adjustmentAmountReplaceHelp;
    }
    return this.adjustmentAction === "Add"
      ? this.customLabels.adjustmentAddHelp
      : this.customLabels.adjustmentReplaceHelp;
  }

  get adjustmentActionLabel() {
    return this.adjustmentAction === "Add"
      ? this.customLabels.adjustmentAdd
      : this.customLabels.adjustmentReplace;
  }

  get adjustmentRecurringWarning() {
    if (!this.adjustmentPreview?.recurringPricingActive) {
      return "";
    }
    if (this.adjustmentAction !== "Add") {
      return this.customLabels.adjustmentRecurringReplaceWarning;
    }
    return this.adjustmentPreview?.inputType === "Amount"
      ? this.customLabels.adjustmentAmountRecurringAddWarning
      : this.customLabels.adjustmentRecurringAddWarning;
  }

  get adjustmentPreviewOutcome() {
    return this.adjustmentPreview?.calculatedOutcome || {};
  }

  get adjustmentPreviewTitle() {
    const inputType =
      this.adjustmentPreview?.inputType ||
      this._pendingIndividualCell?.inputType;
    return inputType === "Amount"
      ? this.customLabels.adjustmentAmountPreviewTitle
      : this.customLabels.adjustmentPreviewTitle;
  }

  get showBulkReplaceAddChoice() {
    if (!this.showBulkOptimizer || this.readOnly) {
      return false;
    }
    return this._inRangeSelectedCells().some(({ cell, month, year }) => {
      const existing = this._getCommittedCellDiscount(month, year, cell.room);
      return Number.isFinite(existing) && existing !== 0;
    });
  }

  get bulkAdjustmentActionHelp() {
    if (this.isFormatAmount) {
      return this.bulkAdjustmentAction === "Add"
        ? this.customLabels.adjustmentAmountAddHelp
        : this.customLabels.adjustmentAmountReplaceHelp;
    }
    return this.bulkAdjustmentAction === "Add"
      ? this.customLabels.adjustmentAddHelp
      : this.customLabels.adjustmentReplaceHelp;
  }

  get bulkAddWarning() {
    if (
      this.bulkAdjustmentAction !== "Add" ||
      (!this.showBulkReplaceAddChoice && !this.showBulkToolbarReplaceAddChoice)
    ) {
      return "";
    }
    return this.customLabels.adjustmentBulkAddWarning;
  }

  get showBulkSaveReplaceAddChoice() {
    const candidate = this._bulkAdjustmentCandidate();
    if (!candidate) {
      return false;
    }
    return candidate.items.some(({ cell, month, year }) => {
      const existing = this._getCommittedCellDiscount(month, year, cell.room);
      return Number.isFinite(existing) && existing !== 0;
    });
  }

  get showBulkToolbarReplaceAddChoice() {
    return this.showBulkSaveReplaceAddChoice && !this.showBulkReplaceAddChoice;
  }

  _bulkRecurringCells() {
    const cells = this._inRangeSelectedCells().map(({ cell }) => cell);
    const candidate = this._bulkAdjustmentCandidate();
    if (candidate) {
      candidate.items.forEach(({ cell }) => {
        if (!cells.some((existing) => existing.id === cell.id)) {
          cells.push(cell);
        }
      });
    }
    return cells;
  }

  get bulkRecurringWarning() {
    if (
      !this.showBulkReplaceAddChoice &&
      !this.showBulkToolbarReplaceAddChoice
    ) {
      return "";
    }
    const hasRecurring = this._bulkRecurringCells().some(
      (cell) => cell.recurringPricingActive === true
    );
    if (!hasRecurring) {
      return "";
    }
    if (this.bulkAdjustmentAction !== "Add") {
      return this.customLabels.adjustmentRecurringReplaceWarning;
    }
    return this.isFormatAmount
      ? this.customLabels.adjustmentAmountRecurringAddWarning
      : this.customLabels.adjustmentRecurringAddWarning;
  }

  get adjustmentValueSuffix() {
    return this.adjustmentPreview?.inputType === "Percentage" ? "%" : "";
  }

  get adjustmentExistingDisplay() {
    return `${this.adjustmentPreviewOutcome.existingAdjustment ?? ""}${
      this.adjustmentValueSuffix
    }`;
  }

  get adjustmentEnteredDisplay() {
    return `${this.adjustmentPreview?.inputValue ?? ""}${
      this.adjustmentValueSuffix
    }`;
  }

  get adjustmentResultingDisplay() {
    return `${this.adjustmentPreviewOutcome.resultingAdjustment ?? ""}${
      this.adjustmentValueSuffix
    }`;
  }

  customStartDate = null;
  customEndDate = null;
  globalFinalPriceForProductSelected;
  yearToApplyDiscount;
  discountFormat = "Percentage";
  sortOrder = "ASC";
  discountApplyChoice = "Year";
  yearsDate = [];
  monthsDate = [];
  isYear = true;

  get isScopeYear() {
    return this.discountApplyChoice === "Year";
  }
  get isScopeCustom() {
    return this.discountApplyChoice === "Custom";
  }
  get isFormatPercentage() {
    return this.discountFormat === "Percentage";
  }
  get isFormatAmount() {
    return this.discountFormat === "Amount";
  }

  get linkedDiscountFieldLabel() {
    return this.isFormatPercentage ? "Discount %" : "Discount Amount";
  }

  get linkedDiscountInputValue() {
    return this.isFormatPercentage
      ? this.globalDiscount
      : this.discountAmountInput;
  }

  get scopeYearBtnClass() {
    return `mp-seg__btn${this.isScopeYear ? " is-selected" : ""}`;
  }
  get scopeCustomBtnClass() {
    return `mp-seg__btn${this.isScopeCustom ? " is-selected" : ""}`;
  }
  get formatAmountBtnClass() {
    return `mp-seg__btn${this.isFormatAmount ? " is-selected" : ""}`;
  }
  get formatPercentBtnClass() {
    return `mp-seg__btn${this.isFormatPercentage ? " is-selected" : ""}`;
  }

  subscription = {};
  channelName = "/event/MonthlyPaymentAdded__e";
  globalDiscount = "";
  @api objectApiName;

  get isApplyDiscountDisabled() {
    if (this.readOnly) return true;
    if (!this.hasSelection) return true;
    if (this.discountApplyChoice === "Custom" && this.isCustomDateRangeInvalid)
      return true;
    const hasDiscount =
      (this.globalDiscount !== "" && this.globalDiscount != null) ||
      (this.discountAmountInput !== "" && this.discountAmountInput != null);
    return !hasDiscount && !this.globalFinalPriceForProductSelected;
  }

  get hasCustomRangeError() {
    return this.customRangeErrorMessage !== "";
  }

  get isCustomDateRangeInvalid() {
    if (this.discountApplyChoice !== "Custom") return false;
    if (!this.customStartDate) return true;
    if (!this.customEndDate) return false;
    const start = this._parseYmd(this.customStartDate);
    const end = this._parseYmd(this.customEndDate);
    if (!start || !end) return true;
    return end < start;
  }

  get customRangeErrorMessage() {
    if (this.discountApplyChoice !== "Custom") return "";
    if (!this.customStartDate) {
      return "Please select a Start Date.";
    }
    const start = this._parseYmd(this.customStartDate);
    if (!start) {
      return "Please select a valid Start Date.";
    }
    if (this.customEndDate) {
      const end = this._parseYmd(this.customEndDate);
      if (!end) {
        return "Please select a valid End Date.";
      }
      if (end < start) {
        return "End Date cannot be before Start Date.";
      }
    }
    return "";
  }

  /** Custom scope: overlap with [customStart, customEnd] or [customStart, ∞) when end is omitted. */
  _isPaymentRowInCustomRange(room, customStart, customEnd) {
    if (!customStart || !room) return false;
    const rowStart = this._parseYmd(room.startDate);
    const rowEnd = this._parseYmd(room.endDate);
    if (!rowStart || !rowEnd) return false;
    if (rowEnd < customStart) return false;
    if (customEnd && rowStart > customEnd) return false;
    return true;
  }

  get calendarMinDate() {
    if (!this.hasSelection || !this.monthlyPayments?.length) {
      return undefined;
    }
    const mins = [];
    const seen = new Set();
    for (const monthYear of this.monthlyPayments) {
      for (const p of monthYear.data || []) {
        if (
          !this._isLineItemSelected(p.room, this.selectedProducts) ||
          seen.has(p.room)
        ) {
          continue;
        }
        seen.add(p.room);
        const deal = this._parseYmd(p.dealStartDate);
        const svc = this._parseYmd(p.productServiceDate);
        let productMin = null;
        if (deal && svc) {
          productMin = deal > svc ? deal : svc;
        } else {
          productMin = deal || svc;
        }
        if (productMin) {
          mins.push(productMin);
        }
      }
    }
    if (!mins.length) {
      return undefined;
    }
    const calendarMin = mins.reduce((a, b) => (a < b ? a : b));
    return this._fmtYmd(calendarMin);
  }

  get calendarMaxDate() {
    if (!this.hasSelection || !this.monthlyPayments?.length) {
      return undefined;
    }
    const ends = [];
    const seen = new Set();
    for (const monthYear of this.monthlyPayments) {
      for (const p of monthYear.data || []) {
        if (
          !this._isLineItemSelected(p.room, this.selectedProducts) ||
          seen.has(p.room)
        ) {
          continue;
        }
        seen.add(p.room);
        const productEnd = this._parseYmd(p.productEndDate);
        if (!productEnd) {
          return undefined;
        }
        ends.push(productEnd);
      }
    }
    if (!ends.length) {
      return undefined;
    }
    const calendarMax = ends.reduce((a, b) => (a > b ? a : b));
    return this._fmtYmd(calendarMax);
  }

  get endDateMin() {
    return this.customStartDate || this.calendarMinDate;
  }

  get hasMonthlyPaymentData() {
    return (
      Array.isArray(this.filteredMonthlyPayments) &&
      this.filteredMonthlyPayments.length > 0
    );
  }

  _scrollSyncLock = false;
  _tableResizeObserver = null;
  @track _showTopScrollbar = false;

  get scrollTopClass() {
    return this._showTopScrollbar
      ? "mp-scroll-top"
      : "mp-scroll-top mp-scroll-top--hidden";
  }

  get tableRegionClass() {
    const base = "mp-table-region";
    return this._showTopScrollbar
      ? `${base} mp-table-region--top-scroll`
      : base;
  }

  get tableWrapClass() {
    return "mp-table-wrap";
  }

  _getScrollElements() {
    return {
      main: this.template.querySelector('[data-id="scrollMain"]'),
      top: this.template.querySelector('[data-id="scrollTop"]'),
      inner: this.template.querySelector('[data-id="scrollTopInner"]')
    };
  }

  _syncScrollLeft(scrollLeft) {
    const { main, top } = this._getScrollElements();
    this._scrollSyncLock = true;
    if (main && main.scrollLeft !== scrollLeft) {
      main.scrollLeft = scrollLeft;
    }
    if (top && top.scrollLeft !== scrollLeft) {
      top.scrollLeft = scrollLeft;
    }
    this._scrollSyncLock = false;
  }

  syncScrollWidths() {
    const { main, inner } = this._getScrollElements();
    if (!main || !inner) {
      return;
    }
    const scrollWidth = main.scrollWidth;
    inner.style.width = `${scrollWidth}px`;
    const hasHorizontal = scrollWidth > main.clientWidth + 1;
    if (hasHorizontal !== this._showTopScrollbar) {
      this._showTopScrollbar = hasHorizontal;
    }
    this._syncScrollLeft(main.scrollLeft);
  }

  handleMainScroll(event) {
    if (this._scrollSyncLock) {
      return;
    }
    this._syncScrollLeft(event.target.scrollLeft);
  }

  handleTopScroll(event) {
    if (this._scrollSyncLock) {
      return;
    }
    this._syncScrollLeft(event.target.scrollLeft);
  }

  _setupTableScrollObserver() {
    const { main } = this._getScrollElements();
    if (!main || this._tableResizeObserver) {
      return;
    }
    this._tableResizeObserver = new ResizeObserver(() => {
      this.syncScrollWidths();
    });
    this._tableResizeObserver.observe(main);
  }

  _teardownTableScrollObserver() {
    if (this._tableResizeObserver) {
      this._tableResizeObserver.disconnect();
      this._tableResizeObserver = null;
    }
  }

  renderedCallback() {
    if (!this.hasMonthlyPaymentData) {
      this._teardownTableScrollObserver();
      return;
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    requestAnimationFrame(() => {
      this.syncScrollWidths();
      this._setupTableScrollObserver();
    });
  }

  @wire(getRecord, {
    recordId: "$recordId",
    layoutTypes: ["Full"],
    modes: ["View"]
  })
  wiredRecord({ error, data }) {
    if (data) {
      // eslint-disable-next-line @lwc/lwc/no-api-reassignments -- wire sets object context from record
      this.objectApiName = data.apiName;
    } else if (error) {
      console.error("Error fetching record:", error);
    }
  }

  connectedCallback() {
    this.handleSubscribe();
    this.getData();
    window.addEventListener("keydown", this._handleWindowKeyDown);
  }

  _loadGeneration = 0;
  _ensureAttempted = false;
  _lastCommittedMonthlyPayments = null;
  @track _hasUnsavedChanges = false;
  @track savingDiscounts = false;

  @api
  get hasUnsavedMonthlyChanges() {
    return this._hasUnsavedChanges;
  }

  @api
  discardUnsavedMonthlyChanges() {
    this.handleCancelClick();
  }

  get showSaveCancelToolbar() {
    if (this.readOnly) return false;
    return this._hasUnsavedChanges || this.savingDiscounts;
  }

  get saveDiscountsDisabled() {
    if (this.readOnly) return true;
    return !this._hasUnsavedChanges || this.savingDiscounts;
  }

  get cancelDiscountsDisabled() {
    return this.savingDiscounts;
  }

  _serializePaymentsForCompare(months) {
    return (months || [])
      .map((m) => ({
        month: m.month,
        year: m.year,
        data: (m.data || [])
          .map((p) => ({
            room: p.room,
            discount: Number((parseFloat(p.discount) || 0).toFixed(6)),
            finalPrice: Number((parseFloat(p.finalPrice) || 0).toFixed(6)),
            finalPriceUnset: p.finalPriceUnset === true,
            lastModifiedDate: p.lastModifiedDate || null
          }))
          .sort((a, b) => String(a.room).localeCompare(String(b.room)))
      }))
      .sort((a, b) => a.year - b.year || a.month - b.month);
  }

  _syncUnsavedFlag() {
    if (!this._lastCommittedMonthlyPayments || !this.monthlyPayments) {
      this._hasUnsavedChanges = false;
      return;
    }
    const a = this._serializePaymentsForCompare(this.monthlyPayments);
    const b = this._serializePaymentsForCompare(
      this._lastCommittedMonthlyPayments
    );
    this._hasUnsavedChanges = JSON.stringify(a) !== JSON.stringify(b);
  }

  _isCellDirty(month, year, roomId) {
    if (!this._lastCommittedMonthlyPayments) {
      return false;
    }
    const curM = (this.monthlyPayments || []).find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    const snapM = (this._lastCommittedMonthlyPayments || []).find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    if (!curM || !snapM) return false;
    const cur = (curM.data || []).find((p) => p.room === roomId);
    const snap = (snapM.data || []).find((p) => p.room === roomId);
    if (!cur || !snap) return false;
    const dDisc = Math.abs(
      (parseFloat(cur.discount) || 0) - (parseFloat(snap.discount) || 0)
    );
    const dFin = Math.abs(
      (parseFloat(cur.finalPrice) || 0) - (parseFloat(snap.finalPrice) || 0)
    );
    const unsetChanged =
      (cur.finalPriceUnset === true) !== (snap.finalPriceUnset === true);
    return dDisc > 1e-5 || dFin > 1e-5 || unsetChanged;
  }

  _resolveRecordContext() {
    const oppId =
      this.objectApiName === "Opportunity" ||
      (this.recordId && this.recordId.startsWith("006"))
        ? this.recordId
        : null;
    const orderId =
      this.objectApiName === "Order" ||
      (this.recordId && this.recordId.startsWith("801"))
        ? this.recordId
        : null;
    const contractId =
      this.objectApiName === "Contract" ||
      (this.recordId && this.recordId.startsWith("800"))
        ? this.recordId
        : null;
    return { oppId, orderId, contractId };
  }

  async _processPaymentsResult(result, loadGen) {
    if (loadGen !== this._loadGeneration) {
      return;
    }
    const data = [...(result || [])];
    if (loadGen !== this._loadGeneration) {
      return;
    }
    this.monthlyPayments = this.transformData(data);
    this._lastCommittedMonthlyPayments = JSON.parse(
      JSON.stringify(this.monthlyPayments)
    );
    this.filteredMonthlyPayments = this.monthlyPayments;
    this.selectedProducts = [...(this._selectedLineItemIds || [])];
    this.applySelectionFilter();
    this._syncUnsavedFlag();
    this._applyContractPriceDefaults();
  }

  _referenceListPriceForSelection() {
    if (!this.hasSelection) {
      return 0;
    }
    const isCustom = this.discountApplyChoice === "Custom";
    const customStart = isCustom ? this._parseYmd(this.customStartDate) : null;
    const customEnd = isCustom ? this._parseYmd(this.customEndDate) : null;

    for (const monthYear of this.monthlyPayments || []) {
      for (const p of monthYear.data || []) {
        if (!this._isLineItemSelected(p.room, this.selectedProducts)) {
          continue;
        }
        if (isCustom && customStart) {
          if (!this._isPaymentRowInCustomRange(p, customStart, customEnd)) {
            continue;
          }
        }
        const listPriceVal = parseFloat(p.listPrice);
        if (Number.isFinite(listPriceVal)) {
          return listPriceVal;
        }
      }
    }
    return this._avgListPriceForSelection();
  }

  _avgListPriceForSelection() {
    if (!this.hasSelection) return 0;
    let total = 0;
    let count = 0;
    (this.monthlyPayments || []).forEach((m) => {
      (m.data || []).forEach((p) => {
        if (this._isLineItemSelected(p.room, this.selectedProducts)) {
          total += parseFloat(p.listPrice) || 0;
          count += 1;
        }
      });
    });
    return count > 0 ? total / count : 0;
  }

  _applyContractPriceDefaults() {
    if (this.showPriceOptimizerFields) {
      if (this.priceChangeMode) {
        this.discountApplyChoice = "Custom";
        this.discountFormat = "Amount";
        this.isYear = false;
      }
      if (this.contractStartDateYmd) {
        this.customStartDate = this.contractStartDateYmd;
      }
      if (this.contractEndDateYmd) {
        this.customEndDate = this.contractEndDateYmd;
      }
    }
    this._initLinkedPriceFields();
  }

  _initLinkedPriceFields() {
    if (!this.showLinkedPriceFields) {
      return;
    }
    if (this._initLinkedPriceFieldsFromSavedPayments()) {
      this.calculateGlobalFinalPrice();
      return;
    }
    const meta = (this.selectedLineItemMeta || [])[0];
    if (!meta) {
      return;
    }
    const qty = Number(meta.deskcount) || 0;
    const desk = Number(meta.unitPrice) || 0;
    let product = Number(meta.totalPrice) || 0;
    if (!product && desk && qty) {
      product = desk * qty;
    }
    this.deskPriceInput = desk ? String(desk) : "";
    this.productPriceInput = product ? String(product) : "";
    this._linkedDeskPriceBaseline = this.deskPriceInput;
    this._linkedProductPriceBaseline = this.productPriceInput;
    const refList = this._referenceListPriceForSelection();
    const discountAmt = refList ? product - refList : 0;
    this.discountAmountInput = String(Math.round(discountAmt * 100) / 100);
    this.globalDiscount = this.discountAmountInput;
    this.calculateGlobalFinalPrice();
  }

  _initLinkedPriceFieldsFromSavedPayments() {
    const cells = this._inRangeSelectedCells();
    if (!cells.length) {
      return false;
    }
    const finalNum = roundMoney(parseFloat(cells[0].cell.finalPrice));
    const listNum = parseFloat(cells[0].cell.listPrice) || 0;
    if (!Number.isFinite(finalNum) || !listNum) {
      return false;
    }
    if (Math.abs(finalNum - listNum) < 0.005) {
      return false;
    }
    const qty = this.selectedQuantityForPriceFields || 0;
    this.productPriceInput = String(finalNum);
    this.deskPriceInput = qty ? String(roundMoney(finalNum / qty)) : "";
    this._linkedDeskPriceBaseline = this.deskPriceInput;
    this._linkedProductPriceBaseline = this.productPriceInput;
    const discountAmt = finalNum - listNum;
    this.discountAmountInput = String(roundMoney(discountAmt));
    this.globalDiscount = this.discountAmountInput;
    this.discountFormat = "Amount";
    return true;
  }

  _isSplitMonthCell(cell) {
    const orderStart = this._parseYmd(cell.orderStartDate);
    const monthStart = this._parseYmd(cell.startDate);
    const monthEnd = this._parseYmd(cell.endDate);
    if (!orderStart || !monthStart || !monthEnd) {
      return false;
    }
    return monthStart < orderStart && orderStart <= monthEnd;
  }

  _splitMonthDayCounts(cell) {
    const orderStart = this._parseYmd(cell.orderStartDate);
    const monthStart = this._parseYmd(cell.startDate);
    const monthEnd = this._parseYmd(cell.endDate);
    if (!orderStart || !monthStart || !monthEnd) {
      return null;
    }
    const dayMs = 86400000;
    const totalDays = Math.round((monthEnd - monthStart) / dayMs) + 1;
    const preDays = Math.round((orderStart - monthStart) / dayMs);
    const postDays = totalDays - preDays;
    if (totalDays <= 0 || preDays < 0 || postDays <= 0) {
      return null;
    }
    return { totalDays, preDays, postDays };
  }

  _getCommittedCellDiscount(month, year, roomId) {
    if (!this._lastCommittedMonthlyPayments) {
      return null;
    }
    const snapM = this._lastCommittedMonthlyPayments.find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    if (!snapM) {
      return null;
    }
    const snap = (snapM.data || []).find(
      (p) =>
        this._normalizeLineItemId(p.room) === this._normalizeLineItemId(roomId)
    );
    if (!snap) {
      return null;
    }
    if (snap.dbDiscountPercent != null && snap.dbDiscountPercent !== "") {
      const db = parseFloat(snap.dbDiscountPercent);
      if (Number.isFinite(db)) {
        return db;
      }
    }
    return parseFloat(snap.discount) || 0;
  }

  _effectiveDiscountFromFinalPrice(listPriceValue, finalPriceValue) {
    const listNum = parseFloat(listPriceValue) || 0;
    const finalNum = parseFloat(finalPriceValue) || 0;
    if (!listNum) {
      return 0;
    }
    return (finalNum / listNum - 1) * 100;
  }

  _discountForSave(cell, month, year) {
    // Prefer the raw entered % (full precision) so the backend receives the
    // typed value; only fall back to the money-derived % when it is missing.
    const rawEntered = parseFloat(cell.enteredDiscount);
    const listNum = parseFloat(cell.listPrice) || 0;
    const effectiveDiscount = Number.isFinite(rawEntered)
      ? rawEntered
      : listNum
        ? this._effectiveDiscountFromFinalPrice(listNum, cell.finalPrice)
        : parseFloat(cell.discount) || 0;

    if (!this._isSplitMonthCell(cell)) {
      return discountToSf(effectiveDiscount);
    }

    const dayCounts = this._splitMonthDayCounts(cell);
    if (!dayCounts) {
      return discountToSf(effectiveDiscount);
    }

    const oldD = this._getCommittedCellDiscount(month, year, cell.room) ?? 0;
    const { totalDays, preDays, postDays } = dayCounts;
    const postStartEntered =
      (effectiveDiscount * totalDays - oldD * preDays) / postDays;
    return discountToSf(postStartEntered);
  }

  handleDeskPriceFieldInput(event) {
    this.deskPriceInput = event.detail?.value ?? event.target?.value ?? "";
  }

  handleProductPriceFieldInput(event) {
    this.productPriceInput = event.detail?.value ?? event.target?.value ?? "";
  }

  handleDeskPriceFieldChange(event) {
    this.deskPriceInput = event.detail?.value ?? event.target?.value ?? "";
    const desk = parseFloat(this.deskPriceInput) || 0;
    const qty = this.selectedQuantityForPriceFields || 0;
    const product = qty ? desk * qty : desk;
    this.productPriceInput = String(Math.round(product * 100) / 100);
    this._syncDiscountFromProductPrice(parseFloat(this.productPriceInput) || 0);
  }

  handleProductPriceFieldChange(event) {
    this.productPriceInput = event.detail?.value ?? event.target?.value ?? "";
    const product = parseFloat(this.productPriceInput) || 0;
    const qty = this.selectedQuantityForPriceFields || 0;
    const desk = qty ? product / qty : product;
    this.deskPriceInput = String(Math.round(desk * 100) / 100);
    this._syncDiscountFromProductPrice(product);
  }

  handleDiscountAmountFieldChange(event) {
    this.discountAmountInput = event.detail?.value ?? event.target?.value ?? "";
    this.globalDiscount = this.discountAmountInput;
    this.discountFormat = "Amount";
    const discount = parseFloat(this.discountAmountInput) || 0;
    const refList = this._referenceListPriceForSelection();
    if (refList) {
      const product = refList + discount;
      this.productPriceInput = String(Math.round(product * 100) / 100);
      const qty = this.selectedQuantityForPriceFields || 0;
      if (qty) {
        this.deskPriceInput = String(Math.round((product / qty) * 100) / 100);
      }
    }
    this.calculateGlobalFinalPrice();
  }

  handleLinkedDiscountFieldChange(event) {
    const val = event.detail?.value ?? event.target?.value ?? "";
    if (this.isFormatPercentage) {
      this.globalDiscount = val;
      this._syncLinkedPriceFieldsFromDiscountPercent();
      this.calculateGlobalFinalPrice();
      return;
    }
    this.discountAmountInput = val;
    this.globalDiscount = val;
    this.discountFormat = "Amount";
    const discount = parseFloat(val) || 0;
    const refList = this._referenceListPriceForSelection();
    if (refList) {
      const product = refList + discount;
      this.productPriceInput = String(Math.round(product * 100) / 100);
      const qty = this.selectedQuantityForPriceFields || 0;
      if (qty) {
        this.deskPriceInput = String(Math.round((product / qty) * 100) / 100);
      }
    }
    this.calculateGlobalFinalPrice();
  }

  _syncLinkedDiscountOnFormatChange(newFormat) {
    const refList = this._referenceListPriceForSelection();
    if (!refList) {
      return;
    }
    if (newFormat === "Percentage") {
      const amt =
        parseFloat(this.discountAmountInput) ||
        parseFloat(this.globalDiscount) ||
        0;
      this.globalDiscount = String(normalizePercent((100 * amt) / refList));
      this._syncLinkedPriceFieldsFromDiscountPercent();
      return;
    }
    const pct = parseFloat(this.globalDiscount) || 0;
    const amt = (refList * pct) / 100;
    this.discountAmountInput = String(Math.round(amt * 100) / 100);
    this.globalDiscount = this.discountAmountInput;
  }

  _syncDiscountFromProductPrice(productPrice) {
    const refList = this._referenceListPriceForSelection();
    const discountAmt = refList ? productPrice - refList : 0;
    this.discountAmountInput = String(Math.round(discountAmt * 100) / 100);
    this.globalDiscount = this.discountAmountInput;
    this.discountFormat = "Amount";
    this.calculateGlobalFinalPrice();
  }

  _syncLinkedPriceFieldsFromDiscountPercent() {
    const refList = this._referenceListPriceForSelection();
    if (!refList) {
      return;
    }
    const pct = parseFloat(this.globalDiscount) || 0;
    const product = roundMoney(refList + (refList * pct) / 100);
    this.productPriceInput = String(product);
    const qty = this.selectedQuantityForPriceFields || 0;
    if (qty) {
      this.deskPriceInput = String(roundMoney(product / qty));
    }
    this.discountAmountInput = String(roundMoney(product - refList));
  }

  async getData() {
    const { oppId, orderId, contractId } = this._resolveRecordContext();
    if (!oppId && !orderId && !contractId) {
      return;
    }

    const loadGen = ++this._loadGeneration;
    this._isLoadingPayments = true;

    try {
      let result = await getMonthlyPayments({
        oppId,
        contractId,
        orderId
      });
      await this._processPaymentsResult(result, loadGen);

      if (
        orderId &&
        this.hasSelection &&
        !this.hasMatchingPaymentsForSelection &&
        !this._ensureAttempted
      ) {
        this._ensureAttempted = true;
        try {
          await ensureMonthlyPaymentsForLineItems({
            orderId,
            lineItemIds: this._selectedLineItemIds
          });
          if (loadGen !== this._loadGeneration) {
            return;
          }
          result = await getMonthlyPayments({
            oppId,
            contractId,
            orderId
          });
          await this._processPaymentsResult(result, loadGen);
        } catch (ensureError) {
          console.error("Error ensuring monthly payments:", ensureError);
        }
      }
    } catch (error) {
      console.error("Error loading monthly payments:", error);
    } finally {
      if (loadGen === this._loadGeneration) {
        this._isLoadingPayments = false;
      }
    }
  }

  syncDateFiltersToAvailableOptions() {
    const yearApplyValues = new Set(
      (this.yearsDate || []).map((opt) => String(opt.value))
    );
    if (
      this.yearToApplyDiscount != null &&
      !yearApplyValues.has(String(this.yearToApplyDiscount))
    ) {
      this.yearToApplyDiscount = null;
    }
  }

  applySelectionFilter() {
    if (!this.hasSelection) {
      this.filteredMonthlyPayments = [];
      this.monthsDate = [];
      this.yearsDate = [];
      this.syncDateFiltersToAvailableOptions();
      return;
    }
    this.filteredMonthlyPayments = (this.monthlyPayments || [])
      .map((monthYear) => {
        const filteredData = (monthYear.data || []).filter((p) =>
          this._isLineItemSelected(p.room, this.selectedProducts)
        );
        return { ...monthYear, data: filteredData };
      })
      .filter((monthYear) => (monthYear.data || []).length > 0);

    this.sortData(this.filteredMonthlyPayments, this.sortOrder);
    this.generateComboboxOptions(this.filteredMonthlyPayments, false);
    this.syncDateFiltersToAvailableOptions();
    this._clampCustomDatesToAllowedRange();
  }

  _clampCustomDatesToAllowedRange() {
    const min = this.calendarMinDate;
    const max = this.calendarMaxDate;
    if (!min && !max) {
      return;
    }
    if (min && this.customStartDate && this.customStartDate < min) {
      this.customStartDate = min;
    }
    if (max && this.customStartDate && this.customStartDate > max) {
      this.customStartDate = max;
    }
    const floor = this.customStartDate || min;
    if (floor && this.customEndDate && this.customEndDate < floor) {
      this.customEndDate = floor;
    }
    if (max && this.customEndDate && this.customEndDate > max) {
      this.customEndDate = max;
    }
  }

  _buildMetaByNormalizedId(sourceMonths) {
    const metaByNorm = new Map();
    (sourceMonths || []).forEach((monthYear) => {
      (monthYear.data || []).forEach((p) => {
        const norm = this._normalizeLineItemId(p.room);
        if (!metaByNorm.has(norm)) {
          metaByNorm.set(norm, {
            id: p.room,
            displayName: p.displayName || p.room,
            deskcount: p.deskcount || 0
          });
        }
      });
    });
    return metaByNorm;
  }

  get selectedProductsMeta() {
    if (!this.hasSelection) return [];
    const source =
      (this.filteredMonthlyPayments || []).length > 0
        ? this.filteredMonthlyPayments
        : this.monthlyPayments;
    const metaByNorm = this._buildMetaByNormalizedId(source);

    return (this.selectedProducts || []).map((id, idx) => {
      const norm = this._normalizeLineItemId(id);
      const paymentMeta = metaByNorm.get(norm);
      const selectionMeta = this._selectionMetaByNormId.get(norm);
      return {
        id: paymentMeta?.id || selectionMeta?.id || id,
        displayName:
          paymentMeta?.displayName || selectionMeta?.displayName || String(id),
        // Grid "Desks Count" uses Quantity; prefer live selection over payment snapshot.
        deskcount: selectionMeta?.deskcount ?? paymentMeta?.deskcount ?? 0,
        accessType: selectionMeta?.accessType || "",
        isUsageBased: this._isUsageBasedProductId(id),
        colIndex: idx
      };
    });
  }

  _formatMonthLabel(month, year) {
    if (!month || !year) return "";
    return `${month}/${year}`;
  }

  _arrowClass(discount) {
    const d = parseFloat(discount) || 0;
    return d < 0
      ? "discount-arrow discount-down"
      : "discount-arrow discount-up";
  }

  _fmtPercent(value, scale = 2) {
    const n = parseFloat(value);
    if (Number.isNaN(n)) return "";
    return `${n.toFixed(scale)}%`;
  }

  _recomputeCellFromEnteredDiscount(cell) {
    if (!cell) return;
    // Keep the raw entered % at full precision for save; round only for display.
    const raw = parseFloat(cell.enteredDiscount ?? cell.discount ?? 0) || 0;
    cell.enteredDiscount = raw;
    cell.discount = normalizePercent(raw);
    cell.finalPrice =
      Math.round((parseFloat(cell.listPrice) || 0) * (1 + raw / 100) * 100) /
      100;
  }

  _fmtYmd(value) {
    if (!value) return "";
    const dt = new Date(value);
    if (Number.isNaN(dt.getTime())) return String(value);
    const yyyy = dt.getFullYear();
    const mm = String(dt.getMonth() + 1).padStart(2, "0");
    const dd = String(dt.getDate()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd}`;
  }

  _deltaTooltip(listPriceVal, finalPriceVal) {
    const lp = parseFloat(listPriceVal);
    const fp = parseFloat(finalPriceVal);
    if (Number.isNaN(lp) || Number.isNaN(fp)) return "";
    const delta = fp - lp;
    const sign = delta >= 0 ? "+" : "-";
    const abs = Math.abs(delta);
    const formatted = abs % 1 === 0 ? String(Math.round(abs)) : abs.toFixed(2);
    return `${sign}${formatted} vs list price`;
  }

  get monthRows() {
    const products = this.selectedProductsMeta;
    return (this.filteredMonthlyPayments || []).map((monthYear, rowIndex) => {
      const cellsByNormId = {};
      (monthYear.data || []).forEach((p) => {
        const isDirty = this._isCellDirty(
          monthYear.month,
          monthYear.year,
          p.room
        );
        const usageBased = p.usageBased === true;
        const finalPriceUnset = usageBased && p.finalPriceUnset === true;
        const usageLocked =
          usageBased && !this._isUsageBasedFinalPriceEditable(p);
        cellsByNormId[this._normalizeLineItemId(p.room)] = {
          ...p,
          arrowClass: this._arrowClass(p.discount),
          deltaTooltip: this._deltaTooltip(p.listPrice, p.finalPrice),
          isDirty,
          finalPriceReadOnly: usageBased
            ? usageLocked
            : this._standardColumnReadOnly(p.room),
          standardReadOnly: this._standardColumnReadOnly(p.room),
          finalPriceInputValue: finalPriceUnset
            ? ""
            : String(p.finalPrice ?? ""),
          finalPriceClass:
            Number(p.finalPrice) < 0
              ? "modern-input bold-input final-price-negative"
              : "modern-input bold-input",
          cellGridClass: `cell-grid${isDirty ? " cell-grid--dirty" : ""}${
            usageBased ? " cell-grid--usage-based" : ""
          }${usageLocked ? " cell-grid--locked" : ""}`
        };
      });
      const cells = products.map((prod) => {
        const cell = cellsByNormId[this._normalizeLineItemId(prod.id)] || null;
        return {
          key: `${monthYear.month}-${monthYear.year}-${prod.id}`,
          prodId: prod.id,
          colIndex: prod.colIndex,
          displayName: prod.displayName,
          deskcount: prod.deskcount,
          isUsageBased: prod.isUsageBased,
          cell
        };
      });
      return {
        key: `${monthYear.month}-${monthYear.year}`,
        month: monthYear.month,
        year: monthYear.year,
        label: this._formatMonthLabel(monthYear.month, monthYear.year),
        rowIndex,
        cells
      };
    });
  }

  handleCellKeyDown(event) {
    const key = event.key;
    const rowIdx = parseInt(event.target?.dataset?.rowIdx, 10);
    const colIdx = parseInt(event.target?.dataset?.colIdx, 10);
    const field = event.target?.dataset?.field;
    if (Number.isNaN(rowIdx) || Number.isNaN(colIdx) || !field) return;

    const focusField = (r, c, f) => {
      const selector = `input[data-row-idx="${r}"][data-col-idx="${c}"][data-field="${f}"]`;
      const el = this.template.querySelector(selector);
      if (el) {
        el.focus();
        el.select?.();
        return true;
      }
      return false;
    };

    if (key === "Enter") {
      event.preventDefault();
      event.target.blur();
      return;
    }

    if (key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.revertCellByIndex(rowIdx, colIdx);
      return;
    }

    if (key === "Tab") {
      const withinCell = event.shiftKey
        ? field === "finalPrice"
        : field === "discount";
      if (withinCell) {
        event.preventDefault();
        const nextField = event.shiftKey ? "discount" : "finalPrice";
        focusField(rowIdx, colIdx, nextField);
      }
      return;
    }

    const nav = {
      ArrowUp: [-1, 0],
      ArrowDown: [1, 0],
      ArrowLeft: [0, -1],
      ArrowRight: [0, 1]
    }[key];

    if (nav) {
      event.preventDefault();
      const [dr, dc] = nav;
      focusField(rowIdx + dr, colIdx + dc, field);
    }
  }

  revertCellByIndex(rowIdx, colIdx) {
    const row = this.monthRows[rowIdx];
    const product = this.selectedProductsMeta[colIdx];
    if (!row || !product || !this._lastCommittedMonthlyPayments) return;
    const month = row.month;
    const year = row.year;
    const productId = product.id;

    const currentMonth = (this.monthlyPayments || []).find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    const snapMonth = (this._lastCommittedMonthlyPayments || []).find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    if (!currentMonth || !snapMonth) return;
    const cur = (currentMonth.data || []).find(
      (p) =>
        this._normalizeLineItemId(p.room) ===
        this._normalizeLineItemId(productId)
    );
    const snap = (snapMonth.data || []).find(
      (p) =>
        this._normalizeLineItemId(p.room) ===
        this._normalizeLineItemId(productId)
    );
    if (!cur || !snap) return;

    cur.discount = snap.discount;
    cur.finalPrice = snap.finalPrice;
    cur.finalPriceUnset = snap.finalPriceUnset === true;
    cur.isDiscountArrow = (parseFloat(cur.discount) || 0) < 0;
    this.applySelectionFilter();
    this._syncUnsavedFlag();
  }

  handleSubscribe() {
    const messageCallback = () => {
      this.getData();
    };
    subscribe(this.channelName, -1, messageCallback).then((response) => {
      this.subscription = response;
    });
    onError((error) => {
      console.error("Occurred an Error: ", JSON.stringify(error));
    });
  }

  disconnectedCallback() {
    this._loadGeneration++;
    this._teardownTableScrollObserver();
    this.handleUnsubscribe();
    window.removeEventListener("keydown", this._handleWindowKeyDown);
  }

  _handleWindowKeyDown = (event) => {
    if (event.key === "Escape" && this.showAdjustmentPreview) {
      event.preventDefault();
      this.closeAdjustmentPreview();
    }
  };

  handleUnsubscribe() {
    unsubscribe(this.subscription, () => {});
  }

  handleDiscountMultipleValue(e) {
    const name = e.target.name;
    const value = e.target.value;

    if (value === "All") {
      this[name] = "All";
    } else {
      this[name] = this.cleanAndConvertToNumber(value);
    }
    this.calculateGlobalFinalPrice();
  }

  handleCustomDateChange(event) {
    const name = event.currentTarget?.dataset?.name || event.target?.name;
    const value = event.detail?.value ?? event.target?.value ?? null;
    if (name) {
      this[name] = value || null;
    }
    this._clampCustomDatesToAllowedRange();
    this.calculateGlobalFinalPrice();
  }

  async handleOpenRecurringPriceIncrease() {
    const lineIds = [
      ...new Set((this.selectedProducts || []).filter((id) => !!id))
    ];
    if (!lineIds.length) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: "Error",
          message: "Select at least one product.",
          variant: "error"
        })
      );
      return;
    }
    try {
      const result = await packageBuilderRecurringPriceIncreaseModal.open({
        size: "medium",
        lineIds,
        isArchived: this.isArchived === true,
        contractStartDateYmd: this.contractStartDateYmd || null,
        readOnly: this.showGlobalReadOnlyBanner === true
      });
      if (result?.saved) {
        this.dispatchEvent(
          new CustomEvent("monthlypaymentssaved", {
            bubbles: true,
            composed: true
          })
        );
        await this.getData();
      }
    } catch {
      // User dismissed modal or LightningModal closed without result.
    }
  }

  _parseYmd(value) {
    if (value == null || value === "") {
      return null;
    }
    if (value instanceof Date) {
      if (Number.isNaN(value.getTime())) {
        return null;
      }
      return new Date(value.getFullYear(), value.getMonth(), value.getDate());
    }
    const str = String(value);
    const iso = str.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (iso) {
      const y = Number(iso[1]);
      const m = Number(iso[2]);
      const d = Number(iso[3]);
      if (Number.isFinite(y) && Number.isFinite(m) && Number.isFinite(d)) {
        return new Date(y, m - 1, d);
      }
    }
    const dt = new Date(str);
    if (Number.isNaN(dt.getTime())) {
      return null;
    }
    return new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
  }

  _resolveDealStartDate(payment) {
    if (payment.Opportunity__r?.Start_Date__c) {
      return payment.Opportunity__r.Start_Date__c;
    }
    const order = payment.OrderItem__r?.Order;
    if (order) {
      return order.Order_Start_Date__c ?? order.EffectiveDate;
    }
    return null;
  }

  _resolveProductServiceDate(payment) {
    if (payment.OpportunityLineItem__r?.ServiceDate) {
      return payment.OpportunityLineItem__r.ServiceDate;
    }
    return payment.OrderItem__r?.ServiceDate ?? null;
  }

  _resolveProductEndDate(payment) {
    if (payment.OpportunityLineItem__r?.End_date__c) {
      return payment.OpportunityLineItem__r.End_date__c;
    }
    return payment.OrderItem__r?.EndDate ?? null;
  }

  generateComboboxOptions(data, isAfterFilter) {
    const roomMap = new Map();
    const months = new Set();
    const years = new Set();

    data.forEach((entry) => {
      months.add(entry.month);
      years.add(entry.year);
      entry.data.forEach((item) => {
        const key = item.room;
        if (!roomMap.has(key)) {
          roomMap.set(key, {
            displayName: item.displayName,
            roomId: item.room
          });
        }
      });
    });

    const displayNameCount = {};
    const totalDisplayNameCount = {};
    const uniqueProducts = Array.from(roomMap.values());
    uniqueProducts.forEach((prod) => {
      const name = prod.displayName;
      totalDisplayNameCount[name] = (totalDisplayNameCount[name] || 0) + 1;
    });

    // eslint-disable-next-line @lwc/lwc/no-api-reassignments -- rebuild product picklist from loaded payments
    this.productsDate = uniqueProducts.map((prod) => {
      const name = prod.displayName;
      let label = name;
      if (totalDisplayNameCount[name] > 1) {
        displayNameCount[name] = (displayNameCount[name] || 0) + 1;
        label = `${name} #${displayNameCount[name]}`;
      }
      return { label, value: prod.roomId };
    });

    this.productsDate.push({
      label: this.customLabels.allProducts,
      value: "All"
    });
    this.monthsDate = Array.from(months)
      .map((month) => ({ label: month, value: month }))
      .sort((a, b) => a.value - b.value);
    this.yearsDate = Array.from(years).map((year) => ({
      label: year,
      value: year
    }));

    if (!isAfterFilter) {
      this.yearsDate.push({ label: this.customLabels.allTime, value: "All" });
    }
  }

  transformData(data) {
    const groupedData = {};
    data.forEach((payment) => {
      const startdate = new Date(payment.Start_date__c);
      const month = startdate.getMonth() + 1;
      const year = startdate.getFullYear();
      const key = `${month}-${year}`;

      if (!groupedData[key]) {
        groupedData[key] = { month, year, data: [], total: 0 };
      }

      const oppOrOrderId =
        payment.OpportunityLineItem__c || payment.OrderItem__c;

      let deskCount = 0;
      let calcListPriceAdj = 0;

      if (payment.OpportunityLineItem__c && payment.OpportunityLineItem__r) {
        const oli = payment.OpportunityLineItem__r;
        deskCount = oli.Quantity ?? oli.Desk_Count__c ?? 0;
        calcListPriceAdj = oli.Calculated_List_Price_Adjustment__c || 0;
      } else if (payment.OrderItem__c && payment.OrderItem__r) {
        const oi = payment.OrderItem__r;
        deskCount = oi.Quantity ?? oi.Number_of_desks__c ?? 0;
        calcListPriceAdj = oi.Calculated_List_Price_Adjustment__c || 0;
      }

      const dbDiscountPercent = discountFromSf(payment.Discount__c);
      const discountDisplay = normalizePercent(dbDiscountPercent);
      const dealStartDate = this._resolveDealStartDate(payment);
      const productServiceDate = this._resolveProductServiceDate(payment);
      const productEndDate = this._resolveProductEndDate(payment);
      const usageBased =
        paymentIsUsageBased(payment) ||
        this._isUsageBasedProductId(oppOrOrderId);
      const usageFinal = usageBased ? usageFinalFromPayment(payment) : null;
      const cell = {
        id: payment.Id,
        month,
        year,
        lastModifiedDate: payment.LastModifiedDate,
        recurringPricingActive: recurringPricingApplies(payment),
        oppproductid: oppOrOrderId,
        room: oppOrOrderId,
        dealStartDate,
        productServiceDate,
        productEndDate,
        displayName: payment.Products_Name__c,
        calculateListPriceAdj: calcListPriceAdj,
        deskcount: deskCount,
        usageBased,
        listPrice: usageBased ? null : payment.Price__c,
        discount: discountDisplay,
        enteredDiscount: discountDisplay,
        dbDiscountPercent,
        startDate: payment.Start_date__c,
        endDate: payment.End_date__c,
        orderStartDate: dealStartDate,
        monthUnit: payment.Monthly_Units__c || 1,
        finalPrice: 0,
        finalPriceUnset: false,
        lastEditedField: null
      };
      if (usageBased) {
        if (usageFinal != null) {
          cell.finalPrice = usageFinal;
          cell.finalPriceUnset = false;
        } else {
          cell.finalPrice = 0;
          cell.finalPriceUnset = true;
        }
      } else {
        const sfFinal = parseFloat(payment.FinalPrice__c);
        const listNum = parseFloat(payment.Price__c) || 0;
        if (Number.isFinite(sfFinal)) {
          cell.finalPrice = roundMoney(sfFinal);
        } else {
          this._recomputeCellFromEnteredDiscount(cell);
        }
        if (listNum !== 0) {
          const rawPct = (cell.finalPrice / listNum - 1) * 100;
          cell.enteredDiscount = rawPct;
          cell.discount = normalizePercent(rawPct);
        }
      }
      groupedData[key].data.push(cell);
      groupedData[key].total += cell.finalPrice;
    });
    return Object.values(groupedData).map((entry) => ({
      ...entry,
      total: roundMoney(entry.total)
    }));
  }

  handleDiscountChange(event) {
    const { month, year, productId } = event.target.dataset;
    this._applyCellFieldEdit(
      month,
      year,
      productId,
      "discount",
      event.target.value
    );
  }

  handleFinalPriceChange(event) {
    const { month, year, productId } = event.target.dataset;
    this._applyCellFieldEdit(
      month,
      year,
      productId,
      "finalPrice",
      event.target.value
    );
  }

  _applyCellFieldEdit(month, year, productId, field, rawValue) {
    const monthYearData = this.monthlyPayments.filter(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    if (monthYearData.length === 0) return;
    const roomData = monthYearData[0].data.filter(
      (item) =>
        this._normalizeLineItemId(item.room) ===
        this._normalizeLineItemId(productId)
    );
    if (!roomData.length) return;
    const cell = roomData[0];

    if (field === "finalPrice" && cell.usageBased) {
      if (!this._isUsageBasedFinalPriceEditable(cell)) {
        return;
      }
      const trimmed = String(rawValue ?? "").trim();
      if (trimmed === "") {
        cell.finalPrice = 0;
        cell.finalPriceUnset = true;
      } else {
        const input = trimmed.replace(/[^0-9.-]/g, "");
        const parsed = parseFloat(input);
        if (!Number.isFinite(parsed)) {
          return;
        }
        const next = roundMoney(parsed);
        if (next < 0) {
          this.showToast(
            "Validation Error",
            "Usage Based final price cannot be negative.",
            "error"
          );
          return;
        }
        cell.finalPrice = next;
        cell.finalPriceUnset = false;
      }
      this.applySelectionFilter();
      this._syncUnsavedFlag();
      return;
    }

    if (this._standardColumnReadOnly(cell.room)) {
      return;
    }

    if (field === "finalPrice") {
      const input = String(rawValue ?? "").replace(/[^0-9.]/g, "");
      const listNum = parseFloat(cell.listPrice) || 0;
      cell.finalPrice = roundMoney(parseFloat(input) || 0);
      const rawPct = listNum !== 0 ? (cell.finalPrice / listNum - 1) * 100 : 0;
      cell.enteredDiscount = rawPct;
      cell.discount = normalizePercent(rawPct);
      cell.lastEditedField = "finalPrice";
    } else if (field === "discount") {
      const priceChange = String(rawValue ?? "");
      const isDiscount = priceChange.includes("-");
      roomData[0].enteredDiscount =
        parseFloat(priceChange.replace(/[^0-9.-]/g, "")) || 0;
      this._recomputeCellFromEnteredDiscount(roomData[0]);
      roomData[0].isDiscountArrow = isDiscount;
      roomData[0].lastEditedField = "discount";
    }

    this.applySelectionFilter();
    this._syncUnsavedFlag();
  }

  _flushFocusedGridCellEdit() {
    const focused = this.template?.querySelector("input.modern-input:focus");
    if (!focused) {
      return false;
    }
    const field = focused.dataset?.field;
    const { month, year, productId } = focused.dataset || {};
    if (!field || month == null || year == null || !productId) {
      return false;
    }
    this._applyCellFieldEdit(month, year, productId, field, focused.value);
    return true;
  }

  _readLightningInputValue(field) {
    const el = this.template.querySelector(
      `lightning-input[data-field="${field}"]`
    );
    if (!el) {
      if (field === "productPrice") {
        return this.productPriceInput ?? "";
      }
      if (field === "deskPrice") {
        return this.deskPriceInput ?? "";
      }
      if (field === "linkedDiscount") {
        return this.linkedDiscountInputValue ?? "";
      }
      return "";
    }
    const internal = el.shadowRoot?.querySelector("input");
    const internalVal = internal?.value;
    if (internalVal != null && String(internalVal).trim() !== "") {
      return String(internalVal);
    }
    if (el.value != null && String(el.value).trim() !== "") {
      return String(el.value);
    }
    if (field === "productPrice") {
      return this.productPriceInput ?? "";
    }
    if (field === "deskPrice") {
      return this.deskPriceInput ?? "";
    }
    if (field === "linkedDiscount") {
      return this.linkedDiscountInputValue ?? "";
    }
    return "";
  }

  _inRangeSelectedCells() {
    const isYear = this.discountApplyChoice === "Year";
    const customStart = !isYear ? this._parseYmd(this.customStartDate) : null;
    const customEnd = !isYear ? this._parseYmd(this.customEndDate) : null;
    const cells = [];
    (this.monthlyPayments || []).forEach((monthYear) => {
      (monthYear.data || []).forEach((room) => {
        if (!this._isLineItemSelected(room.room, this.selectedProducts)) {
          return;
        }
        if (room.usageBased) {
          return;
        }
        let inRange = false;
        if (isYear) {
          inRange =
            this.yearToApplyDiscount === "All" ||
            String(monthYear.year) === String(this.yearToApplyDiscount);
        } else if (customStart) {
          inRange = this._isPaymentRowInCustomRange(
            room,
            customStart,
            customEnd
          );
        }
        if (inRange) {
          cells.push({
            cell: room,
            month: monthYear.month,
            year: monthYear.year
          });
        }
      });
    });
    return cells;
  }

  _optimizerTargetProductPrice() {
    const raw = this._readLightningInputValue("productPrice");
    const n = parseFloat(raw);
    return Number.isFinite(n) ? n : NaN;
  }

  _optimizerUserChangedInputs() {
    const product = this._optimizerTargetProductPrice();
    const desk = parseFloat(this._readLightningInputValue("deskPrice"));
    const productBaseline = parseFloat(this._linkedProductPriceBaseline);
    const deskBaseline = parseFloat(this._linkedDeskPriceBaseline);
    if (
      Number.isFinite(product) &&
      Number.isFinite(productBaseline) &&
      Math.abs(product - productBaseline) > 0.005
    ) {
      return true;
    }
    if (
      Number.isFinite(desk) &&
      Number.isFinite(deskBaseline) &&
      Math.abs(desk - deskBaseline) > 0.005
    ) {
      return true;
    }
    return false;
  }

  _optimizerDiffersFromGrid() {
    if (!this.showLinkedPriceFields) {
      return false;
    }
    if (!this._optimizerUserChangedInputs()) {
      return false;
    }
    const target = this._optimizerTargetProductPrice();
    if (!Number.isFinite(target)) {
      return false;
    }
    const cells = this._inRangeSelectedCells();
    if (!cells.length) {
      return true;
    }
    return cells.some(
      (entry) =>
        Math.abs((parseFloat(entry.cell.finalPrice) || 0) - target) > 0.005
    );
  }

  _syncOptimizerInputsFromDom() {
    if (this.showLinkedPriceFields) {
      const deskVal = this._readLightningInputValue("deskPrice");
      const deskNum = parseFloat(deskVal);
      const deskBaseline = parseFloat(this._linkedDeskPriceBaseline);
      if (
        deskVal !== "" &&
        deskVal != null &&
        Number.isFinite(deskNum) &&
        Number.isFinite(deskBaseline) &&
        Math.abs(deskNum - deskBaseline) > 0.005
      ) {
        this.handleDeskPriceFieldChange({ detail: { value: deskVal } });
        return;
      }

      const productVal = this._readLightningInputValue("productPrice");
      if (productVal !== "" && productVal != null) {
        this.handleProductPriceFieldChange({ detail: { value: productVal } });
        return;
      }

      const discountVal = this._readLightningInputValue("linkedDiscount");
      if (discountVal !== "" && discountVal != null) {
        this.handleLinkedDiscountFieldChange({
          detail: { value: discountVal }
        });
      }
      return;
    }

    const adjEl = this.template.querySelector(
      'lightning-input[name="globalDiscount"]'
    );
    if (adjEl?.value != null && adjEl.value !== "") {
      this.globalDiscount = adjEl.value;
      this.calculateGlobalFinalPrice();
    }
  }

  _prepareSaveState() {
    const gridFlushed = this._flushFocusedGridCellEdit();
    this._syncUnsavedFlag();
    const gridDirtyBeforeOptimizer = this._hasUnsavedChanges;

    if (!gridDirtyBeforeOptimizer && !gridFlushed) {
      this._syncOptimizerInputsFromDom();
      if (
        this.showLinkedPriceFields &&
        this.hasSelection &&
        this._optimizerDiffersFromGrid()
      ) {
        this.applyFilters();
      }
    }
    this._syncUnsavedFlag();
  }

  applyFilters() {
    if (!this.monthlyPayments || this.monthlyPayments.length === 0) return;

    const discountToApply = parseFloat(this.globalDiscount) || 0;
    const isPercentage = this.discountFormat === "Percentage";
    const isYear = this.discountApplyChoice === "Year";
    const targetProductPrice = this.showLinkedPriceFields
      ? parseFloat(this.productPriceInput)
      : NaN;
    const useTargetProductPrice =
      this.showLinkedPriceFields &&
      !isPercentage &&
      Number.isFinite(targetProductPrice);

    const customStart = !isYear ? this._parseYmd(this.customStartDate) : null;
    const customEnd = !isYear ? this._parseYmd(this.customEndDate) : null;

    this.monthlyPayments.forEach((monthYear) => {
      monthYear.data.forEach((room) => {
        if (!this._isLineItemSelected(room.room, this.selectedProducts)) {
          return;
        }
        if (room.usageBased) {
          return;
        }

        let inRange = false;
        if (isYear) {
          inRange =
            this.yearToApplyDiscount === "All" ||
            String(monthYear.year) === String(this.yearToApplyDiscount);
        } else {
          if (!customStart) {
            return;
          }
          if (customEnd && customEnd < customStart) {
            return;
          }
          inRange = this._isPaymentRowInCustomRange(
            room,
            customStart,
            customEnd
          );
        }

        if (!inRange) {
          return;
        }

        if (useTargetProductPrice) {
          room.finalPrice = targetProductPrice;
          const listNum = parseFloat(room.listPrice) || 0;
          const rawPct =
            listNum !== 0 ? (100 * (room.finalPrice - listNum)) / listNum : 0;
          room.enteredDiscount = rawPct;
          room.discount = normalizePercent(rawPct);
          room.enteredAdjustmentValue = discountToApply;
          room.lastEditedField = "amount";
        } else if (isPercentage) {
          room.enteredDiscount = discountToApply;
          this._recomputeCellFromEnteredDiscount(room);
          room.lastEditedField = "discount";
        } else {
          const listNum = parseFloat(room.listPrice) || 0;
          room.finalPrice = listNum + discountToApply;
          const rawPct =
            listNum !== 0 ? (100 * (room.finalPrice - listNum)) / listNum : 0;
          room.enteredDiscount = rawPct;
          room.discount = normalizePercent(rawPct);
          room.finalPrice = Math.round(room.finalPrice * 100) / 100;
          room.enteredAdjustmentValue = discountToApply;
          room.lastEditedField = "amount";
        }
        room.isDiscountArrow = room.discount < 0;
      });
    });

    this.applySelectionFilter();
  }

  handleFormatDiscount(event) {
    this[event.target.name] = event.target.value;
    if (event.target.name === "globalDiscount") {
      this.calculateGlobalFinalPrice();
    }
  }

  handleSegmentedClick(event) {
    const name = event.currentTarget?.dataset?.name;
    const value = event.currentTarget?.dataset?.value;
    if (!name) return;
    this[name] = value;
    if (name === "discountApplyChoice") {
      this.isYear = this.discountApplyChoice === "Year";
      if (this.discountApplyChoice === "Custom") {
        this._clampCustomDatesToAllowedRange();
      }
    }
    if (name === "discountFormat" && this.showLinkedPriceFields) {
      this._syncLinkedDiscountOnFormatChange(value);
    }
    this.calculateGlobalFinalPrice();
  }

  calculateGlobalFinalPrice() {
    if (
      this.showLinkedPriceFields &&
      this.discountFormat === "Amount" &&
      this.productPriceInput
    ) {
      const product = parseFloat(this.productPriceInput);
      if (Number.isFinite(product)) {
        this.globalFinalPriceForProductSelected = product;
        return;
      }
    }
    if (
      this.selectedProducts.length === 1 &&
      this.selectedProducts[0] !== "All" &&
      this.globalDiscount
    ) {
      const productId = this.selectedProducts[0];
      let totalList = 0;
      let count = 0;
      this.monthlyPayments.forEach((m) => {
        m.data.forEach((d) => {
          if (
            this._normalizeLineItemId(d.room) ===
            this._normalizeLineItemId(productId)
          ) {
            totalList += d.listPrice;
            count++;
          }
        });
      });
      if (count > 0) {
        const avgList = totalList / count;
        const discount = parseFloat(this.globalDiscount) || 0;
        if (this.discountFormat === "Percentage") {
          this.globalFinalPriceForProductSelected =
            avgList + (avgList * discount) / 100;
        } else {
          this.globalFinalPriceForProductSelected = avgList + discount;
        }
      }
    } else {
      this.globalFinalPriceForProductSelected = null;
    }
  }

  sortData(data, sortOrder) {
    data.sort((a, b) => {
      if (a.year === b.year)
        return sortOrder === "ASC" ? a.month - b.month : b.month - a.month;
      return sortOrder === "ASC" ? a.year - b.year : b.year - a.year;
    });
  }

  cleanAndConvertToNumber(value) {
    if (value == null) return null;
    const sanitized = String(value).replace(/[^0-9.]/g, "");
    return parseFloat(sanitized) || 0;
  }

  async handleSaveDiscountsClick() {
    this._prepareSaveState();
    const focused = this.template?.querySelector("input.modern-input:focus");
    if (focused) {
      focused.blur();
    }
    const active = this.template.activeElement;
    if (
      active?.tagName === "LIGHTNING-INPUT" &&
      typeof active.blur === "function"
    ) {
      active.blur();
    }
    await Promise.resolve();
    const individualCandidate = this._individualAdjustmentCandidate();
    if (individualCandidate) {
      if (
        individualCandidate.inputType === "Amount" &&
        !individualCandidate.hasExistingAdjustment
      ) {
        await this.applyIndividualAmountSet(individualCandidate);
        return;
      }
      await this.openAdjustmentPreview(individualCandidate);
      return;
    }
    const bulkCandidate = this._bulkAdjustmentCandidate();
    if (bulkCandidate) {
      await this.applyBulkAdjustmentSave(bulkCandidate);
      return;
    }
    const typedDirty = this._typedDirtyCellsForSave();
    if (
      typedDirty.length > 1 &&
      typedDirty.some(({ cell, month, year }) => {
        const existing = this._getCommittedCellDiscount(month, year, cell.room);
        return Number.isFinite(existing) && existing !== 0;
      })
    ) {
      this.showToast(
        "Error",
        this.customLabels.adjustmentMixedEditError,
        "error"
      );
      return;
    }
    this.commitDiscountsToServer();
  }

  _dirtyCellsForSave() {
    const dirty = [];
    const monthsToSave = this.hasSelection
      ? this.filteredMonthlyPayments
      : this.monthlyPayments;
    (monthsToSave || []).forEach((monthYear) => {
      (monthYear.data || []).forEach((cell) => {
        if (this._isCellDirty(monthYear.month, monthYear.year, cell.room)) {
          dirty.push({ cell, month: monthYear.month, year: monthYear.year });
        }
      });
    });
    return dirty;
  }

  _typedDirtyCellsForSave() {
    return this._dirtyCellsForSave().filter(({ cell }) => {
      if (
        cell.usageBased ||
        (cell.lastEditedField !== "discount" &&
          cell.lastEditedField !== "amount") ||
        this._standardColumnReadOnly(cell.room)
      ) {
        return false;
      }
      return true;
    });
  }

  _bulkAdjustmentInputValue(cell) {
    if (cell.lastEditedField === "amount") {
      return parseFloat(cell.enteredAdjustmentValue) || 0;
    }
    return parseFloat(cell.enteredDiscount) || 0;
  }

  _bulkAdjustmentCandidate() {
    const dirty = this._typedDirtyCellsForSave();
    if (dirty.length <= 1) {
      return null;
    }
    const inputTypes = new Set(
      dirty.map(({ cell }) => {
        return cell.lastEditedField === "amount" ? "Amount" : "Percentage";
      })
    );
    if (inputTypes.size !== 1) {
      return null;
    }
    const inputType = [...inputTypes][0];
    const inputValues = new Set(
      dirty.map(({ cell }) => this._bulkAdjustmentInputValue(cell))
    );
    if (inputValues.size !== 1) {
      return null;
    }
    return {
      inputType,
      inputValue: [...inputValues][0],
      items: dirty
    };
  }

  _getCommittedCellExpectation(month, year, roomId) {
    const discount = this._getCommittedCellDiscount(month, year, roomId) ?? 0;
    const snapMonth = (this._lastCommittedMonthlyPayments || []).find(
      (m) =>
        String(m.month) === String(month) && String(m.year) === String(year)
    );
    const snap = (snapMonth?.data || []).find(
      (p) =>
        this._normalizeLineItemId(p.room) === this._normalizeLineItemId(roomId)
    );
    if (!snap) {
      return null;
    }
    return {
      discount,
      finalPrice: roundMoney(parseFloat(snap.finalPrice) || 0),
      lastModifiedDate: snap.lastModifiedDate
    };
  }

  _individualAdjustmentCandidate() {
    const dirty = this._typedDirtyCellsForSave();
    if (dirty.length !== 1) {
      return null;
    }
    const candidate = dirty[0];
    const { cell, month, year } = candidate;
    if (
      cell.usageBased ||
      (cell.lastEditedField !== "discount" &&
        cell.lastEditedField !== "amount") ||
      this._standardColumnReadOnly(cell.room)
    ) {
      return null;
    }
    const existingDiscount = this._getCommittedCellDiscount(
      month,
      year,
      cell.room
    );
    if (!Number.isFinite(existingDiscount)) {
      return null;
    }
    if (cell.lastEditedField === "discount" && existingDiscount === 0) {
      return null;
    }
    return {
      ...candidate,
      inputType: cell.lastEditedField === "amount" ? "Amount" : "Percentage",
      inputValue:
        cell.lastEditedField === "amount"
          ? parseFloat(cell.enteredAdjustmentValue) || 0
          : parseFloat(cell.enteredDiscount) || 0,
      hasExistingAdjustment: existingDiscount !== 0
    };
  }

  _adjustmentRequest(action = this.adjustmentAction) {
    const pending = this._pendingIndividualCell;
    if (!pending?.cell) {
      return null;
    }
    return {
      paymentId: pending.cell.id,
      inputType: pending.inputType,
      inputValue: pending.inputValue,
      action,
      currentStateExpectation:
        this.adjustmentPreview?.currentStateExpectation || null
    };
  }

  async openAdjustmentPreview(candidate) {
    this._pendingIndividualCell = candidate;
    this.adjustmentAction = "Replace";
    this.adjustmentPreview = null;
    await this.refreshAdjustmentPreview();
  }

  async refreshAdjustmentPreview() {
    const request = this._adjustmentRequest();
    if (!request) {
      return;
    }
    this.adjustmentPreviewLoading = true;
    try {
      this.adjustmentPreview = await previewIndividualAdjustment({ request });
    } catch (error) {
      this.closeAdjustmentPreview();
      const message =
        error?.body?.message ||
        error?.message ||
        this.customLabels.adjustmentStaleError;
      this.showToast("Error", message, "error");
    } finally {
      this.adjustmentPreviewLoading = false;
    }
  }

  async handleAdjustmentActionChange(event) {
    this.adjustmentAction = event.detail?.value || event.target?.value;
    // Keep the previous preview visible until the new one returns so the
    // modal does not collapse to a tall spinner-only shell.
    await this.refreshAdjustmentPreview();
  }

  handleBulkAdjustmentActionChange(event) {
    this.bulkAdjustmentAction = event.detail?.value || event.target?.value;
  }

  closeAdjustmentPreview() {
    this.adjustmentPreview = null;
    this.adjustmentPreviewLoading = false;
    this.adjustmentAction = "Replace";
    this._pendingIndividualCell = null;
  }

  async applyIndividualAmountSet(candidate) {
    this._pendingIndividualCell = candidate;
    this.savingDiscounts = true;
    try {
      await applyIndividualAdjustment({
        request: this._adjustmentRequest("Set")
      });
      this.closeAdjustmentPreview();
      await this.getData();
      this.showToast("Success", "Prices updated successfully", "success");
      this.dispatchEvent(
        new CustomEvent("monthlypaymentssaved", {
          bubbles: true,
          composed: true
        })
      );
    } catch (error) {
      this.closeAdjustmentPreview();
      const message =
        error?.body?.message ||
        error?.message ||
        this.customLabels.adjustmentStaleError;
      this.showToast("Error", message, "error");
      await this.getData();
    } finally {
      this.savingDiscounts = false;
    }
  }

  async applyBulkAdjustmentSave(candidate) {
    const items = candidate.items
      .map(({ cell, month, year }) => {
        const currentStateExpectation = this._getCommittedCellExpectation(
          month,
          year,
          cell.room
        );
        if (!currentStateExpectation) {
          return null;
        }
        return {
          paymentId: cell.id,
          currentStateExpectation
        };
      })
      .filter((item) => item != null);
    if (items.length !== candidate.items.length) {
      this.showToast(
        "Error",
        this.customLabels.adjustmentBulkStaleError,
        "error"
      );
      return;
    }
    this.savingDiscounts = true;
    try {
      await applyBulkAdjustment({
        bulkRequest: {
          inputType: candidate.inputType,
          inputValue: candidate.inputValue,
          action: this.bulkAdjustmentAction,
          items
        }
      });
      await this.getData();
      this.showToast("Success", "Prices updated successfully", "success");
      this.dispatchEvent(
        new CustomEvent("monthlypaymentssaved", {
          bubbles: true,
          composed: true
        })
      );
    } catch (error) {
      const message =
        error?.body?.message ||
        error?.message ||
        this.customLabels.adjustmentBulkStaleError;
      this.showToast("Error", message, "error");
      await this.getData();
    } finally {
      this.savingDiscounts = false;
    }
  }

  async confirmAdjustmentPreview() {
    const request = this._adjustmentRequest();
    if (!request?.currentStateExpectation) {
      return;
    }
    this.savingDiscounts = true;
    try {
      await applyIndividualAdjustment({ request });
      this.closeAdjustmentPreview();
      await this.getData();
      this.showToast("Success", "Prices updated successfully", "success");
      this.dispatchEvent(
        new CustomEvent("monthlypaymentssaved", {
          bubbles: true,
          composed: true
        })
      );
    } catch (error) {
      this.closeAdjustmentPreview();
      const message =
        error?.body?.message ||
        error?.message ||
        this.customLabels.adjustmentStaleError;
      this.showToast("Error", message, "error");
      await this.getData();
    } finally {
      this.savingDiscounts = false;
    }
  }

  handleCancelClick() {
    if (!this._lastCommittedMonthlyPayments) {
      return;
    }
    this.monthlyPayments = JSON.parse(
      JSON.stringify(this._lastCommittedMonthlyPayments)
    );
    this.applySelectionFilter();
    this._syncUnsavedFlag();
  }

  commitDiscountsToServer() {
    const monthsToSave = this.hasSelection
      ? this.filteredMonthlyPayments
      : this.monthlyPayments;
    const paymentsToUpdate = [];
    const enteredPercentageByPaymentId = {};
    (monthsToSave || []).forEach((m) => {
      (m.data || []).forEach((p) => {
        if (!this._isCellDirty(m.month, m.year, p.room)) {
          return;
        }
        const paymentEndYmd = this._fmtYmd(p.endDate);
        const orderStartYmd = this._fmtYmd(p.orderStartDate);
        if (paymentEndYmd && orderStartYmd && paymentEndYmd < orderStartYmd) {
          return;
        }
        if (p.usageBased && !this._isUsageBasedFinalPriceEditable(p)) {
          return;
        }
        if (p.usageBased) {
          paymentsToUpdate.push({
            Id: p.id,
            ListPrice__c: p.finalPriceUnset
              ? null
              : roundMoney(parseFloat(p.finalPrice) || 0)
          });
          return;
        }
        const exactFinal = parseFloat(p.finalPrice);
        const row = {
          Id: p.id,
          Discount__c: this._discountForSave(p, m.month, m.year)
        };
        if (p.lastEditedField === "discount") {
          enteredPercentageByPaymentId[p.id] =
            parseFloat(p.enteredDiscount) || 0;
        }
        // Split-month Amount is blended (Price × weighted Discount), not a typed lock.
        if (
          p.lastEditedField !== "discount" &&
          !this._isSplitMonthCell(p) &&
          Number.isFinite(exactFinal)
        ) {
          row.Final_Adjusted_Price__c = exactFinal;
        }
        paymentsToUpdate.push(row);
      });
    });
    if (paymentsToUpdate.length === 0) {
      this.showToast("Info", "No price changes to save.", "info");
      return;
    }
    this.savingDiscounts = true;
    updateDiscount({
      payments: paymentsToUpdate,
      enteredPercentageByPaymentId
    })
      .then(() => {
        this._lastCommittedMonthlyPayments = JSON.parse(
          JSON.stringify(this.monthlyPayments)
        );
        this._syncUnsavedFlag();
        this.showToast("Success", "Prices updated successfully", "success");
        this.dispatchEvent(
          new CustomEvent("monthlypaymentssaved", {
            bubbles: true,
            composed: true
          })
        );
      })
      .catch((error) => {
        console.error("Error saving records:", error);
        const msg = error?.body?.message || error?.message || "Unknown error";
        this.showToast("Error", "Error saving records: " + msg, "error");
      })
      .finally(() => {
        this.savingDiscounts = false;
      });
  }

  handleApplyOptimizer() {
    if (
      this.discountApplyChoice === "Custom" &&
      this.isCustomDateRangeInvalid
    ) {
      if (this.customRangeErrorMessage) {
        this.showToast(
          "Validation Error",
          this.customRangeErrorMessage,
          "error"
        );
      }
      return;
    }
    this.applyFilters();
    this._syncUnsavedFlag();
  }

  resetPriceOptimizerBlock() {
    this.globalDiscount = "";
    this.bulkAdjustmentAction = "Replace";
    this.yearToApplyDiscount = null;
    if (this.showPriceOptimizerFields) {
      this.discountApplyChoice = "Custom";
      this.discountFormat = "Amount";
      this.isYear = false;
      this.customStartDate = this.contractStartDateYmd || null;
      this.customEndDate = this.contractEndDateYmd || null;
    } else {
      this.customStartDate = null;
      this.customEndDate = null;
      this.discountApplyChoice = "Year";
      this.discountFormat = "Percentage";
      this.isYear = true;
    }
    this.globalFinalPriceForProductSelected = null;
    this._initLinkedPriceFields();
  }

  showToast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
