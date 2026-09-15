// WI-000168: Package Builder - date-based discount, Save/Cancel footer, oncellchange support
import { LightningElement, api, track, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import {
  getObjectInfo,
  getPicklistValuesByRecordType
} from "lightning/uiObjectInfoApi";
import {
  updateRecord,
  getRecord,
  notifyRecordUpdateAvailable
} from "lightning/uiRecordApi";
import {
  registerRefreshHandler,
  unregisterRefreshHandler
} from "lightning/refresh";
import {
  subscribe,
  unsubscribe,
  MessageContext
} from "lightning/messageService";
import PACKAGE_BUILDER_REFRESH from "@salesforce/messageChannel/PackageBuilderRefresh__c";
import OPPORTUNITY_OBJECT from "@salesforce/schema/Opportunity";
import ORDER_OBJECT from "@salesforce/schema/Order";
import STAGE_NAME_FIELD from "@salesforce/schema/Opportunity.StageName";
import OPP_START_DATE_FIELD from "@salesforce/schema/Opportunity.Start_Date__c";

import getProducts from "@salesforce/apex/PackageBuilderController.getProducts";
import saveLineItems from "@salesforce/apex/PackageBuilderController.saveLineItems";
import updateOrderItemEarlyExitRequest from "@salesforce/apex/PackageBuilderController.updateOrderItemEarlyExitRequest";
import deleteLineItems from "@salesforce/apex/PackageBuilderController.deleteLineItems";
import getContractOrders from "@salesforce/apex/PackageBuilderController.getContractOrders";
import getContractDates from "@salesforce/apex/PackageBuilderController.getContractDates";
import ensureDraftOrderWithStartDate from "@salesforce/apex/PackageBuilderController.ensureDraftOrderWithStartDate";
import activateDraftOrder from "@salesforce/apex/PackageBuilderController.activateDraftOrder";
import finalizeTerminateAll from "@salesforce/apex/PackageBuilderController.finalizeTerminateAll";
import reconcileContractTermsForCutoff from "@salesforce/apex/PackageBuilderController.reconcileContractTermsForCutoff";
import setOrderStatus from "@salesforce/apex/PackageBuilderController.setOrderStatus";
import cancelDraftOrder from "@salesforce/apex/PackageBuilderController.cancelDraftOrder";
import alignOrderItemDatesForStartDateChange from "@salesforce/apex/PackageBuilderController.alignOrderItemDatesForStartDateChange";
import getOrderSummary from "@salesforce/apex/PackageBuilderController.getOrderSummary";
import getOrderDetails from "@salesforce/apex/PackageBuilderController.getOrderDetails";
import getMonthlyPaymentPayableSumsForPackageBuilder from "@salesforce/apex/PackageBuilderController.getMonthlyPaymentPayableSumsForPackageBuilder";
import getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder from "@salesforce/apex/PackageBuilderController.getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder";
import hasEntryDateAdminOverride from "@salesforce/apex/PackageBuilderController.hasEntryDateAdminOverride";
import hasTerminatedEndDateAdminOverride from "@salesforce/apex/PackageBuilderController.hasTerminatedEndDateAdminOverride";
import getOrderItemTerminationReasonPicklistOptions from "@salesforce/apex/PackageBuilderController.getOrderItemTerminationReasonPicklistOptions";
import getOrderPaymentMethodPicklistOptions from "@salesforce/apex/PackageBuilderController.getOrderPaymentMethodPicklistOptions";
import bulkUpdateModal from "c/bulkUpdateModal";
import packageBuilderConfirmModal from "c/packageBuilderConfirmModal";
import {
  mergeSectionSelectionsExclusiveContractTerms,
  unionSelectionMap,
  ensureSelectionMap
} from "./packageBuilderSelectionUtils";

import {
  buildPicklistMapAllowBlank,
  canonicalPackageBuilderProductWireRow,
  formatIterationsDisplay,
  originalOrderProductIdFromRow,
  replacedOrderProductIdFromRow,
  isCatalogLineActive,
  clearOrphanReplacedOrderProductId,
  findActiveOrderLineForDraftRow,
  activeOrderLineEndDateYmd,
  replaceModalPeriodEndFloorYmd,
  orderItemTerminationReasonPresent,
  endDateYmdToRestoreAfterClearedTermination,
  draftRowForClearedTerminationRestore,
  monthlyAccessTypeFromRow,
  sortByLatestWithReplacementGroups,
  parseDate,
  monthDiffInclusive,
  computeBoundedMaxEndFromRowsAndChanges,
  hasExtensionBeyondContractEnd,
  hasExtensionBeyondOrderEnd,
  snapshotShowEndedCrossForStatusIcons,
  shouldSuppressStatusEndedCrossForMovingOut,
  shouldSuppressFutureEndBeforeMaxForReplacement,
  shouldShowStatusNewProductPlusIcon,
  maxVisibleStatusIcons,
  statusIconColumnWidthPx,
  addCalendarDaysYmd,
  replacementStartFollowsRemovedEnd,
  inferReplacedOrderProductIdForRow,
  resolveReplacementRowStatus,
  maxSelectedProductEndDateYmd,
  shouldApplyTerminateToProduct,
  pastStartSignedBlockMessage
} from "./packageBuilderTableUtils";

import {
  isPeriodicLike,
  isUsageBased,
  accessTypePicklistMapForRow,
  accessTypeOptionsFromValues,
  intersectionAccessTypesForRows,
  flipPackageBuilderAccessType,
  pastStartAccessTypePickerConfig,
  requiresEndDate,
  endDateRequiredMessage
} from "c/accessTypePolicy";

import iconReplaceMovingIn from "@salesforce/resourceUrl/PackageBuilderIconReplaceMovingIn";
import iconReplaceMovingOut from "@salesforce/resourceUrl/PackageBuilderIconReplaceMovingOut";
import iconEditPlus from "@salesforce/resourceUrl/PackageBuilderIconEditPlus";
import iconEditX from "@salesforce/resourceUrl/PackageBuilderIconEditX";
import iconNewPlus from "@salesforce/resourceUrl/PackageBuilderIconNewPlus";
import iconOrderStartWarning from "@salesforce/resourceUrl/PackageBuilderIconOrderStartWarning";
import iconFuturePlus from "@salesforce/resourceUrl/PackageBuilderIconFuturePlus";
import iconFutureEndBeforeMax from "@salesforce/resourceUrl/PackageBuilderIconFutureEndBeforeMax";
import iconMoney from "@salesforce/resourceUrl/PackageBuilderIconMoney";
import iconReplaceButton from "@salesforce/resourceUrl/PackageBuilderIconReplaceButton";
import iconEditButton from "@salesforce/resourceUrl/PackageBuilderIconEditButton";
import iconTrash from "@salesforce/resourceUrl/PackageBuilderIconTrash";
import hasSignedPastStartAdminOverride from "@salesforce/customPermission/PackageBuilder_Signed_PastStart_AdminOverride";

import None from "@salesforce/label/c.PackageBuilder_None";
import PackageBuilderTblName from "@salesforce/label/c.PackageBuilderTbl_Name";
import DeskUnitPrice from "@salesforce/label/c.PackageBuilderTbl_DeskUnitPrice";
import EndDate from "@salesforce/label/c.PackageBuilderTbl_EndDate";
import EntryDateLabel from "@salesforce/label/c.PackageBuilderTbl_EntryDate";
import EndDateBeforeOrderStart from "@salesforce/label/c.PackageBuilderTbl_EndDateBeforeOrderStart";
import EndDateOnOrBeforeToday from "@salesforce/label/c.PackageBuilderTbl_EndDateOnOrBeforeToday";
import Quantity from "@salesforce/label/c.PackageBuilderTbl_Quantity";
import Value from "@salesforce/label/c.PackageBuilderTbl_Value";
import Temporary from "@salesforce/label/c.PackageBuilderTbl_Temporary";
import EarlyExitRequestLabel from "@salesforce/label/c.PackageBuilderTbl_EarlyExitRequest";
import AccessType from "@salesforce/label/c.PackageBuilder_AccessType";
import AddProductsErrorLabel from "@salesforce/label/c.AddProducts_Error";
import AddProductSuccess from "@salesforce/label/c.PackageBuilder_AddProductSuccess";
import BulkSaveMonthlyEndDateCleared from "@salesforce/label/c.PackageBuilder_BulkSaveMonthlyEndDateCleared";
import MonthlyReplacementEndDateRequired from "@salesforce/label/c.PackageBuilder_MonthlyReplacementEndDateRequired";
import MonthlyReplacementEndDateAfterChild from "@salesforce/label/c.PackageBuilder_MonthlyReplacementEndDateAfterChild";
import DeleteProductSuccess from "@salesforce/label/c.PackageBuilder_DeleteProductSuccess";
import Cancel from "@salesforce/label/c.PackageBuilder_Cancel";
import RemoveDraftConfirm from "@salesforce/label/c.PackageBuilder_RemoveDraftConfirm";
import RemoveDraftConfirmTitle from "@salesforce/label/c.PackageBuilder_RemoveDraftConfirmTitle";
import RemoveDraftSuccess from "@salesforce/label/c.PackageBuilder_RemoveDraftSuccess";
import RemoveDraftIconHelp from "@salesforce/label/c.PackageBuilder_RemoveDraftIconHelp";
import AvailableStatus from "@salesforce/label/c.PackageBuilder_AvailableStatus";
import PartlyAvailableStatus from "@salesforce/label/c.PackageBuilder_PartlyAvailableStatus";
import NotAvailableStatus from "@salesforce/label/c.PackageBuilder_NotAvailableStatus";
import ProductTableSubType from "@salesforce/label/c.AddProductsFltr_SubType";
import StatusIconNewProduct from "@salesforce/label/c.PackageBuilder_StatusIcon_NewProduct";
import StatusIconCrossOrderStart from "@salesforce/label/c.PackageBuilder_StatusIcon_CrossOrderStart";
import StatusIconProductEnded from "@salesforce/label/c.PackageBuilder_StatusIcon_ProductEnded";
import StatusIconFuturePlusEntry from "@salesforce/label/c.PackageBuilder_StatusIcon_FuturePlusEntry";
import StatusIconFuturePlusEntryActive from "@salesforce/label/c.PackageBuilder_StatusIcon_FuturePlusEntryActive";
import StatusIconFutureXOtherProducts from "@salesforce/label/c.PackageBuilder_StatusIcon_FutureXOtherProducts";
import StatusIconMoneyFinancial from "@salesforce/label/c.PackageBuilder_StatusIcon_MoneyFinancial";
import StatusIconReplacementRemoved from "@salesforce/label/c.PackageBuilder_StatusIcon_ReplacementRemoved";
import StatusIconReplacementAdded from "@salesforce/label/c.PackageBuilder_StatusIcon_ReplacementAdded";
import StatusIconModified from "@salesforce/label/c.PackageBuilder_StatusIcon_Modified";
import RowActionDeleteProduct from "@salesforce/label/c.PackageBuilder_RowAction_DeleteProduct";
import RowActionReplaceProduct from "@salesforce/label/c.PackageBuilder_RowAction_ReplaceProduct";
import TerminateSelectedHover from "@salesforce/label/c.PackageBuilder_TerminateSelectedHover";
import PackageBuilderOpportunityClosedWonReadOnly from "@salesforce/label/c.PackageBuilder_OpportunityClosedWonReadOnly";
import PackageBuilderContractStatusTerminated from "@salesforce/label/c.PackageBuilder_ContractStatus_Terminated";
import PackageBuilderTerminatedProductSelectionBlocked from "@salesforce/label/c.PackageBuilder_TerminatedProductSelectionBlocked";
import PackageBuilderTerminatedOrderItemNoEdit from "@salesforce/label/c.PackageBuilder_TerminatedOrderItemNoEdit";
import PackageBuilderTerminatedProductsPartialBulkUpdate from "@salesforce/label/c.PackageBuilder_TerminatedProductsPartialBulkUpdate";
import EndDateBeforeActivatedTitle from "@salesforce/label/c.PackageBuilder_EndDateBeforeActivatedTitle";
import EndDateBeforeActivatedBody from "@salesforce/label/c.PackageBuilder_EndDateBeforeActivatedBody";
import TerminatedEndDateShortenBody from "@salesforce/label/c.PackageBuilder_TerminatedEndDateShortenBody";
import TerminationReasonBlocksEndDateClearBody from "@salesforce/label/c.PackageBuilder_TerminationReasonBlocksEndDateClearBody";

const PRODUCT_LIST_PRICE_LABEL = "Product's List Price";
const PRODUCT_PRICE_LABEL = "Product's Price";
const ROOMS_QUANTITY_LABEL = "Desks Count";
const ROOMS_UNIT_PRICE_LABEL = DeskUnitPrice;
const EXTRA_UNIT_PRICE_LABEL = "Unit Price";
const TERMINATED_DRAFT_BLOCKED_DRAFT_FIELDS = new Set([
  "AccessType",
  "EntryDate",
  "UnitPrice",
  "Quantity",
  "Description",
  "TotalPrice",
  "CpiDate",
  "OriginalStartDate",
  "OriginalEndDate",
  "Temporary"
]);

export default class PackageBuilderTable extends LightningElement {
  labels = {
    None,
    AccessType,
    PackageBuilderTblName,
    EndDate,
    Quantity,
    Value,
    Temporary,
    EarlyExitRequest: EarlyExitRequestLabel,
    Error: AddProductsErrorLabel,
    AddProductSuccess,
    BulkSaveMonthlyEndDateCleared,
    MonthlyReplacementEndDateRequired,
    MonthlyReplacementEndDateAfterChild,
    DeleteProductSuccess,
    Cancel,
    RemoveDraftConfirm,
    RemoveDraftConfirmTitle,
    RemoveDraftSuccess,
    RemoveDraftIconHelp,
    AvailableStatus,
    PartlyAvailableStatus,
    NotAvailableStatus,
    ProductTableSubType,
    EndDateBeforeOrderStart,
    EndDateOnOrBeforeToday,
    TerminationReason: "Termination Reason",
    CpiDate: "CPI Date",
    OpportunityClosedWonReadOnly: PackageBuilderOpportunityClosedWonReadOnly,
    TerminatedProductSelectionBlocked:
      PackageBuilderTerminatedProductSelectionBlocked,
    TerminatedOrderItemNoEdit: PackageBuilderTerminatedOrderItemNoEdit,
    TerminatedProductsPartialBulkUpdate:
      PackageBuilderTerminatedProductsPartialBulkUpdate,
    EndDateBeforeActivatedTitle,
    EndDateBeforeActivatedBody,
    TerminatedEndDateShortenBody,
    TerminationReasonBlocksEndDateClearBody
  };

  @api recordId;
  @api objectApiName;

  /** Wired Opportunity.StageName when record is an Opportunity (006…). */
  @track opportunityStageName = null;
  /** Opportunity.Start_Date__c (YYYY-MM-DD) for recurring min start on Opp PB Monthly Payments. */
  @track opportunityStartDateYmd = null;

  @track draftValues = [];
  _pristineProductsData = [];
  _pristineActiveProducts = [];
  _pristineDraftProducts = [];

  // --- Opportunity / Order (legacy single-context) ---
  @track productsData = [];

  // --- Contract dual-context ---
  @track activeProducts = [];
  @track draftProducts = [];
  @track activeSummary = {};
  @track draftSummary = {};
  _lastContractKpiSummary = null;
  /** Preserve Opportunity KPI tiles only while a reload is in flight (e.g. Closed Won RefreshView). */
  _lastOpportunityKpiSummary = null;
  _oppProductsReloadInFlight = false;
  @track activeTab = "active";
  @track activeOrderId = null;
  @track draftOrderId = null;
  @track isCreatingDraftFromModify = false;
  @track isDraftHydrating = false;
  @track isModifyMode = false; // Legacy: pre-persist modify clone; kept for cancel/edge paths until fully removed
  _justActivatedDraft = false; // Guard: after Activate, keep draft cleared until wire settles
  _defaultTabApplied = false; // When true, we've already set default tab to draft once when draft exists
  @track contractStartDate = null;
  @track contractEndDate = null;
  @track contractStatus = null;
  @track contractQuarterlyPayment = false;
  /** Snapshot of Quarterly_Payment__c when inline edit opens (revert on Cancel; compare on Save). */
  _contractQuarterlyPaymentSnapshot = undefined;
  /** When false: hide KPI body; when true: show 8 tiles. Applies to Contract and Opportunity. */
  @track kpiViewExpanded = true;

  /** Order section (Draft): edit mode and dirty state for SF-style edit-on-click and Save/Cancel only when changed. */
  @track orderSectionEditMode = false;
  @track orderSectionDirty = false;
  /** Expand/collapse order section body (like Summary). Default expanded. */
  @track orderSectionExpanded = true;
  /** Which single field is in inline-edit mode: 'Order_Start_Date__c' | 'EndDate' (saved draft order section) or 'effectiveDate' | 'endDate' (in-memory). Null = not editing a single field. */
  @track orderSectionEditingField = null;
  /** Saved draft inline-edit fields currently open. Allows editing multiple fields at once. */
  @track orderSectionEditingFields = [];
  /**
   * Pending values for Order fields rendered with lightning-input (not lightning-input-field),
   * so Package Builder can keep field metadata help without LDS stacking the help icon in the value column.
   */
  @track _orderSectionCustomEdits = {};
  /** Draft tab: Order_Start_Date__c edited from products toolbar (outside record-edit-form). */
  @track _toolbarEffectiveDateValue;
  /** Coalesces concurrent toolbar order-start persists (duplicate date change events → one confirm modal). */
  _toolbarOrderStartPersistPromise = null;
  /** True while footer Save is in progress (e.g. first-time draft creation). */
  @track savingDraft = false;
  /** Prevents duplicate delete Apex calls (double toast / ENTITY_IS_DELETED). */
  _lineItemDeleteInFlight = false;
  @track cancellingDraft = false;
  /** True while Activate (path or header) is calling Apex — shows spinner on status path. */
  @track isActivatingDraft = false;
  /** Coalesces concurrent Signed/Activate invocations into one activation call. */
  _activationInFlightPromise = null;
  @track activeOrderDetails = null;
  @track draftOrderDetails = null;
  @track inMemoryDraftOrder = {
    orderNumber: "Calculated upon save",
    effectiveDate: null,
    endDate: null,
    status: "Draft",
    totalAmount: null,
    description: null,
    numberOfMembers: null,
    trackCpi: null,
    autoRenewal: null,
    noticePeriodMonths: null,
    renewalTotalIterations: null,
    renewalPeriodMonths: null,
    renewalPriceIncreasePercent: null,
    googleDriveLink: null,
    earlyTerminationFee: null,
    paymentMethod: null
  };
  _orderSectionEditSnapshot = null;

  oppRecordTypeName;
  @track oppRecordTypeId = null;
  oppObjectInfo;

  columns;
  selectedRows = [];
  _selectedBySection = {
    standard: new Set(),
    parking: new Set(),
    contractTerms: new Set()
  };
  @track entryDateAdminOverride = false;
  @track terminatedEndDateAdminOverride = false;

  // Wire result handles for refreshApex
  wiredLineItemsResult;
  wiredOrdersResult;
  wiredActiveLineItemsResult;
  wiredDraftLineItemsResult;
  wiredActiveSummaryResult;
  wiredDraftSummaryResult;
  wiredActiveOrderDetailsResult;
  wiredDraftOrderDetailsResult;
  wiredContractDatesResult;
  wiredActiveMpPayableSumsResult;
  wiredDraftMpPayableSumsResult;
  wiredOppMpPayableSumsResult;
  wiredActiveMpOneMinusSumsResult;
  wiredDraftMpOneMinusSumsResult;
  wiredOppMpOneMinusSumsResult;
  mpPayableSumByLineIdActive = {};
  mpPayableSumByLineIdDraft = {};
  mpPayableSumByLineIdOpp = {};
  mpOneMinusSumByLineIdActive = {};
  mpOneMinusSumByLineIdDraft = {};
  mpOneMinusSumByLineIdOpp = {};
  _authoritativeDraftOrderId = null;
  _draftGuardUntilMs = 0;
  _modifyDraftPersistencePromise = null;
  _draftHydrationPollToken = 0;
  /** RefreshView handle so Opportunity StageName wire updates after Closed Won without full page reload. */
  _recordPageRefreshHandlerId;
  _packageBuilderRefreshSubscription;

  @wire(MessageContext)
  messageContext;

  accessTypeOptions = [];

  /** Termination_Reason__c picklist values for the inline combobox on the Draft tab (contract only). */
  terminationReasonOptions = [];
  /** Payment_Method__c picklist values for the in-memory order section combobox. */
  paymentMethodOptions = [];

  /** Map exposed to the combobox cell; preserves the "(None)" entry so users can clear. */
  get terminationReasonPicklistMap() {
    return buildPicklistMapAllowBlank(this.terminationReasonDisplayOptions);
  }

  get terminationReasonDisplayOptions() {
    const noneOption = { label: this.labels.None, value: "" };
    const base = Array.isArray(this.terminationReasonOptions)
      ? this.terminationReasonOptions
      : [];
    return [noneOption, ...base];
  }

  // ─── LIFECYCLE ────────────────────────────────────────────

  _oppProductsRefreshDone = false;
  _inferredObjectApiName;

  connectedCallback() {
    // Robust object detection from record Id prefix
    if (!this.objectApiName && this.recordId) {
      if (this.recordId.startsWith("006"))
        this._inferredObjectApiName = "Opportunity";
      else if (this.recordId.startsWith("800"))
        this._inferredObjectApiName = "Contract";
      else if (this.recordId.startsWith("801"))
        this._inferredObjectApiName = "Order";
    }

    this.setColumns();

    // Keep at least "None" while waiting for record-type values; row values are appended dynamically.
    this.accessTypeOptions = [{ label: this.labels.None, value: "" }];

    // For Opportunity/Order, wire fetches using recordId directly
    if (this.isOpportunity) {
      this.activeOrderId = this.recordId;
    }
    this.loadEntryDateEditPolicy();
    this.loadTerminatedEndDateEditPolicy();

    if (this.isOpportunity && this.recordId) {
      try {
        this._recordPageRefreshHandlerId = registerRefreshHandler(
          this,
          this._handleRecordPageRefresh.bind(this)
        );
      } catch (e) {
        console.warn("[packageBuilderTable] registerRefreshHandler skipped", e);
      }
      this._subscribePackageBuilderRefresh();
    }
  }

  _subscribePackageBuilderRefresh() {
    if (this._packageBuilderRefreshSubscription || !this.messageContext) {
      return;
    }
    this._packageBuilderRefreshSubscription = subscribe(
      this.messageContext,
      PACKAGE_BUILDER_REFRESH,
      (message) => this._handlePackageBuilderRefreshMessage(message)
    );
  }

  _handlePackageBuilderRefreshMessage(message) {
    if (
      !this.isOpportunity ||
      !this.recordId ||
      message?.recordId !== this.recordId
    ) {
      return;
    }
    this._lastOpportunityKpiSummary = null;
    this._reloadOpportunityProducts();
  }

  /**
   * When the record page runs a RefreshView pass, tell LDS to refetch this Opportunity so
   * wired StageName (Closed Won lock) stays in sync with Path / flow updates.
   */
  _handleRecordPageRefresh() {
    if (!this.isOpportunity || !this.recordId) {
      return Promise.resolve(true);
    }
    return this._reloadOpportunityProducts().then(() => true);
  }

  _reloadOpportunityProducts() {
    // Do not clear productsData here — RefreshView on Closed Won used to wipe the table/KPIs
    // while refreshApex was still in flight; keep prior rows until wired getProducts returns.
    this._oppProductsReloadInFlight = true;
    const ldsRefresh = notifyRecordUpdateAvailable([
      { recordId: this.recordId }
    ]).catch(() => undefined);
    const productsRefresh = this.refreshProductsTable().catch(() => undefined);
    return Promise.all([ldsRefresh, productsRefresh]).finally(() => {
      this._oppProductsReloadInFlight = false;
    });
  }

  async loadEntryDateEditPolicy() {
    try {
      this.entryDateAdminOverride = !!(await hasEntryDateAdminOverride());
    } catch {
      this.entryDateAdminOverride = false;
    }
  }

  async loadTerminatedEndDateEditPolicy() {
    try {
      this.terminatedEndDateAdminOverride =
        !!(await hasTerminatedEndDateAdminOverride());
    } catch {
      this.terminatedEndDateAdminOverride = false;
    }
  }

  _terminatedEndDateBaselineYmd(sourceRow) {
    if (!sourceRow) {
      return null;
    }
    return this._normalizeToYyyyMmDd(
      sourceRow.EndDate ??
        sourceRow.End_date__c ??
        sourceRow.End_Date__c ??
        null
    );
  }

  /** Terminated draft: block shortening below current termination End Date unless admin override. */
  _terminatedEndDateShortenBlocked(sourceRow, newEndYmd) {
    if (!sourceRow || !this._isTerminatedDraftOrderItemRow(sourceRow)) {
      return false;
    }
    if (this.terminatedEndDateAdminOverride) {
      return false;
    }
    const baselineYmd = this._terminatedEndDateBaselineYmd(sourceRow);
    if (!baselineYmd || !newEndYmd) {
      return false;
    }
    return newEndYmd < baselineYmd;
  }

  _showTerminatedEndDateShortenBlockedToast() {
    this.showToast(
      this.labels.EndDateBeforeActivatedTitle,
      this.labels.TerminatedEndDateShortenBody,
      "error"
    );
  }

  /** Block clearing End Date while Termination_Reason__c remains on the line. */
  _terminationReasonBlocksEndDateClear(sourceRow, newEndYmd) {
    if (!sourceRow || !this._orderItemTerminationReasonPresent(sourceRow)) {
      return false;
    }
    return !newEndYmd;
  }

  _showTerminationReasonBlocksEndDateClearToast() {
    this.showToast(
      this.labels.EndDateBeforeActivatedTitle,
      this.labels.TerminationReasonBlocksEndDateClearBody,
      "error"
    );
  }

  disconnectedCallback() {
    if (this._packageBuilderRefreshSubscription) {
      unsubscribe(this._packageBuilderRefreshSubscription);
      this._packageBuilderRefreshSubscription = null;
    }
    if (this._recordPageRefreshHandlerId != null) {
      try {
        unregisterRefreshHandler(this._recordPageRefreshHandlerId);
      } catch (e) {
        console.warn(
          "[packageBuilderTable] unregisterRefreshHandler skipped",
          e
        );
      }
      this._recordPageRefreshHandlerId = undefined;
    }
    this._stickyDraftFooterActive = false;
    this._unbindDraftFooterPositionListeners();
  }

  renderedCallback() {
    if (this.isOpportunity && this.recordId) {
      this._subscribePackageBuilderRefresh();
    }

    // Opportunity: if products are empty, force refresh (late recordId, cache, or post-Closed Won RefreshView).
    if (
      this.recordId &&
      !this.isContract &&
      (this.productsData?.length ?? 0) === 0 &&
      this.wiredLineItemsResult &&
      !this._oppProductsRefreshDone
    ) {
      this._oppProductsRefreshDone = true;
      refreshApex(this.wiredLineItemsResult);
      this._refreshMonthlyPaymentKpiWires().catch(() => {});
    }

    const sticky = this.showStickyDraftFooter;
    if (sticky && !this._stickyDraftFooterActive) {
      this._stickyDraftFooterActive = true;
      this._bindDraftFooterPositionListeners();
      this._scheduleDraftFooterPosition();
    } else if (!sticky && this._stickyDraftFooterActive) {
      this._stickyDraftFooterActive = false;
      this._unbindDraftFooterPositionListeners();
      this._resetDraftFooterDomStyles();
    }
  }

  // ─── COMPUTED PROPERTIES ──────────────────────────────────

  get isOpportunity() {
    const apiName = this.objectApiName || this._inferredObjectApiName;
    return (
      apiName === "Opportunity" ||
      (this.recordId && this.recordId.startsWith("006"))
    );
  }

  get datatableContainerClass() {
    let base = this.isOpportunity
      ? "datatable-container datatable-container--opportunity"
      : "datatable-container";
    // Contract: Draft shows row checkboxes → date columns shift +1 vs Active (no checkbox).
    // packageBuilderTableCustom.css uses this for Entry / End / Initial Period / CPI vertical dividers.
    if (this.isContract) {
      base += this.hideCheckboxColumn
        ? " datatable-container--contract-cols-no-checkbox"
        : " datatable-container--contract-cols-with-checkbox";
    }
    return base;
  }

  get isContract() {
    const apiName = this.objectApiName || this._inferredObjectApiName;
    return apiName === "Contract";
  }

  /** Contract views hide Bulk Edit (869dk2u53); Opportunity keeps it. */
  get hideBulkEditOnContract() {
    return this.isContract;
  }

  get showLegacyHeaderRenewal() {
    return false;
  }

  @track showIterationsModal = false;
  @track iterationLineIds = [];

  get iterationsModalContext() {
    return this.isOpportunity ? "Opportunity" : "Contract";
  }

  get iterationsModalArchived() {
    // Active and Draft are both editable for Iterations.
    return false;
  }

  /** Opportunity-only: show On Demand Products header styles + label. */
  get isOnDemandProducts() {
    // We always show the standard Products header regardless of Opportunity record type.
    return false;
  }

  get currentOrderId() {
    if (this.isContract) {
      if (this.activeTab === "draft") return this.draftOrderId;
      return this.activeOrderId;
    }
    return this.recordId;
  }

  get sobjectType() {
    return this.isOpportunity ? "OpportunityLineItem" : "OrderItem";
  }

  get lineItems() {
    if (this.isContract) {
      if (this.isContractActiveLineItemsContext)
        return this.sortedActiveProducts;
      return this.sortedDraftProducts;
    }
    return this._sortRowsForDisplay(this.productsData);
  }

  /** Extra section: Product2.Type__c "Extra for all products" (same toolbar behavior as Rooms). */
  _isExtraForAllProductsRow(p) {
    const t = (p?.ProductsType || p?.ProductTypeName || "").trim();
    return t === "Extra for all products";
  }

  /** Extra section: Product2.Type__c "Extra for meter Products". */
  _isExtraForMeterProductsRow(p) {
    const t = (p?.ProductsType || p?.ProductTypeName || "").trim();
    return t === "Extra for meter Products";
  }

  _isExtraSectionRow(p) {
    return (
      this._isExtraForAllProductsRow(p) || this._isExtraForMeterProductsRow(p)
    );
  }

  /** Extra section (meter credits): Product2.Type__c "Contract Terms" (restricted replace, no MP, etc.). */
  _isContractTermsRow(p) {
    const t = (p?.ProductsType || p?.ProductTypeName || "").trim();
    return t === "Contract Terms";
  }

  /** Contract Terms and past-start split replacements use edit+/X icons. */
  _useEditReplacementIcons(row, allRows) {
    if (this._isContractTermsRow(row)) {
      return true;
    }
    return this._isPastStartSplitReplacementRow(row, allRows);
  }

  _readRowAccessType(row) {
    return String(row?.AccessType || row?.Access_Type__c || "").trim();
  }

  _findPastStartSplitParentRow(row, allRows) {
    const rows = allRows || this.lineItems || [];
    const repId = this._normalizeRowId(
      row?.ReplacedOrderProductId ||
        inferReplacedOrderProductIdForRow(row, rows)
    );
    if (!repId) {
      return null;
    }
    return (
      rows.find((r) => this._normalizeRowId(r.LineItemId || r.Id) === repId) ||
      null
    );
  }

  /** New line from past-start qty or access split (869dk2u53), not normal Replace Product. */
  _isPastStartSplitChildRow(row, allRows) {
    if (!this.isContract || this.activeTab !== "draft" || !row) {
      return false;
    }
    // Access-type split (869dk96y8): edit +/- icons; not gated on parent start being in the past.
    if (row.ChangedAccessType === true) {
      return true;
    }
    const parent = this._findPastStartSplitParentRow(row, allRows);
    if (!parent || (parent.ChangeType || "").trim() !== "Removed") {
      return false;
    }
    const childStart = this._normalizeToYyyyMmDd(
      row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null
    );
    const parentStart = this._normalizeToYyyyMmDd(
      parent?.EntryDate ?? parent?.ServiceDate ?? parent?.Entry_Date__c ?? null
    );
    if (!childStart || !parentStart || childStart <= parentStart) {
      return false;
    }
    const childAt = this._readRowAccessType(row);
    const parentAt = this._readRowAccessType(parent);
    if (!childAt || !parentAt) {
      return false;
    }
    // Legacy access-type flip without Changed_Access_Type__c on the child row.
    if (
      childAt !== parentAt &&
      this._flipAccessTypeLabel(parentAt) === childAt
    ) {
      return true;
    }
    if (parentStart >= this._todayYmdUtc()) {
      return false;
    }
    const childPbe = row?.PricebookEntryId || row?.pricebookEntryId;
    const parentPbe = parent?.PricebookEntryId || parent?.pricebookEntryId;
    if (childPbe && parentPbe && childPbe !== parentPbe) {
      return false;
    }
    return childAt === parentAt;
  }

  /** New line from past-start access-type split (869dk96y8); legacy rows may carry the flag on qty splits. */
  _isAccessTypeSplitNewLine(row, allRows) {
    if (!this.isContract || this.activeTab !== "draft" || !row) {
      return false;
    }
    const parent = this._findPastStartSplitParentRow(row, allRows);
    const childAt = this._readRowAccessType(row);
    if (row.ChangedAccessType === true) {
      if (!parent) {
        return true;
      }
      const parentAt = this._readRowAccessType(parent);
      if (!childAt || !parentAt) {
        return true;
      }
      return (
        childAt !== parentAt && this._flipAccessTypeLabel(parentAt) === childAt
      );
    }
    if (!this._isPastStartSplitChildRow(row, allRows) || !parent) {
      return false;
    }
    const parentAt = this._readRowAccessType(parent);
    return (
      !!childAt &&
      !!parentAt &&
      childAt !== parentAt &&
      this._flipAccessTypeLabel(parentAt) === childAt
    );
  }

  /** Past-start qty/access split rows (869dk2u53), not normal Replace Product. */
  _isPastStartSplitReplacementRow(row, allRows) {
    if (!this.isContract || this.activeTab !== "draft" || !row) {
      return false;
    }
    if (this._isPastStartSplitChildRow(row, allRows)) {
      return true;
    }
    const rows = allRows || this.lineItems || [];
    const rowId = this._normalizeRowId(row.LineItemId || row.Id);
    if ((row.ChangeType || "").trim() !== "Removed" || !rowId) {
      return false;
    }
    return rows.some((r) => {
      const repId = this._normalizeRowId(
        r.ReplacedOrderProductId || inferReplacedOrderProductIdForRow(r, rows)
      );
      return repId === rowId && this._isPastStartSplitChildRow(r, rows);
    });
  }

  /** Row edit flags follow wire context (draft vs active), not the tab selected at load time. */
  _rowEditGate(context) {
    if (context === "contractActive") {
      return false;
    }
    if (context === "contractDraft") {
      return true;
    }
    return !this.isReadOnlyMode;
  }

  _applyRowEditabilityFlags(
    row,
    context,
    allRows,
    replacedById,
    isReplacedLine
  ) {
    if (!row) {
      return;
    }
    const gate = this._rowEditGate(context);
    const terminationBlocksAccessType =
      this.isContract &&
      !this.isOpportunity &&
      this._orderItemTerminationReasonPresent(row);
    const accessTypeLocked =
      isReplacedLine || this._isAccessTypeSplitNewLine(row, allRows);
    const usageBasedLine = isUsageBased(row?.AccessType || row?.Access_Type__c);
    row.AccessTypeEditable =
      gate && !terminationBlocksAccessType && !accessTypeLocked;
    row.AccessTypePastStartSplit =
      context === "contractDraft" &&
      this._isPastStartForSplitChange(row) &&
      !accessTypeLocked;
    row.ChangedAccessType = row.ChangedAccessType === true;
    row.QuantityEditable =
      gate &&
      !isReplacedLine &&
      !usageBasedLine &&
      this._isExtraSectionRow(row) &&
      (this.isContract || this.isOpportunity);
    row.QuantityPastStartSplit =
      context === "contractDraft" &&
      this._isPastStartForSplitChange(row) &&
      this._isExtraSectionRow(row) &&
      !isReplacedLine &&
      !usageBasedLine;
    row.UnitPriceEditable = gate && !isReplacedLine && !usageBasedLine;
    row.UnitPricePastStartSplit =
      context === "contractDraft" &&
      this._isPastStartForSplitChange(row) &&
      !isReplacedLine &&
      !usageBasedLine;
    row.TotalPriceEditable = gate && !isReplacedLine && !usageBasedLine;
    row.TotalPricePastStartSplit =
      context === "contractDraft" &&
      this._isPastStartForSplitChange(row) &&
      !isReplacedLine &&
      !usageBasedLine;
    row.TerminationReasonEditable =
      gate &&
      this.isContract &&
      !this.isOpportunity &&
      this._orderItemTerminationReasonPresent(row) &&
      !isReplacedLine;
    if (context === "contractDraft") {
      row.EntryDateEditable = this._canEditEntryDateCell(row, allRows, context);
      row.EndDateEditable = this._canEditEndDateCell(
        row,
        allRows,
        replacedById,
        context
      );
      row.ContractTermEndDateEditable = this._canEditContractTermEndDateCell(
        row,
        replacedById,
        context
      );
    }
    row.TemporaryEditable = this._canEditTemporaryCell(
      row,
      !this.isReadOnlyMode,
      isReplacedLine
    );
    row.DescriptionEditable = this._canEditDescriptionCell(row);
    // Early Exit Request: editable on Draft and Active (not gated by Active read-only).
    row.EarlyExitRequestEditable = this._canEditEarlyExitRequestCell(
      row,
      true,
      isReplacedLine
    );
  }

  /**
   * Draft Contract Terms (Contract Terms) should not render the
   * "end date before order start" cross icon.
   */
  _hideEndBeforeStartCrossInContractTerms(row, isActiveOrderLineItems) {
    return (
      this.isContract &&
      !isActiveOrderLineItems &&
      this._isContractTermsRow(row)
    );
  }

  /** True when every selected row is Contract Terms (monthly payments not available). */
  _selectionIsOnlyExtraMeterProducts() {
    const sel = this.selectedRows || [];
    if (!sel.length) {
      return false;
    }
    const rows = this.lineItems || [];
    for (const id of sel) {
      const row = rows.find((r) => (r.LineItemId || r.Id) === id);
      if (!row || !this._isContractTermsRow(row)) {
        return false;
      }
    }
    return true;
  }

  /** Rooms section: standard / on-demand lines (not Extra-for-all, not Extra-for-meter). */
  get standardProducts() {
    const items = this.lineItems || [];
    return items.filter(
      (p) => !this._isExtraSectionRow(p) && !this._isContractTermsRow(p)
    );
  }

  /** Parking section: Type "Extra for all products". */
  get parkingProducts() {
    const items = this.lineItems || [];
    return items.filter((p) => this._isExtraSectionRow(p));
  }

  get hasParkingProducts() {
    return this.parkingProducts.length > 0;
  }

  get parkingProductsCount() {
    return this.parkingProducts.length;
  }

  /**
   * Draft products sorted so replacement rows appear immediately under the replaced row.
   * Used when activeTab === 'draft' for Contract.
   */
  get sortedDraftProducts() {
    const list = this.draftProducts || [];
    if (list.length === 0) return list;
    return this._sortRowsForDisplay(list);
  }

  /**
   * Active products sorted so replacement rows appear immediately under the replaced row.
   * Concluded Terms: ended-or-today rows that are not part of a replacement pair go to the bottom.
   */
  get sortedActiveProducts() {
    const list = this.activeProducts || [];
    if (list.length === 0) return list;
    const ordered = this._sortRowsForDisplay(list);
    if (!(this.isContract && this.isContractActiveLineItemsContext)) {
      return ordered;
    }
    const replacedById = new Set();
    list.forEach((p) => {
      const replacedId = this._normalizeRowId(replacedOrderProductIdFromRow(p));
      if (replacedId) replacedById.add(replacedId);
    });
    const isReplacementLinked = (row) =>
      Boolean(this._normalizeRowId(replacedOrderProductIdFromRow(row))) ||
      replacedById.has(this._normalizeRowId(row.LineItemId || row.Id));
    const head = [];
    const tail = [];
    for (const row of ordered) {
      if (this._isRowEndedOrToday(row) && !isReplacementLinked(row)) {
        tail.push(row);
      } else {
        head.push(row);
      }
    }
    return head.concat(tail);
  }

  /** Sort by latest change while keeping replacement rows attached below replaced rows. */
  _sortRowsForDisplay(rows) {
    return sortByLatestWithReplacementGroups(rows);
  }

  _normalizeRowId(value) {
    const s = String(value || "").trim();
    return s ? s.substring(0, 15).toLowerCase() : "";
  }

  /** Resolve a grid/wire row by OrderItem id (15- and 18-char Ids must match). */
  _findLineItemRowById(rows, id) {
    const n = this._normalizeRowId(id);
    if (!n || !Array.isArray(rows)) {
      return null;
    }
    return (
      rows.find((r) => this._normalizeRowId(r.LineItemId || r.Id) === n) || null
    );
  }

  _rowModifiedTime(row) {
    const raw = row?.LineLastModifiedDateTime || row?.LastModifiedDate || null;
    const t = raw ? new Date(raw).getTime() : 0;
    return Number.isFinite(t) ? t : 0;
  }

  /** Extra section: Type "Contract Terms". */
  get contractTermsProducts() {
    const items = this.lineItems || [];
    return items.filter((p) => this._isContractTermsRow(p));
  }

  get hasContractTermsProducts() {
    return this.contractTermsProducts.length > 0;
  }

  /** True when there is at least one product (Standard or Extra). */
  get hasStandardOrExtraProducts() {
    return (this.lineItems || []).length > 0;
  }

  get contractTermsCount() {
    return this.contractTermsProducts.length;
  }

  /** Order section: show on both Active and Draft tabs when the respective order exists. */
  get showOrderSection() {
    if (!this.isContract) return false;
    if (this.activeTab === "active" || this.showModifyContractOnly)
      return this.activeOrderId != null;
    if (this.activeTab === "draft")
      return this.draftOrderId != null || this.isModifyMode;
    return false;
  }

  /** True when Draft tab is in in-memory modify mode (draft record not yet saved). */
  get showInMemoryOrderSection() {
    return (
      this.isContract &&
      this.activeTab === "draft" &&
      this.isModifyMode &&
      !this.draftOrderId
    );
  }

  /** The order Id to display in the Order section (active or draft depending on tab). */
  get orderSectionOrderId() {
    if (this.activeTab === "draft") return this.draftOrderId;
    return this.activeOrderId;
  }

  get inMemoryOrderEffectiveDate() {
    return this.inMemoryDraftOrder?.effectiveDate || null;
  }

  /** True when Order section should be read-only (Active tab). */
  get isOrderSectionReadOnly() {
    return this.activeTab !== "draft";
  }

  /** Order section header label. */
  get orderSectionTitle() {
    return "Contract Details";
  }

  /** Contract draft: Order Start Date lives on the products toolbar. */
  get showVersionStartDateInToolbar() {
    return this.isContract && this.isDraftTab && this.showOrderSection;
  }

  get savedDraftToolbarEffectiveDateInputValue() {
    if (this._toolbarEffectiveDateValue !== undefined) {
      return this._toolbarEffectiveDateValue;
    }
    return this._normalizeToYyyyMmDd(this.draftOrderDetails?.effectiveDate);
  }

  /** Earliest selectable Contract Start Date on the products toolbar (Contract.StartDate floor). */
  get toolbarOrderStartMinYmd() {
    return this._toolbarOrderStartMinYmd();
  }

  get orderSectionClass() {
    const base = "order-section";
    return this.orderSectionExpanded
      ? base
      : `${base} order-section--collapsed`;
  }

  get showSavedOrderInlineEdit() {
    return (
      this.showOrderSection &&
      this.activeTab === "draft" &&
      !this.showInMemoryOrderSection
    );
  }

  get showSavedOrderInlineView() {
    return (
      this.showOrderSection &&
      this.activeTab === "draft" &&
      !this.showInMemoryOrderSection
    );
  }

  get showActiveTabQuarterlyPaymentEdit() {
    return (
      this.showOrderSection &&
      (this.activeTab === "active" || this.showModifyContractOnly) &&
      !this.showInMemoryOrderSection
    );
  }

  get _isEditingQuarterlyPaymentOnActiveTab() {
    return (
      this.showActiveTabQuarterlyPaymentEdit &&
      this.orderSectionEditingFields.includes("Quarterly_Payment__c")
    );
  }

  isSavedOrderFieldEditing(fieldName) {
    return (
      this.showSavedOrderInlineEdit &&
      this.orderSectionEditingFields.includes(fieldName)
    );
  }

  get isEditingDescription() {
    return this.isSavedOrderFieldEditing("Description");
  }

  get isEditingAutoRenewal() {
    return this.isSavedOrderFieldEditing("Auto_Renewal__c");
  }

  get isEditingRenewalTotalIterations() {
    return this.isSavedOrderFieldEditing("Renewal_Total_Iterations__c");
  }

  get isEditingNoticePeriodMonths() {
    return this.isSavedOrderFieldEditing("Lease_Termination_Notice_Months__c");
  }

  get isEditingRenewalPeriodMonths() {
    return this.isSavedOrderFieldEditing("Renewal_Period_Months__c");
  }

  get isEditingRenewalPriceIncreasePercent() {
    return this.isSavedOrderFieldEditing("Renewal_Price_Increase_Percent__c");
  }

  get isEditingGoogleDriveLink() {
    return this.isSavedOrderFieldEditing("Google_Drive_Link__c");
  }

  get _orderSectionDetailsSource() {
    if (
      this.orderSectionOrderId &&
      this.draftOrderId &&
      this.orderSectionOrderId === this.draftOrderId
    ) {
      return this.draftOrderDetails;
    }
    return this.activeOrderDetails;
  }

  get orderSectionRenewalPriceIncreaseValue() {
    if (
      Object.prototype.hasOwnProperty.call(
        this._orderSectionCustomEdits || {},
        "Renewal_Price_Increase_Percent__c"
      )
    ) {
      return this._orderSectionCustomEdits.Renewal_Price_Increase_Percent__c;
    }
    return this._orderSectionDetailsSource?.renewalPriceIncreasePercent ?? null;
  }

  get hasOrderSectionRenewalPriceIncreaseValue() {
    return (
      this.orderSectionRenewalPriceIncreaseValue !== null &&
      this.orderSectionRenewalPriceIncreaseValue !== undefined &&
      this.orderSectionRenewalPriceIncreaseValue !== ""
    );
  }

  get orderSectionGoogleDriveLinkValue() {
    if (
      Object.prototype.hasOwnProperty.call(
        this._orderSectionCustomEdits || {},
        "Google_Drive_Link__c"
      )
    ) {
      return this._orderSectionCustomEdits.Google_Drive_Link__c;
    }
    return this._orderSectionDetailsSource?.googleDriveLink ?? null;
  }

  get isEditingPenaltyAmount() {
    return this.isSavedOrderFieldEditing("Early_Termination_Fee__c");
  }

  get isEditingNumberOfMembers() {
    return this.isSavedOrderFieldEditing("Number_of_members__c");
  }

  get isEditingPaymentMethod() {
    return this.isSavedOrderFieldEditing("Payment_Method__c");
  }

  get showPencilDescription() {
    return this.showSavedOrderInlineView && !this.isEditingDescription;
  }

  get showPencilAutoRenewal() {
    return this.showSavedOrderInlineView && !this.isEditingAutoRenewal;
  }

  get showPencilRenewalTotalIterations() {
    return (
      this.showSavedOrderInlineView && !this.isEditingRenewalTotalIterations
    );
  }

  get showPencilPenaltyAmount() {
    return this.showSavedOrderInlineView && !this.isEditingPenaltyAmount;
  }

  get showPencilNoticePeriodMonths() {
    return this.showSavedOrderInlineView && !this.isEditingNoticePeriodMonths;
  }

  get showPencilRenewalPeriodMonths() {
    return this.showSavedOrderInlineView && !this.isEditingRenewalPeriodMonths;
  }

  get showPencilRenewalPriceIncreasePercent() {
    return (
      this.showSavedOrderInlineView &&
      !this.isEditingRenewalPriceIncreasePercent
    );
  }

  get showPencilGoogleDriveLink() {
    return this.showSavedOrderInlineView && !this.isEditingGoogleDriveLink;
  }

  get showPencilNumberOfMembers() {
    return this.showSavedOrderInlineView && !this.isEditingNumberOfMembers;
  }

  get showPencilPaymentMethod() {
    return this.showSavedOrderInlineView && !this.isEditingPaymentMethod;
  }

  get isEditingQuarterlyPayment() {
    if (this.showInMemoryOrderSection) {
      return this._isInMemoryFieldEditing("quarterlyPayment");
    }
    if (!this.orderSectionEditingFields.includes("Quarterly_Payment__c")) {
      return false;
    }
    return (
      this.showSavedOrderInlineEdit || this.showActiveTabQuarterlyPaymentEdit
    );
  }

  get inMemoryEditQuarterlyPayment() {
    return this._isInMemoryFieldEditing("quarterlyPayment");
  }

  get showPencilInMemoryQuarterlyPayment() {
    return this.showInMemoryOrderSection && !this.inMemoryEditQuarterlyPayment;
  }

  get showPencilQuarterlyPayment() {
    if (this.showInMemoryOrderSection) {
      return this.showPencilInMemoryQuarterlyPayment;
    }
    return (
      (this.showSavedOrderInlineView ||
        this.showActiveTabQuarterlyPaymentEdit) &&
      !this.isEditingQuarterlyPayment
    );
  }

  _isInMemoryFieldEditing(fieldKey) {
    return (
      this.showInMemoryOrderSection &&
      this.orderSectionEditMode &&
      this.orderSectionEditingFields.includes(fieldKey)
    );
  }

  get inMemoryEditDescription() {
    return this._isInMemoryFieldEditing("description");
  }
  get inMemoryEditNumberOfMembers() {
    return this._isInMemoryFieldEditing("numberOfMembers");
  }
  get inMemoryEditAutoRenewal() {
    return this._isInMemoryFieldEditing("autoRenewal");
  }
  get inMemoryEditRenewalTotalIterations() {
    return this._isInMemoryFieldEditing("renewalTotalIterations");
  }
  get inMemoryEditNoticePeriodMonths() {
    return this._isInMemoryFieldEditing("noticePeriodMonths");
  }
  get inMemoryEditRenewalPeriodMonths() {
    return this._isInMemoryFieldEditing("renewalPeriodMonths");
  }
  get inMemoryEditRenewalPriceIncreasePercent() {
    return this._isInMemoryFieldEditing("renewalPriceIncreasePercent");
  }
  get inMemoryEditGoogleDriveLink() {
    return this._isInMemoryFieldEditing("googleDriveLink");
  }
  get inMemoryEditPenaltyAmount() {
    return this._isInMemoryFieldEditing("earlyTerminationFee");
  }
  get inMemoryEditPaymentMethod() {
    return this._isInMemoryFieldEditing("paymentMethod");
  }
  get showPencilInMemoryDescription() {
    return this.showInMemoryOrderSection && !this.inMemoryEditDescription;
  }
  get showPencilInMemoryNumberOfMembers() {
    return this.showInMemoryOrderSection && !this.inMemoryEditNumberOfMembers;
  }
  get showPencilInMemoryAutoRenewal() {
    return this.showInMemoryOrderSection && !this.inMemoryEditAutoRenewal;
  }
  get showPencilInMemoryRenewalTotalIterations() {
    return (
      this.showInMemoryOrderSection && !this.inMemoryEditRenewalTotalIterations
    );
  }
  get showPencilInMemoryNoticePeriodMonths() {
    return (
      this.showInMemoryOrderSection && !this.inMemoryEditNoticePeriodMonths
    );
  }
  get showPencilInMemoryRenewalPeriodMonths() {
    return (
      this.showInMemoryOrderSection && !this.inMemoryEditRenewalPeriodMonths
    );
  }
  get showPencilInMemoryRenewalPriceIncreasePercent() {
    return (
      this.showInMemoryOrderSection &&
      !this.inMemoryEditRenewalPriceIncreasePercent
    );
  }
  get showPencilInMemoryGoogleDriveLink() {
    return this.showInMemoryOrderSection && !this.inMemoryEditGoogleDriveLink;
  }

  get inMemoryRenewalEndDateDisplay() {
    const endYmd = this._normalizeToYyyyMmDd(this.inMemoryDraftOrder?.endDate);
    const months = this.inMemoryDraftOrder?.renewalPeriodMonths;
    if (!endYmd || months == null || months === "") {
      return "";
    }
    const computed = this._computeRenewalEndDateFromEndAndMonths(
      endYmd,
      Number(months)
    );
    return computed || "";
  }
  get showPencilInMemoryPenaltyAmount() {
    return this.showInMemoryOrderSection && !this.inMemoryEditPenaltyAmount;
  }
  get showPencilInMemoryPaymentMethod() {
    return this.showInMemoryOrderSection && !this.inMemoryEditPaymentMethod;
  }

  /** Show editable inputs in Order section (Draft tab, edit mode). */
  get showOrderSectionEditMode() {
    return (
      this.showOrderSection &&
      this.activeTab === "draft" &&
      this.orderSectionEditMode
    );
  }

  /** Show Save/Cancel only when user has made changes in Order section (saved drafts only; in-memory uses footer). */
  get showOrderSectionSaveCancel() {
    if (this.showInMemoryOrderSection) return false;
    if (this._isEditingQuarterlyPaymentOnActiveTab && this.orderSectionDirty) {
      return true;
    }
    return (
      (this.showOrderSectionEditMode ||
        this.orderSectionEditingField ||
        this.orderSectionEditingFields.length > 0) &&
      this.orderSectionDirty
    );
  }

  /** Show Cancel (exit edit mode) whenever in Order section edit mode (saved drafts only; in-memory uses footer). */
  get showOrderSectionCancelOnly() {
    if (this.showInMemoryOrderSection) return false;
    if (this._isEditingQuarterlyPaymentOnActiveTab) {
      return !this.orderSectionDirty;
    }
    return (
      (this.showOrderSectionEditMode ||
        this.orderSectionEditingField ||
        this.orderSectionEditingFields.length > 0) &&
      !this.orderSectionDirty
    );
  }

  /** True when Contract and Active tab is selected. */
  get isActiveTab() {
    return this.isContract && this.activeTab === "active";
  }

  get isDraftTab() {
    return this.isContract && this.activeTab === "draft";
  }

  /**
   * Concluded Terms line items / KPIs: use the active order whenever the UI shows that package
   * (Active tab, or single-tab mode after draft is removed). Avoids empty draft rows while activeTab
   * is still "draft" briefly during cancel-refresh.
   */
  get isContractActiveLineItemsContext() {
    return (
      this.isContract &&
      (this.activeTab === "active" || this.showModifyContractOnly)
    );
  }

  /** Count of products in the current tab view (8th KPI tile). */
  get currentProductsCount() {
    if (this.isContract) {
      return (
        (this.isContractActiveLineItemsContext
          ? this.activeProducts
          : this.draftProducts
        )?.length || 0
      );
    }
    if (this.activeTab === "active") return this.activeProducts?.length || 0;
    return this.draftProducts?.length || 0;
  }

  /**
   * Products header count for both contexts.
   * Contract: driven by current tab (active vs draft).
   * Opportunity/Order: driven by productsData (single context).
   */
  get productsHeaderCount() {
    return this.isContract ? this.currentProductsCount : this.oppProductsCount;
  }

  /** Products header supporting metadata: total monthly value (muted). */
  get productsToolbarTotalMonthlyValue() {
    return this.isContract
      ? this.currentMonthlyRevenueFromTable
      : this.oppMonthlyRevenueFromTable;
  }

  get showProductsToolbarSummary() {
    return this.productsToolbarTotalMonthlyValue > 0;
  }

  get currentMonthlyRevenueFromTable() {
    const products = this.isContract
      ? this.isContractActiveLineItemsContext
        ? this.activeProducts
        : this.draftProducts
      : this.activeTab === "active"
        ? this.activeProducts
        : this.draftProducts;
    return this._sumMonthlyRevenueForProductsByMode(products, false);
  }

  get oppMonthlyRevenueFromTable() {
    return this._sumMonthlyRevenueForProductsByMode(this.productsData, false);
  }

  _sumQuantity(products) {
    const rows = products || [];
    if (!rows.length) return 0;
    return rows.reduce((sum, p) => sum + (Number(p.Quantity) || 0), 0);
  }

  _isParkingByName(p) {
    const name = `${p?.Name || ""}`.toLowerCase();
    return name.includes("parking");
  }

  _getExtrasRowsForKpi() {
    const items = this.lineItems || [];
    return items.filter(
      (p) => this._isExtraSectionRow(p) || this._isContractTermsRow(p)
    );
  }

  _lineTotalPriceForKpi(p, useAdjustedTotals) {
    if (!p) return 0;
    return useAdjustedTotals
      ? this._effectiveLineTotalPrice(p)
      : Number(p.TotalPrice) || 0;
  }

  _sumMonthlyRevenueForProductsByMode(products, useAdjustedTotals) {
    const rows = products || [];
    if (!rows.length) return 0;
    const sum = rows.reduce((acc, p) => {
      const total = this._lineTotalPriceForKpi(p, useAdjustedTotals);
      const months = this._productMonthSpan(p);
      return acc + total / months;
    }, 0);
    return Number(sum.toFixed(2));
  }

  _readAccessTypeForKpi(p) {
    return `${p?.AccessType ?? p?.Access_Type__c ?? ""}`.trim();
  }

  _isMonthlyAccessTypeRowForKpi(p) {
    return this._readAccessTypeForKpi(p).toLowerCase() === "monthly";
  }

  _isPeriodicAccessTypeRowForKpi(p) {
    return isPeriodicLike(this._readAccessTypeForKpi(p));
  }

  /** Resolve a line Id against an Apex string-keyed rollup map (15- or 18-char Id keys). */
  _kpiSumByLineFromMap(map, lineId) {
    if (!map || !lineId) {
      return 0;
    }
    const id = String(lineId);
    const direct = map[id];
    if (direct != null && Number.isFinite(Number(direct))) {
      return Number(direct);
    }
    const keyNorm = this._normalizeRowId(id);
    if (!keyNorm) {
      return 0;
    }
    const keys = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (this._normalizeRowId(k) === keyNorm) {
        const v = map[k];
        return v != null && Number.isFinite(Number(v)) ? Number(v) : 0;
      }
    }
    return 0;
  }

  _monthlyPayableSumMapForCurrentKpiContext() {
    if (!this.isContract) {
      return this.mpPayableSumByLineIdOpp || {};
    }
    if (this.isActiveTab || this.showModifyContractOnly) {
      return this.mpPayableSumByLineIdActive || {};
    }
    return this.mpPayableSumByLineIdDraft || {};
  }

  _monthlyOneMinusSumMapForCurrentKpiContext() {
    if (!this.isContract) {
      return this.mpOneMinusSumByLineIdOpp || {};
    }
    if (this.isActiveTab || this.showModifyContractOnly) {
      return this.mpOneMinusSumByLineIdActive || {};
    }
    return this.mpOneMinusSumByLineIdDraft || {};
  }

  /**
   * KPI "Total Calculated Monthly Rooms Revenue": Monthly access → add line TotalPrice; Periodic →
   * (sum of monthly payment payables for the line) / product month span (0 when that sum is 0; no TotalPrice fallback).
   */
  _calculatedTotalMonthlyRoomsRevenue(roomsRows) {
    const map = this._monthlyPayableSumMapForCurrentKpiContext();
    let sum = 0;
    const rows = roomsRows || [];
    for (let i = 0; i < rows.length; i++) {
      const p = rows[i];
      if (this._isMonthlyAccessTypeRowForKpi(p)) {
        sum += Number(p.TotalPrice) || 0;
        continue;
      }
      const months = this._productMonthSpan(p) || 1;
      const mpTotal = this._kpiSumByLineFromMap(map, p.LineItemId || p.Id);
      sum += mpTotal / months;
    }
    return Number(sum.toFixed(2));
  }

  /**
   * KPI "Total Calculated Revenue of periodic Rooms": sum of monthly payment line payables (Price * (1 + rate);
   * rate = discount as fraction if |d| &lt; 1 else d/100, e.g. 10 = 10%) per server rollup, periodic standard lines only.
   */
  _totalCalculatedRevenuePeriodicRooms(roomsRows) {
    const map = this._monthlyOneMinusSumMapForCurrentKpiContext();
    let sum = 0;
    const rows = roomsRows || [];
    for (let i = 0; i < rows.length; i++) {
      const p = rows[i];
      if (!this._isPeriodicAccessTypeRowForKpi(p)) {
        continue;
      }
      sum += this._kpiSumByLineFromMap(map, p.LineItemId || p.Id);
    }
    return Number(sum.toFixed(2));
  }

  _sumTotalRevenueForProductsByMode(products, useAdjustedTotals) {
    const rows = products || [];
    if (!rows.length) return 0;
    const sum = rows.reduce(
      (acc, p) => acc + this._lineTotalPriceForKpi(p, useAdjustedTotals),
      0
    );
    return Number(sum.toFixed(2));
  }

  get hasActiveOrder() {
    return this.activeOrderId != null;
  }

  get hasDraftContent() {
    return this.draftOrderId != null || this.isModifyMode;
  }

  /** Show Active empty state. */
  get showActiveEmptyState() {
    return (
      (this.isActiveTab || this.showModifyContractOnly) && !this.hasActiveOrder
    );
  }

  /** Show Draft tab KPIs + table. */
  get showDraftContent() {
    return this.isDraftTab && this.hasDraftContent;
  }

  /** True when draft products exist (used by template to show draft table). */
  get hasDraftProducts() {
    return this.hasDraftContent && this.draftProducts?.length > 0;
  }

  get showDraftHydrationLoader() {
    return (
      this.isDraftTab &&
      this.draftOrderId != null &&
      !this.hasDraftProducts &&
      this.isDraftHydrating
    );
  }

  /** Show Draft empty state. */
  get showDraftEmptyState() {
    return this.isDraftTab && !this.hasDraftContent;
  }

  /** Show KPIs when there's data for the current tab (or single-view = active). */
  get showContractKpis() {
    if (this.isActiveTab || this.showModifyContractOnly)
      return this.hasActiveOrder;
    if (this.isDraftTab) return this.hasDraftContent;
    return false;
  }

  /** Show same 8 KPI tiles for Opportunity as Contract (always, even with 0 products). */
  get showOpportunityKpis() {
    return !this.isContract;
  }

  _buildKpiSummaryFromCurrentRows() {
    const roomsRows = (this.standardProducts || []).filter((p) =>
      this._isIncludedInClientKpiSummary(p)
    );
    const extrasRows = this._getExtrasRowsForKpi().filter((p) =>
      this._isIncludedInClientKpiSummary(p)
    );
    const parkingExtrasRows = extrasRows.filter((p) =>
      this._isParkingByName(p)
    );
    const nonParkingExtrasRows = extrasRows.filter(
      (p) => !this._isParkingByName(p)
    );

    const deskCount = this._sumQuantity(roomsRows);
    const parkingSpots = this._sumQuantity(parkingExtrasRows);
    const extraProducts = this._sumQuantity(nonParkingExtrasRows);

    const totalMonthlyRoomsRevenue = this._sumTotalRevenueForProductsByMode(
      roomsRows,
      false
    );
    // Total Calculated Monthly Rooms Revenue: see _calculatedTotalMonthlyRoomsRevenue (periodic uses MP sum ÷ months only).
    const totalCalculatedMonthlyRoomsRevenue =
      this._calculatedTotalMonthlyRoomsRevenue(roomsRows);
    const totalCalculatedRevenueAllRooms =
      this._totalCalculatedRevenuePeriodicRooms(roomsRows);

    const totalMonthlyParkingRevenue = this._sumTotalRevenueForProductsByMode(
      parkingExtrasRows,
      false
    );

    const averageMonthlyDesksRevenue =
      deskCount > 0
        ? Number((totalMonthlyRoomsRevenue / deskCount).toFixed(2))
        : 0;
    const averageMonthlyParkingRevenue =
      parkingSpots > 0
        ? Number((totalMonthlyParkingRevenue / parkingSpots).toFixed(2))
        : 0;

    return {
      totalMonthlyRoomsRevenue,
      averageMonthlyDesksRevenue,
      totalCalculatedMonthlyRoomsRevenue,
      deskCount,
      totalCalculatedRevenueAllRooms,
      totalMonthlyParkingRevenue,
      averageMonthlyParkingRevenue,
      parkingSpots,
      extraProducts
    };
  }

  /** Normalized KPI summary for Contract tiles/table (all values coerced to numbers). */
  get contractKpiSummary() {
    if (
      this.isContractActiveLineItemsContext &&
      this.hasActiveOrder &&
      (this.lineItems?.length || 0) === 0 &&
      this._lastContractKpiSummary
    ) {
      return this._lastContractKpiSummary;
    }
    const s = this._buildKpiSummaryFromCurrentRows();
    const summary = {
      totalMonthlyRoomsRevenue: Number(s.totalMonthlyRoomsRevenue) || 0,
      averageMonthlyDesksRevenue: Number(s.averageMonthlyDesksRevenue) || 0,
      totalCalculatedMonthlyRoomsRevenue:
        Number(s.totalCalculatedMonthlyRoomsRevenue) || 0,
      deskCount: Number(s.deskCount) || 0,
      totalCalculatedRevenueAllRooms:
        Number(s.totalCalculatedRevenueAllRooms) || 0,
      totalMonthlyParkingRevenue: Number(s.totalMonthlyParkingRevenue) || 0,
      averageMonthlyParkingRevenue: Number(s.averageMonthlyParkingRevenue) || 0,
      parkingSpots: Number(s.parkingSpots) || 0,
      extraProducts: Number(s.extraProducts) || 0
    };
    if (
      this.isContractActiveLineItemsContext &&
      (this.lineItems?.length || 0) > 0
    ) {
      this._lastContractKpiSummary = summary;
    }
    return summary;
  }

  /** Normalized KPI summary for Opportunity tiles/table (all values coerced to numbers). */
  get opportunityKpiSummary() {
    if (
      this.isOpportunity &&
      (this.productsData?.length || 0) === 0 &&
      this._lastOpportunityKpiSummary &&
      this._oppProductsReloadInFlight
    ) {
      return this._lastOpportunityKpiSummary;
    }
    const s = this._buildKpiSummaryFromCurrentRows() || {};
    const summary = {
      totalMonthlyRoomsRevenue: Number(s.totalMonthlyRoomsRevenue) || 0,
      averageMonthlyDesksRevenue: Number(s.averageMonthlyDesksRevenue) || 0,
      totalCalculatedMonthlyRoomsRevenue:
        Number(s.totalCalculatedMonthlyRoomsRevenue) || 0,
      deskCount: Number(s.deskCount) || 0,
      totalCalculatedRevenueAllRooms:
        Number(s.totalCalculatedRevenueAllRooms) || 0,
      totalMonthlyParkingRevenue: Number(s.totalMonthlyParkingRevenue) || 0,
      averageMonthlyParkingRevenue: Number(s.averageMonthlyParkingRevenue) || 0,
      parkingSpots: Number(s.parkingSpots) || 0,
      extraProducts: Number(s.extraProducts) || 0
    };
    if (this.isOpportunity && (this.productsData?.length || 0) > 0) {
      this._lastOpportunityKpiSummary = summary;
    }
    return summary;
  }

  /** Product count for Opportunity 8th tile. */
  get oppProductsCount() {
    return this.productsData?.length ?? 0;
  }

  /** Show tabs only when Contract has a draft order or user is in modify mode. */
  get showTabs() {
    return this.isContract && (this.draftOrderId != null || this.isModifyMode);
  }

  /** No draft and not in modify mode: show active contract only with "Modify Contract" button (no tab bar). */
  get showModifyContractOnly() {
    return this.isContract && this.draftOrderId == null && !this.isModifyMode;
  }

  get contractTopBarClass() {
    const base = "top-bar-inline top-bar-spacing";
    if (this.showTabs) return `${base} top-bar-tabs-with-actions`;
    return `${base} top-bar-actions-right top-bar-actions-group-standalone`;
  }

  get isOpportunityLocked() {
    return this.isOpportunity && this.opportunityStageName === "Closed Won";
  }

  get isReadOnlyMode() {
    if (this.isContract) {
      return this.activeTab === "active"; // Active tab is read-only
    }
    if (this.isOpportunityLocked) {
      return true;
    }
    return false;
  }

  get showOpportunityClosedWonBanner() {
    return this.isOpportunityLocked;
  }

  get hideCheckboxColumn() {
    // 869dbvxp7: on a Closed Won opportunity or Contract Concluded Terms (active tab)
    // the rest of the UI is read-only, but users still need to pick rows to open the
    // Monthly Payments drawer in view-only mode. Keep the checkbox column visible;
    // everything else inside the drawer is gated by `isMonthlyPaymentsReadOnly`.
    if (this.isOpportunity && this.isOpportunityLocked) {
      return false;
    }
    if (this.isContract && this.activeTab === "active") {
      return false;
    }
    return this.isReadOnlyMode;
  }

  /** Draft tab: toolbar visible but no product rows yet (draft exists). Used to wrap toolbar in products-panel alone. */
  get showContractDraftToolbarWithoutTable() {
    return (
      this.isContract &&
      this.isDraftTab &&
      this.showToolbar &&
      !this.hasDraftProducts &&
      !this.showDraftEmptyState
    );
  }

  /** Toolbar visible: always for Opportunity/Order; for Contract Active when tab has products; for Contract Draft when tab has products OR draft exists (so user can add first product) or in modify mode. */
  get showToolbar() {
    if (this.isContract) {
      if (this.activeTab === "active") {
        return this.activeProducts && this.activeProducts.length > 0;
      }
      return (
        (this.draftProducts && this.draftProducts.length > 0) ||
        this.draftOrderId != null ||
        this.isModifyMode
      );
    }
    return true;
  }

  /** Show hint to add products when Opportunity/Order has no products. */
  get showEmptyProductHint() {
    return !this.isContract && (this.productsData?.length ?? 0) === 0;
  }

  get hasUnsavedChanges() {
    if (this.draftValues.length > 0) {
      return true;
    }
    return false;
  }

  /** Show Save/Cancel only for persisted draft edits with pending inline changes. */
  get showDraftFooter() {
    if (this.isContract) {
      return (
        this.showDraftContent &&
        this.draftOrderId != null &&
        this.hasUnsavedChanges
      );
    }
    return this.showDraftContent && this.hasUnsavedChanges;
  }

  /** Sticky viewport Save/Cancel bar: contract draft edits, or Opportunity unsaved changes. */
  get showStickyDraftFooter() {
    if (this.isContract) {
      return this.showDraftFooter;
    }
    return this.hasStandardOrExtraProducts && this.hasUnsavedChanges;
  }

  /** Show "Cancel draft order" when on Draft tab with a saved draft (not in modify mode). */
  get showCancelDraftButton() {
    return (
      this.isContract &&
      this.isDraftTab &&
      this.draftOrderId != null &&
      !this.isModifyMode
    );
  }

  get isDeleteDisabled() {
    return this.selectedRows.length === 0;
  }

  /** Add Product disabled only on Active tab (read-only). In modify mode we allow Add Product; draft is created on first Add Product click. */
  get isAddProductDisabled() {
    return this.isReadOnlyMode;
  }

  /** Replace button: only for Contract Draft tab, enabled when exactly one row is selected. */
  get showReplaceButton() {
    return this.isContract && !this.isReadOnlyMode;
  }

  /** Replace disabled when no selection, multiple selection, or selected row is New (yellow) or already replaced (moving out). */
  get isReplaceDisabled() {
    if (!this.showReplaceButton || this.selectedRows.length !== 1) return true;
    const selectedId = this.selectedRows[0];
    const row = (this.lineItems || []).find(
      (r) => (r.LineItemId || r.Id) === selectedId
    );
    if (!row) return true;
    // Yellow dot = New product (including replacement lines) - cannot replace
    if ((row.ChangeType || "").trim() === "New") return true;
    // Active replacement pair (moving-in icon) — cannot replace again; orphan lookup alone is allowed
    if (row.ReplacementIcon === "moving-in") return true;
    // Moving out = this row is already the replaced one - cannot replace again
    if (row.ReplacementIcon === "moving-out") return true;
    // End date strictly before today = product already ended
    if (this._isReplaceRowEnded(row)) return true;
    return false;
  }

  /** True when the row has an end date before today (date-only, YYYY-MM-DD). Open-ended rows are not ended. */
  _isReplaceRowEnded(row) {
    if (
      monthlyAccessTypeFromRow(row) &&
      !this._orderItemTerminationReasonPresent(row) &&
      (row.ChangeType || "").trim() !== "Removed"
    ) {
      return false;
    }
    const ymd = this._formatRowEndDateYmd(row);
    if (!ymd) return false;
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    return ymd < todayYmd;
  }

  /** True when the row has an end date on or before today (date-only, YYYY-MM-DD). Open-ended rows are not ended. */
  _isRowEndedOrToday(row) {
    const ymd = this._formatRowEndDateYmd(row);
    if (!ymd) return false;
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    return ymd <= todayYmd;
  }

  _isRowStartAfterToday(row) {
    const ymd = this._normalizeToYyyyMmDd(
      row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null
    );
    if (!ymd) return false;
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    return ymd > todayYmd;
  }

  /** Contract draft: product start is strictly before today (869dk2u53 split flows). */
  _isPastStartForSplitChange(row) {
    if (!this.isContract || this.activeTab !== "draft" || this.isReadOnlyMode) {
      return false;
    }
    const ymd = this._normalizeToYyyyMmDd(
      row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null
    );
    if (!ymd) return false;
    return ymd < this._todayYmdUtc();
  }

  _flipAccessTypeLabel(raw) {
    return flipPackageBuilderAccessType(raw);
  }

  _buildBulkAccessTypeOptions(lineIds) {
    const idSet = new Set(lineIds || []);
    const rows = (this.lineItems || []).filter((r) =>
      idSet.has(r.LineItemId || r.Id)
    );
    const types = intersectionAccessTypesForRows(rows);
    return [
      { label: this.labels.None, value: "" },
      ...accessTypeOptionsFromValues(types)
    ];
  }

  /** End date from wired products (pre-grid display normalization), not reconciled draftProducts. */
  _persistedRowEndDateYmd(row) {
    const lineId = this._normalizeRowId(row?.LineItemId || row?.Id);
    const wireRows = this.wiredDraftLineItemsResult?.data;
    if (!lineId || !Array.isArray(wireRows)) {
      return this._formatRowEndDateYmd(row);
    }
    const raw =
      wireRows.find(
        (r) => this._normalizeRowId(r?.LineItemId || r?.Id) === lineId
      ) || row;
    return this._formatRowEndDateYmd(raw);
  }

  _openPastStartChangeModal(row, mode) {
    const startYmd = this._normalizeToYyyyMmDd(
      row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null
    );
    const endYmd = this._formatRowEndDateYmd(row);
    if (!startYmd) {
      this.showToast("Error", "Start date is required.", "error");
      return;
    }
    if (this._isReplaceRowEnded(row)) {
      this.showToast(
        "Error",
        "Extend the end date before changing quantity or access type.",
        "error"
      );
      return;
    }
    const orderBounds = this._getOrderDateBoundsForAddProductModal();
    const orderEndYmd = orderBounds?.orderEndDate || null;
    const productMinStart = addCalendarDaysYmd(startYmd, 1);
    const contractStartYmd = this._contractCommercialStartYmdForReplaceModal();
    const minStart =
      this._maxYmd(contractStartYmd, productMinStart) || productMinStart;
    let defaultStart = minStart;
    const todayYmd = this._todayYmdUtc();
    if (
      todayYmd &&
      minStart &&
      todayYmd >= minStart &&
      (!endYmd || todayYmd <= endYmd)
    ) {
      defaultStart = todayYmd;
    }
    const orderId = this.draftOrderId || this.currentOrderId;
    if (!orderId) {
      this.showToast("Error", "Draft order is required.", "error");
      return;
    }
    const pickerConfig = pastStartAccessTypePickerConfig(row);
    const {
      showPicker: showAccessTypePicker,
      accessTypePickerOptions,
      defaultPickerAccessType,
      currentAccessType: currentAt,
      flippedAccessType: flippedAt
    } = pickerConfig;
    this.dispatchEvent(
      new CustomEvent("openpaststartchange", {
        bubbles: true,
        composed: true,
        detail: {
          mode,
          orderId,
          replacedOrderItemId: row.LineItemId || row.Id,
          replacedPricebookEntryId:
            row?.PricebookEntryId || row?.pricebookEntryId || null,
          entryDateMinYmd: minStart,
          entryDateMaxYmd:
            mode === "accessType" ? endYmd || orderEndYmd : endYmd,
          defaultEntryDateYmd: defaultStart,
          defaultEndDateYmd:
            mode === "accessType"
              ? endYmd || this._persistedRowEndDateYmd(row) || null
              : null,
          orderEndDateYmd: mode === "accessType" ? orderEndYmd : null,
          defaultQuantity: row?.Quantity,
          currentAccessType: currentAt,
          flippedAccessType: flippedAt,
          showAccessTypePicker,
          accessTypePickerOptions,
          defaultPickerAccessType
        }
      })
    );
  }

  _dealStartDateYmdForMonthlyPayments() {
    if (this.isOpportunity) {
      return this.opportunityStartDateYmd || null;
    }
    return (
      this._orderStartDateYmdFromDetails(this.draftOrderDetails) ||
      this._orderStartDateYmdFromDetails(this.activeOrderDetails) ||
      null
    );
  }

  _openMonthlyPaymentsForPriceChange(row) {
    const lineId = row?.LineItemId || row?.Id;
    if (!lineId) return;
    const contractStart = this._dealStartDateYmdForMonthlyPayments();
    const endYmd = this._formatRowEndDateYmd(row);
    const orderId = this.draftOrderId || this.currentOrderId;
    this.dispatchEvent(
      new CustomEvent("openmonthlypaymentsdrawer", {
        bubbles: true,
        composed: true,
        detail: {
          orderId,
          tabName: this.activeTab,
          selectedLineItemIds: [lineId],
          selectedLineItemMeta: [
            {
              id: lineId,
              displayName: row?.Name || String(lineId),
              deskcount: Number(row?.Quantity ?? 0) || 0,
              unitPrice: Number(row?.UnitPrice ?? 0) || 0,
              totalPrice: Number(row?.TotalPrice ?? 0) || 0,
              accessType: row?.AccessType || row?.Access_Type__c || "",
              productType: row?.ProductsType || row?.ProductTypeName || "",
              rentEligible: row?.RentEligible === true
            }
          ],
          readOnly: this.isMonthlyPaymentsReadOnly,
          concludedTermsActiveTab:
            this.isContract && this.activeTab === "active",
          priceChangeMode: true,
          contractStartDateYmd: contractStart,
          contractEndDateYmd: endYmd
        }
      })
    );
  }

  handleFieldPencilClick(event) {
    const detail = event?.detail || {};
    const fieldName = detail.fieldName;
    const lineId = detail.keyFieldValue;
    const row = this._findLineItemRowById(this.lineItems || [], lineId);
    if (!row || !fieldName) return;

    if (fieldName === "AccessType") {
      if (this._isAccessTypeSplitNewLine(row, this.lineItems || [])) {
        event.preventDefault();
        return;
      }
      if (this._isPastStartForSplitChange(row)) {
        event.preventDefault();
        this._openPastStartChangeModal(row, "accessType");
      }
      return;
    }
    if (fieldName === "Quantity") {
      if (isUsageBased(row?.AccessType || row?.Access_Type__c)) {
        event.preventDefault();
        return;
      }
      if (
        this._isPastStartForSplitChange(row) &&
        this._isExtraSectionRow(row)
      ) {
        event.preventDefault();
        this._openPastStartChangeModal(row, "quantity");
      }
      return;
    }
    if (fieldName === "UnitPrice" || fieldName === "TotalPrice") {
      if (this._isPastStartForSplitChange(row)) {
        event.preventDefault();
        this._openMonthlyPaymentsForPriceChange(row);
      }
    }
  }

  _isReplacementChildRow(row, allRows) {
    if (!row) return false;
    return !!(
      replacedOrderProductIdFromRow(row) ||
      (allRows ? inferReplacedOrderProductIdForRow(row, allRows) : null)
    );
  }

  _isReplacedParentRow(row, replacedById) {
    if (!row) return false;
    const lineId = this._normalizeRowId(row.LineItemId || row.Id);
    if ((row.ChangeType || "").trim() === "Removed") {
      return true;
    }
    return !!(lineId && replacedById && replacedById.has(lineId));
  }

  _canEditEntryDateCell(row, allRows, context) {
    if (context === "contractActive") {
      return false;
    }
    if (!this.isContract) {
      return !this.isReadOnlyMode;
    }
    if (context !== "contractDraft") {
      return false;
    }
    if (this.entryDateAdminOverride) return true;
    const isReplacementChild = this._isReplacementChildRow(row, allRows);
    if (this._isContractTermsRow(row)) {
      return isReplacementChild;
    }
    if (isReplacementChild) {
      return true;
    }
    if (this._isNewOrReplacementDraftProductRow(row)) {
      return true;
    }
    const ymd = this._normalizeToYyyyMmDd(
      row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null
    );
    if (!ymd) return false;
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    return ymd >= todayYmd;
  }

  /**
   * Temporary: Opportunity and Contract Draft — same-site editable;
   * other-site, replaced (moving-out) parents, and Active are locked.
   */
  _canEditTemporaryCell(row, tableEditable, isReplacedLine = false) {
    if (!tableEditable || this.isReadOnlyMode) {
      return false;
    }
    if (isReplacedLine) {
      return false;
    }
    if (this.isOpportunity) {
      return row?.OtherSiteProduct !== true;
    }
    if (!this.isContract || this.activeTab !== "draft") {
      return false;
    }
    if (row?.OtherSiteProduct === true) {
      return false;
    }
    return true;
  }

  /**
   * Notes (Description): Opportunity and Contract Draft — no extra product/site/date rules.
   * Terminated draft lines and Active / read-only stay locked.
   */
  _canEditDescriptionCell(row) {
    if (this.isReadOnlyMode) {
      return false;
    }
    if (
      this.isContract &&
      !this.isOpportunity &&
      this._orderItemTerminationReasonPresent(row)
    ) {
      return false;
    }
    return true;
  }

  /**
   * Early Exit Request: contract Rooms/Extra only; Draft and Active editable
   * (Active persists immediately — no draft required).
   * Not gated by isReadOnlyMode or OtherSiteProduct (those apply to Temporary only).
   */
  _canEditEarlyExitRequestCell(row, _tableEditable, isReplacedLine = false) {
    if (!this.isContract || this.isOpportunity) {
      return false;
    }
    if (isReplacedLine) {
      return false;
    }
    if (this._isContractTermsRow(row)) {
      return false;
    }
    return true;
  }

  _setEarlyExitRequestOnLocalRows(lineId, value) {
    const nk = this._normalizeRowId(lineId);
    if (!nk) {
      return;
    }
    const next = value === true;
    const patch = (rows) => {
      if (!Array.isArray(rows)) {
        return rows;
      }
      let changed = false;
      const out = rows.map((r) => {
        if (this._normalizeRowId(r?.LineItemId || r?.Id) !== nk) {
          return r;
        }
        changed = true;
        return { ...r, EarlyExitRequest: next };
      });
      return changed ? out : rows;
    };
    this.activeProducts = patch(this.activeProducts);
    this.draftProducts = patch(this.draftProducts);
    this.productsData = patch(this.productsData);
  }

  async _persistEarlyExitRequestImmediate(rows) {
    for (const row of rows || []) {
      const id = row?.LineItemId || row?.Id;
      if (!id) {
        continue;
      }
      const next = row.EarlyExitRequest === true;
      const sourceRow = (this.lineItems || []).find(
        (r) =>
          this._normalizeRowId(r?.LineItemId || r?.Id) ===
          this._normalizeRowId(id)
      );
      const isReplacedLine =
        (sourceRow?.ChangeType || "").trim() === "Removed" ||
        sourceRow?.ReplacementIcon === "moving-out";
      if (
        sourceRow &&
        !this._canEditEarlyExitRequestCell(sourceRow, true, isReplacedLine)
      ) {
        continue;
      }
      const prev = sourceRow?.EarlyExitRequest === true;
      this._setEarlyExitRequestOnLocalRows(id, next);
      try {
        // eslint-disable-next-line no-await-in-loop -- sequential Active-tab saves with per-row revert
        await updateOrderItemEarlyExitRequest({
          orderItemId: id,
          earlyExitRequest: next
        });
        // Keep Cancel/wire snapshot aligned; refresh cacheable getProducts so Active doesn't snap back.
        this._pristineActiveProducts = this._cloneRows(
          (this._pristineActiveProducts || []).map((r) => {
            if (
              this._normalizeRowId(r?.LineItemId || r?.Id) !==
              this._normalizeRowId(id)
            ) {
              return r;
            }
            return { ...r, EarlyExitRequest: next };
          })
        );
        // eslint-disable-next-line no-await-in-loop -- refresh Active wire after each successful save
        await this._refreshApexSafe(this.wiredActiveLineItemsResult);
        this.showToast("Success", "Early Exit Request updated.", "success");
      } catch (e) {
        this._setEarlyExitRequestOnLocalRows(id, prev);
        this.showToast(
          "Error",
          this._reduceServerError(e) || "Failed to update Early Exit Request.",
          "error"
        );
      }
    }
  }

  /**
   * Client KPI inclusion: exclude Temporary; exclude EndDate strictly before cutoff.
   * Concluded Terms / Opportunity: cutoff is today (same as isIncludedInOrderSummary).
   * Contract Draft: cutoff is Order Start Date, or today when that date is empty.
   * Soft-deleted lines are already omitted from Package Builder row loads.
   */
  _isIncludedInClientKpiSummary(row) {
    if (!row) {
      return false;
    }
    if (row.Temporary === true) {
      return false;
    }
    const endYmd = this._normalizeToYyyyMmDd(
      row.EndDate ?? row.End_date__c ?? null
    );
    if (endYmd && endYmd < this._kpiInclusionCutoffYmd()) {
      return false;
    }
    return true;
  }

  /** End-date cutoff for Summary KPIs (YYYY-MM-DD). */
  _kpiInclusionCutoffYmd() {
    if (this.isContract && this.isDraftTab && !this.showModifyContractOnly) {
      const orderStartYmd = this._normalizeToYyyyMmDd(
        this._getOrderStartDateForEntryClock()
      );
      if (orderStartYmd) {
        return orderStartYmd;
      }
    }
    return this._todayYmdUtc();
  }

  /** 869dbtkre: End Date is editable inline only on the "replaced" (parent) Contract Terms row
   *  in Draft tab. The replacement (moving-in) row stays open-ended.
   */
  _canEditContractTermEndDateCell(row, replacedById, context) {
    if (context !== "contractDraft") {
      return false;
    }
    if (!this._isContractTermsRow(row)) return false;
    return this._isReplacedParentRow(row, replacedById);
  }

  /** Per-row End Date edit flag for Rooms/Extra draft rows (Contract Terms uses ContractTermEndDateEditable). */
  _canEditEndDateCell(row, allRows, replacedById, context) {
    if (context === "contractActive") {
      return false;
    }
    if (!this.isContract) {
      return !this.isReadOnlyMode;
    }
    if (context !== "contractDraft") {
      return false;
    }
    if (this._isContractTermsRow(row)) {
      return this._canEditContractTermEndDateCell(row, replacedById, context);
    }
    return true;
  }

  /**
   * Modify Contract / Create Draft: clone active lines into in-memory draft instantly.
   * Includes ended lines so Draft can show the same X-state lines immediately.
   */
  _buildInMemoryDraftProductsFromActive() {
    const list = (this.activeProducts || []).filter((p) =>
      isCatalogLineActive(p)
    );
    const keptLineItemIds = new Set(
      list
        .map((p) => this._normalizeRowId(p.LineItemId || p.Id))
        .filter(Boolean)
    );
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    const cloned = list.map((p) => {
      const copiedEntryDate =
        p.EntryDate ??
        p.ServiceDate ??
        p.Entry_Date__c ??
        p.entryDate ??
        todayYmd;
      let copy = {
        ...p,
        EntryDate: copiedEntryDate,
        OriginalStartDate:
          p.OriginalStartDate ??
          p.originalStartDate ??
          p.OriginalStartDateIso ??
          p.originalStartDateIso ??
          copiedEntryDate,
        OriginalEndDate:
          p.OriginalEndDate ??
          p.originalEndDate ??
          p.OriginalEndDateIso ??
          p.originalEndDateIso ??
          null
      };
      delete copy.ShowEndedCross;
      delete copy.ShowEndedCrossAltText;
      delete copy.StatusCrossIconUrl;
      delete copy.StatusEntryAfterStartUrl;
      delete copy.TooltipFuturePlusEntry;
      delete copy.StatusFutureEndBeforeMaxUrl;
      delete copy.StatusMonthlyMoneyIconUrl;
      delete copy.StatusNewProductIconUrl;
      delete copy.StatusCrossHover;
      delete copy.StatusReplacementHover;
      delete copy.ReplaceActionHover;
      delete copy.DeleteActionHover;
      copy = clearOrphanReplacedOrderProductId(copy, keptLineItemIds, (id) =>
        this._normalizeRowId(id)
      );
      return copy;
    });
    return this.normalizeProducts(cloned, "contractDraft");
  }

  _pbDebugEnabled() {
    try {
      // Enable from DevTools console: window.__PB_DEBUG = true; location.reload();
      return !!globalThis.__PB_DEBUG;
    } catch {
      return false;
    }
  }

  _isExistingDraftProductRow(row) {
    if (!this.isContract || this.activeTab !== "draft" || !row) return false;
    return (
      !!row.OriginalOrderProductId && (row.ChangeType || "").trim() !== "New"
    );
  }

  _isNewOrReplacementDraftProductRow(row) {
    if (!this.isContract || this.activeTab !== "draft" || !row) return false;
    if (this._isExistingLineForOrderStartDateAlign(row)) return false;
    return (
      (row.ChangeType || "").trim() === "New" ||
      !!row.ReplacedOrderProductId ||
      !row.OriginalOrderProductId
    );
  }

  /**
   * Mirrors PackageBuilderController.alignOrderItemDatesForStartDateChange when
   * alignChangeTypeNewLines is true: carried-over lines (original link + change type not New) are skipped.
   */
  _isExistingLineForOrderStartDateAlign(row) {
    if (!row) return false;
    const changeType = (row.ChangeType || "").trim();
    const hasOriginal = !!this._normalizeRowId(row.OriginalOrderProductId);
    return hasOriginal && changeType !== "New";
  }

  /**
   * True if moving the draft order start forward (or same) would bump at least one new/replacement line's
   * ServiceDate / Original_Start_Date__c under the Apex align-new-lines rules (skips ended-before-new-start
   * rows and lines already on or after the new order start).
   */
  _draftWouldForwardOrderStartRealignNewLines(newOrderStartYmd) {
    if (!newOrderStartYmd || !this.isContract || this.activeTab !== "draft") {
      return false;
    }
    for (const row of this.lineItems || []) {
      const endYmd = this._formatRowEndDateYmd(row);
      if (endYmd && endYmd < newOrderStartYmd) {
        continue;
      }
      if (this._isExistingLineForOrderStartDateAlign(row)) {
        continue;
      }
      const serviceYmd = this._normalizeToYyyyMmDd(
        row.EntryDate ?? row.ServiceDate ?? row.Entry_Date__c ?? null
      );
      if (!serviceYmd || serviceYmd < newOrderStartYmd) {
        return true;
      }
    }
    return false;
  }

  /** Tooltip for Replace: explains disabled states including ended products. */
  get replaceButtonTitle() {
    if (!this.showReplaceButton) return "Replace";
    if (this.selectedRows.length !== 1) {
      return "Replace (select exactly one product)";
    }
    const row = (this.lineItems || []).find(
      (r) => (r.LineItemId || r.Id) === this.selectedRows[0]
    );
    if (!row) return "Replace";
    if ((row.ChangeType || "").trim() === "New") {
      return "Replace is not available for new lines.";
    }
    if (row.ReplacementIcon === "moving-out") {
      return "This line cannot be replaced.";
    }
    if (this._isReplaceRowEnded(row)) {
      return "Cannot replace a product whose end date is before today.";
    }
    return "Replace selected product";
  }

  /** Bulk actions disabled when read-only or no rows selected. In modify mode (no draft yet) bulk update is allowed; draft is created on first use. */
  get toolbarBulkDisabled() {
    if (this.isContract && this.activeTab === "active") {
      // Concluded Terms tab: Terminate Products is intentionally unavailable.
      return true;
    }
    if (this.isReadOnlyMode || this.isDeleteDisabled) {
      return true;
    }
    if (
      this.isContract &&
      this.activeTab === "draft" &&
      this._selectionIsOnlyExtraMeterProducts()
    ) {
      return true;
    }
    return false;
  }

  get toolbarTerminateDisabled() {
    if (this.isContract && this.activeTab === "active") {
      return true;
    }
    if (this.isReadOnlyMode || this.isDeleteDisabled) {
      return true;
    }
    if (
      this.isContract &&
      this.activeTab === "draft" &&
      this._selectionIsOnlyExtraMeterProducts()
    ) {
      return true;
    }
    return false;
  }

  get bulkEditButtonTitle() {
    if (
      this.isContract &&
      this.activeTab === "draft" &&
      this._selectionIsOnlyExtraMeterProducts()
    ) {
      return "Bulk Edit is not available when only Contract Terms products are selected.";
    }
    if (this.isDeleteDisabled) {
      return "Select at least one product.";
    }
    return "Bulk edit selected products";
  }

  get terminateButtonTitle() {
    if (this.isContract && this.activeTab === "active") {
      return "Terminate Products is not available on Concluded Terms.";
    }
    if (
      this.isContract &&
      this.activeTab === "draft" &&
      this._selectionIsOnlyExtraMeterProducts()
    ) {
      return "Terminate Products is not available when only Contract Terms products are selected.";
    }
    if (this.isDeleteDisabled) {
      return "Select at least one product.";
    }
    return TerminateSelectedHover;
  }

  /** Monthly payments: disabled without an order, or until at least one product row is selected.
   *  Closed-Won opportunities are NOT short-circuited here — the drawer opens in read-only mode instead
   *  so users can still view the adjustments. See `isMonthlyPaymentsReadOnly`.
   */
  get isMonthlyPaymentsDisabled() {
    if (this.isContract) {
      if (!this.currentOrderId) return true;
    }
    if ((this.selectedRows || []).length === 0) {
      return true;
    }
    if (this._selectionIsOnlyExtraMeterProducts()) {
      return true;
    }
    return false;
  }

  _selectionHasUsageBasedProducts() {
    const ids = new Set((this.selectedRows || []).filter(Boolean));
    if (!ids.size) {
      return false;
    }
    const rows = this.lineItems || [];
    return [...ids].some((id) => {
      const row = this._findLineItemRowById(rows, id);
      return isUsageBased(row?.AccessType || row?.Access_Type__c);
    });
  }

  /** Monthly payments drawer should render read-only when the opportunity is Closed Won
   *  or when the user is viewing the Concluded Terms tab of a contract.
   */
  get isMonthlyPaymentsReadOnly() {
    if (this.isOpportunity && this.isOpportunityLocked) {
      return true;
    }
    if (this.isContract && this.activeTab === "active") {
      return !this._selectionHasUsageBasedProducts();
    }
    return false;
  }

  /** Tooltip for the Monthly Payments button (matches disabled reasons). Empty when no draft order yet. */
  get monthlyPaymentsButtonTitle() {
    if (this.isContract && !this.currentOrderId) {
      return "";
    }
    if (!(this.selectedRows || []).length) {
      return "";
    }
    if (this._selectionIsOnlyExtraMeterProducts()) {
      return "Monthly Payments are not available for Extra (Contract Terms) lines.";
    }
    if (this.isMonthlyPaymentsReadOnly) {
      return "View only — adjustments cannot be edited from this view.";
    }
    return "";
  }

  /** True when Contract.Status is Terminated (informational banner only). */
  get isContractTerminatedStatus() {
    if (!this.isContract) {
      return false;
    }
    return (this.contractStatus || "").trim() === "Terminated";
  }

  get showContractTerminatedNotice() {
    return (
      this.isContract && this.isContractTerminatedStatus && !this.isDraftTab
    );
  }

  /**
   * Disable Modify Contract when the activated order is fully line-terminated, signed (Status Activated),
   * and no product line has an end date in the future (blank end = still open → keep Modify enabled).
   */
  _isModifyContractDisabledForTerminatedActivatedPlan() {
    if (!this.isContract) return false;
    if (this.isContractTerminatedStatus) {
      return false;
    }
    if (!(this.activeTab === "active" || this.showModifyContractOnly))
      return false;
    if (!this.draftOrderId) {
      const todayYmd = this._todayYmdUtc();
      const anyLineEndAfterToday = (this.activeProducts || []).some((r) => {
        if (!r) return false;
        const ymd = this._normalizeToYyyyMmDd(
          r.EndDate ?? r.End_date__c ?? null
        );
        return ymd && ymd > todayYmd;
      });
      if (anyLineEndAfterToday) {
        return false;
      }
    }
    const orderStatus = (this.activeOrderDetails?.status || "").trim();
    if (orderStatus !== "Activated") return false;
    const rows = (this.activeProducts || []).filter(
      (r) => r && !this._isContractTermsRow(r)
    );
    if (!rows.length) return false;
    const allHaveTermination = rows.every(
      (r) =>
        String(
          r.TerminationReasonLabel || r.Termination_Reason__c || ""
        ).trim() !== ""
    );
    if (!allHaveTermination) return false;
    const todayYmd = this._todayYmdUtc();
    const anyOpenOrFutureEnd = rows.some((r) => {
      const endRaw = r.EndDate ?? r.End_date__c ?? null;
      if (endRaw == null || endRaw === "") return true;
      const ymd = this._normalizeToYyyyMmDd(endRaw);
      return ymd && ymd > todayYmd;
    });
    return !anyOpenOrFutureEnd;
  }

  get contractStatusBannerMessage() {
    if (!this.isContract || !this.isContractTerminatedStatus) {
      return "";
    }
    return PackageBuilderContractStatusTerminated;
  }

  /** Concluded Terms tab while a persisted draft exists (replaces one-shot toast). */
  get showOpenDraftBanner() {
    return (
      this.isContract && this.activeTab === "active" && !!this.draftOrderId
    );
  }

  get showTopReadOnlyBanner() {
    return this.isOpportunityLocked;
  }

  get showContractTopNotice() {
    return (
      this.showTopReadOnlyBanner ||
      this.showOpenDraftBanner ||
      this.showContractTerminatedNotice
    );
  }

  get topReadOnlyBannerMessage() {
    if (this.showTopReadOnlyBanner && this.isOpportunityLocked) {
      return this.labels.OpportunityClosedWonReadOnly;
    }
    if (this.showOpenDraftBanner) {
      return "Please note - there is an open draft on this contract.";
    }
    if (this.showContractTerminatedNotice) {
      return this.contractStatusBannerMessage;
    }
    return "";
  }

  // ─── WIRE: CONTRACT ORDERS ────────────────────────────────

  @wire(getContractOrders, { contractId: "$contractWireId" })
  wiredOrders(result) {
    this.wiredOrdersResult = result;
    const { data, error } = result;
    if (data) {
      this.activeOrderId = data.active?.Id || null;
      let newDraftId = data.draft?.Id || null;
      if (this._justActivatedDraft) {
        newDraftId = null;
        this.draftProducts = [];
        this.draftSummary = {};
        this._justActivatedDraft = false;
      }
      const guardActive =
        this.isCreatingDraftFromModify &&
        !!this._authoritativeDraftOrderId &&
        Date.now() < this._draftGuardUntilMs;
      if (guardActive && !newDraftId) {
        newDraftId = this._authoritativeDraftOrderId;
      }

      if (this.draftOrderId && !newDraftId) {
        this.draftProducts = [];
        this.draftSummary = {};
      }
      this.draftOrderId = newDraftId;
      if (!this.draftOrderId) {
        this._defaultTabApplied = false;
        this.isDraftHydrating = false;
      }
      if (
        this.draftOrderId &&
        this.draftOrderId === this._authoritativeDraftOrderId
      ) {
        this._draftGuardUntilMs = 0;
      }
      if (
        this.isDraftTab &&
        this.draftOrderId &&
        !this.hasDraftProducts &&
        !this.isDraftHydrating
      ) {
        this._startDraftHydrationPolling();
      }

      // If a real draft exists in DB, exit modify mode
      if (this.draftOrderId) {
        this.isModifyMode = false;
      }

      // 869dbvndm: default to "Concluded Terms" (active) when both active + draft exist;
      // only land on Draft when there is no active order yet. Surface the open draft via a toast.
      if (
        this.draftOrderId &&
        !this._defaultTabApplied &&
        !this.isCreatingDraftFromModify
      ) {
        this.activeTab = this.activeOrderId ? "active" : "draft";
        this._defaultTabApplied = true;
      }

      // Auto-switch to draft if no active but draft exists
      if (
        !this.activeOrderId &&
        this.draftOrderId &&
        this.activeTab === "active" &&
        !this.isCreatingDraftFromModify
      ) {
        this.activeTab = "draft";
      }

      // After draft disappears (e.g. Package Builder activated it server-side), avoid an empty Draft tab
      // while a real activated order still exists — show the active order (Concluded Terms tab) instead.
      if (
        this.isContract &&
        this.isDraftTab &&
        !this.draftOrderId &&
        !this.isModifyMode &&
        this.activeOrderId &&
        !this.isCreatingDraftFromModify
      ) {
        this.activeTab = "active";
        this._setUnifiedSelectedRows([]);
        this.draftValues = [];
        this.setColumns();
        this._refreshEntryDateClockIcons();
      }
      this.updateContainerButtons();
    } else if (error) {
      console.error("Error fetching contract orders:", error);
    }
  }

  // Only pass contractId when actually on a Contract page
  get contractWireId() {
    return this.isContract ? this.recordId : null;
  }

  get opportunityRecordIdForWire() {
    return this.isOpportunity ? this.recordId : null;
  }

  @wire(getRecord, {
    recordId: "$opportunityRecordIdForWire",
    fields: [STAGE_NAME_FIELD, OPP_START_DATE_FIELD]
  })
  wiredOpportunityForLock({ data, error }) {
    const prevStage = this.opportunityStageName;
    if (data?.fields?.StageName?.value != null) {
      this.opportunityStageName = data.fields.StageName.value;
    } else {
      this.opportunityStageName = null;
    }
    this.opportunityStartDateYmd = this._normalizeToYyyyMmDd(
      data?.fields?.Start_Date__c?.value
    );
    if (error && this.isOpportunity) {
      console.error("Opportunity getRecord wire error:", error);
    }
    // Column defs bake `editable` / typeAttributes at setColumns() time; refresh when stage (read-only) changes
    // so datatables match Closed Won without a full page reload.
    if (this.isOpportunity) {
      this.setColumns();
      this._refreshEntryDateClockIcons();
      if (this.isOpportunityLocked && prevStage !== "Closed Won") {
        this.draftValues = [];
        this._oppProductsRefreshDone = false;
        this.refreshProductsTable().catch(() => {});
      }
    }
  }

  @wire(getContractDates, { contractId: "$contractWireId" })
  wiredContractDates(result) {
    this.wiredContractDatesResult = result;
    const { data, error } = result;
    if (data) {
      this.contractStartDate = data.startDate || null;
      this.contractEndDate = data.endDate || null;
      this.contractStatus = data.status || null;
      this.contractQuarterlyPayment = data.quarterlyPayment === true;
      // Keep staged modify-draft order end aligned with contract when contract dates load or refresh.
      if (
        this.isContract &&
        this.showInMemoryOrderSection &&
        this.inMemoryDraftOrder &&
        !this.orderSectionDirty
      ) {
        const endYmd = this._normalizeToYyyyMmDd(this.contractEndDate);
        if (endYmd) {
          this.inMemoryDraftOrder = {
            ...this.inMemoryDraftOrder,
            endDate: endYmd
          };
        }
      }
      this.updateContainerButtons();
      this._refreshEntryDateClockIcons();
    } else if (error) {
      console.error("Error fetching contract dates:", error);
      this.contractStatus = null;
    }
  }

  @wire(getOrderDetails, { orderId: "$activeOrderId" })
  wiredActiveOrderDetails(result) {
    if (!this.isContract) return;
    this.wiredActiveOrderDetailsResult = result;
    const { data, error } = result;
    if (data) {
      this.activeOrderDetails = data;
      // If modify mode is already active, hydrate in-memory Draft Order details once active data arrives.
      if (this.showInMemoryOrderSection && !this.orderSectionDirty) {
        this.seedInMemoryDraftOrderFromActive();
      }
      this._refreshEntryDateClockIcons();
    } else if (error) {
      console.error("Error fetching active order details:", error);
    }
  }

  @wire(getOrderDetails, { orderId: "$draftOrderId" })
  wiredDraftOrderDetails(result) {
    if (!this.isContract) return;
    this.wiredDraftOrderDetailsResult = result;
    const { data, error } = result;
    if (!this.draftOrderId) {
      this.draftOrderDetails = null;
      return;
    }
    if (data) {
      this.draftOrderDetails = data;
      this._refreshEntryDateClockIcons();
    } else if (error) {
      console.error("Error fetching draft order details:", error);
    }
  }

  // ─── WIRE: PRODUCTS (PARALLEL FOR BOTH TABS) ─────────────

  // For non-Contract contexts this is the single wire call
  @wire(getProducts, { recordId: "$nonContractRecordId" })
  wiredLineItems(result) {
    this.wiredLineItemsResult = result;
    const { data, error } = result;
    if (data) {
      const normalized = this.normalizeProducts(data, "nonContract");
      this.productsData = normalized;
      this._pristineProductsData = this._cloneRows(normalized);

      if (data.length > 0) {
        this.populateOppSummary(data[0]);
      } else if (this.isOpportunity) {
        this._lastOpportunityKpiSummary = null;
      }
      this.setColumns();
    } else if (error) {
      console.error("Error fetching line items:", error);
    }
  }

  get nonContractRecordId() {
    return this.isContract ? null : this.recordId;
  }

  // Contract: active order products
  @wire(getProducts, { recordId: "$activeOrderId" })
  wiredActiveLineItems(result) {
    if (!this.isContract) return;
    this.wiredActiveLineItemsResult = result;
    const { data, error } = result;
    if (data) {
      const normalized = this.normalizeProducts(data, "contractActive");
      this.activeProducts = normalized;
      this._pristineActiveProducts = this._cloneRows(normalized);
      if (data.length > 0) this.populateOppSummary(data[0]);
      this.setColumns();
    } else if (error) {
      console.error("Error fetching active products:", error);
    }
  }

  // Contract: draft order products
  @wire(getProducts, { recordId: "$draftOrderId" })
  wiredDraftLineItems(result) {
    if (!this.isContract) return;
    this.wiredDraftLineItemsResult = result;
    if (!this.draftOrderId) {
      this.draftProducts = [];
      this._pristineDraftProducts = [];
      return;
    }
    const { data, error } = result;
    if (data) {
      const normalized = this.normalizeProducts(data, "contractDraft");
      this.draftProducts = normalized;
      this._pristineDraftProducts = this._cloneRows(normalized);
      if ((this.draftProducts?.length || 0) > 0) {
        this.isDraftHydrating = false;
      }
      if (this.isContract) {
        this._refreshEntryDateClockIcons();
      }
      this.setColumns();
      this.updateContainerButtons();
    } else if (error) {
      console.error("Error fetching draft products:", error);
    }
  }

  @wire(getMonthlyPaymentPayableSumsForPackageBuilder, {
    parentRecordId: "$activeOrderId"
  })
  wiredActiveMpPayableSums(result) {
    this.wiredActiveMpPayableSumsResult = result;
    if (!this.isContract) {
      return;
    }
    const { data, error } = result;
    // Only assign when server payload is present; do not clear on in-flight (data and error both unset).
    if (data !== undefined) {
      this.mpPayableSumByLineIdActive = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching active order monthly payment KPI sums:",
        error
      );
    }
  }

  @wire(getMonthlyPaymentPayableSumsForPackageBuilder, {
    parentRecordId: "$draftOrderId"
  })
  wiredDraftMpPayableSums(result) {
    this.wiredDraftMpPayableSumsResult = result;
    if (!this.isContract) {
      return;
    }
    const { data, error } = result;
    if (data !== undefined) {
      this.mpPayableSumByLineIdDraft = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching draft order monthly payment KPI sums:",
        error
      );
    }
  }

  @wire(getMonthlyPaymentPayableSumsForPackageBuilder, {
    parentRecordId: "$nonContractRecordId"
  })
  wiredOppMpPayableSums(result) {
    this.wiredOppMpPayableSumsResult = result;
    if (this.isContract) {
      return;
    }
    const { data, error } = result;
    if (data !== undefined) {
      this.mpPayableSumByLineIdOpp = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching opportunity monthly payment KPI sums:",
        error
      );
    }
  }

  @wire(getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder, {
    parentRecordId: "$activeOrderId"
  })
  wiredActiveMpOneMinusSums(result) {
    this.wiredActiveMpOneMinusSumsResult = result;
    if (!this.isContract) {
      return;
    }
    const { data, error } = result;
    if (data !== undefined) {
      this.mpOneMinusSumByLineIdActive = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching active order monthly payment one-minus KPI sums:",
        error
      );
    }
  }

  @wire(getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder, {
    parentRecordId: "$draftOrderId"
  })
  wiredDraftMpOneMinusSums(result) {
    this.wiredDraftMpOneMinusSumsResult = result;
    if (!this.isContract) {
      return;
    }
    const { data, error } = result;
    if (data !== undefined) {
      this.mpOneMinusSumByLineIdDraft = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching draft order monthly payment one-minus KPI sums:",
        error
      );
    }
  }

  @wire(getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder, {
    parentRecordId: "$nonContractRecordId"
  })
  wiredOppMpOneMinusSums(result) {
    this.wiredOppMpOneMinusSumsResult = result;
    if (this.isContract) {
      return;
    }
    const { data, error } = result;
    if (data !== undefined) {
      this.mpOneMinusSumByLineIdOpp = data ? { ...data } : {};
    }
    if (error) {
      console.error(
        "Error fetching opportunity monthly payment one-minus KPI sums:",
        error
      );
    }
  }

  // ─── WIRE: KPI SUMMARIES (PARALLEL) ──────────────────────

  @wire(getOrderSummary, { orderId: "$activeOrderId" })
  wiredActiveSummary(result) {
    if (!this.isContract) return;
    this.wiredActiveSummaryResult = result;
    if (result.data) {
      this.activeSummary = { ...result.data };
    }
  }

  @wire(getOrderSummary, { orderId: "$draftOrderId" })
  wiredDraftSummary(result) {
    if (!this.isContract) return;
    this.wiredDraftSummaryResult = result;
    if (!this.draftOrderId) {
      this.draftSummary = {};
      return;
    }
    if (result.data) {
      this.draftSummary = { ...result.data };
    }
  }

  // ─── WIRE: PICKLIST VALUES ────────────────────────────────

  @wire(getObjectInfo, { objectApiName: ORDER_OBJECT })
  orderObjectInfo;

  @wire(getObjectInfo, { objectApiName: OPPORTUNITY_OBJECT })
  wiredOppObjectInfo(result) {
    this.oppObjectInfo = result;
  }

  /** Field Setup inline help for Order.Renewal_Price_Increase_Percent__c */
  get renewalPriceIncreaseHelp() {
    return (
      this.orderObjectInfo?.data?.fields?.Renewal_Price_Increase_Percent__c
        ?.inlineHelpText || ""
    );
  }

  get hasRenewalPriceIncreaseHelp() {
    return !!this.renewalPriceIncreaseHelp;
  }

  /** Field Setup inline help for Order.Google_Drive_Link__c */
  get googleDriveLinkHelp() {
    return (
      this.orderObjectInfo?.data?.fields?.Google_Drive_Link__c
        ?.inlineHelpText || ""
    );
  }

  get hasGoogleDriveLinkHelp() {
    return !!this.googleDriveLinkHelp;
  }

  get computedOppRecordTypeId() {
    // Prefer record type id coming from Apex (Opportunity / Contract context).
    // Fallback to the org's default Opportunity record type id so picklist wires always work.
    return (
      this.oppRecordTypeId || this.oppObjectInfo?.data?.defaultRecordTypeId
    );
  }

  @wire(getPicklistValuesByRecordType, {
    objectApiName: OPPORTUNITY_OBJECT,
    recordTypeId: "$computedOppRecordTypeId"
  })
  picklistValues({ error }) {
    // Access Type options for Package Builder come from accessTypePolicy (per-row), not this wire.
    if (error) {
      console.error("Error fetching picklist values", error);
    }
  }

  @wire(getOrderItemTerminationReasonPicklistOptions)
  wiredTerminationReasonPicklist({ data, error }) {
    if (data) {
      this.terminationReasonOptions = data.map((row) => ({
        label: row.label,
        value: row.value
      }));
      this.setColumns();
    } else if (error) {
      console.error("Error fetching termination reason picklist values", error);
    }
  }

  @wire(getOrderPaymentMethodPicklistOptions)
  wiredPaymentMethodPicklist({ data, error }) {
    if (data) {
      this.paymentMethodOptions = data.map((row) => ({
        label: row.label,
        value: row.value
      }));
    } else if (error) {
      console.error("Error fetching payment method picklist values", error);
    }
  }

  // ─── HELPERS ──────────────────────────────────────────────

  populateOppSummary(firstItem) {
    if (!firstItem) return;
    this.oppRecordTypeName = firstItem.oppRecordTypeName;
    if (firstItem.oppRecordTypeId) {
      this.oppRecordTypeId = firstItem.oppRecordTypeId;
    }
  }

  getProductAvailabilityIcon(availability) {
    switch (availability) {
      case this.labels.AvailableStatus:
        return "available";
      case this.labels.PartlyAvailableStatus:
        return "partly";
      case this.labels.NotAvailableStatus:
        return "unavailable";
      default:
        return "";
    }
  }

  /** YYYY-MM-DD for comparing wire / date-local / Date values (calendar date, not UTC midnight shift). */
  _normalizeToYyyyMmDd(value) {
    if (value === null || value === undefined || value === "") return null;
    if (typeof value === "string") {
      const s = value.trim();
      if (!s) return null;
      const isoOnly = s.match(/^(\d{4})-(\d{2})-(\d{2})$/);
      if (isoOnly) {
        return `${isoOnly[1]}-${isoOnly[2]}-${isoOnly[3]}`;
      }
      if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
        return s.substring(0, 10);
      }
      const eu = s.match(/^(\d{1,2})[./](\d{1,2})[./](\d{4})$/);
      if (eu) {
        const dd = eu[1].padStart(2, "0");
        const mm = eu[2].padStart(2, "0");
        return `${eu[3]}-${mm}-${dd}`;
      }
      return null;
    }
    if (typeof value === "object" && value.year != null) {
      return `${value.year}-${String(value.month).padStart(2, "0")}-${String(value.day).padStart(2, "0")}`;
    }
    const d = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(d.getTime())) return null;
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  /** Mirrors Order.Renewal_end_date__c formula for in-memory draft display before the order is saved. */
  _computeRenewalEndDateFromEndAndMonths(endYmd, renewalPeriodMonths) {
    if (
      !endYmd ||
      renewalPeriodMonths == null ||
      Number.isNaN(renewalPeriodMonths)
    ) {
      return null;
    }
    const parts = endYmd.split("-");
    if (parts.length !== 3) return null;
    let year = parseInt(parts[0], 10);
    let month = parseInt(parts[1], 10);
    const day = parseInt(parts[2], 10);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day))
      return null;
    const totalMonths = month + Number(renewalPeriodMonths) - 1;
    year += Math.floor((totalMonths - 1) / 12);
    month = ((totalMonths - 1) % 12) + 1;
    return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }

  /** Contract Draft: replacement pair date mirroring (see plan). */
  _replacementMirrorEligible() {
    return this.isContract && this.activeTab === "draft" && !this.isOpportunity;
  }

  /** Replacement mirror peers: do not skip read-only or terminated rows (product owner request). */
  _replacementMirrorPeerBlocked(row) {
    return !row;
  }

  /**
   * Parent line id for replacement date mirroring. Prefer Replaced_Order_Product__c; draft
   * "moving-in" rows may only have Original_Order_Product__c (see normalizeProducts isMovingIn).
   */
  _replacedParentIdForMirror(row) {
    const explicit = replacedOrderProductIdFromRow(row);
    if (explicit) {
      return explicit;
    }
    if (
      !row ||
      !this.isContract ||
      this.activeTab !== "draft" ||
      this.isOpportunity
    ) {
      return null;
    }
    if ((row.ChangeType || "").trim() !== "New") {
      return null;
    }
    return originalOrderProductIdFromRow(row);
  }

  /**
   * Find a draft grid row by its current OrderItem id, or by the activated line id stored on
   * `Original_Order_Product__c` (draft clone of an activated row).
   */
  _resolveContractDraftLineForMirror(lookupId) {
    const items = this.lineItems || [];
    const direct = this._findLineItemRowById(items, lookupId);
    if (direct) return direct;
    const lid = this._normalizeRowId(lookupId);
    if (!lid) return null;
    return (
      items.find(
        (r) => this._normalizeRowId(originalOrderProductIdFromRow(r)) === lid
      ) || null
    );
  }

  _findDirectReplacementForReplacedId(replacedId, itemsOverride) {
    const rid = this._normalizeRowId(replacedId);
    if (!rid) return null;
    const items = itemsOverride || this.lineItems || [];
    const matches = items.filter(
      (p) => this._normalizeRowId(replacedOrderProductIdFromRow(p)) === rid
    );
    if (matches.length === 1) {
      return matches[0];
    }
    if (matches.length > 1) {
      matches.sort(
        (a, b) => this._rowModifiedTime(b) - this._rowModifiedTime(a)
      );
      return matches[0];
    }
    if (!this.isContract || this.activeTab !== "draft" || this.isOpportunity) {
      return null;
    }
    const parentRow = this._findLineItemRowById(items, rid);
    const parentOrig = parentRow
      ? this._normalizeRowId(originalOrderProductIdFromRow(parentRow))
      : "";
    if (parentOrig) {
      const actMatches = items.filter(
        (p) =>
          this._normalizeRowId(replacedOrderProductIdFromRow(p)) === parentOrig
      );
      if (actMatches.length === 1) {
        return actMatches[0];
      }
      if (actMatches.length > 1) {
        actMatches.sort(
          (a, b) => this._rowModifiedTime(b) - this._rowModifiedTime(a)
        );
        return actMatches[0];
      }
    }
    if (parentRow && (parentRow.ChangeType || "").trim() === "Removed") {
      const parentEndYmd = this._normalizeToYyyyMmDd(parentRow.EndDate);
      if (parentEndYmd) {
        const dateMatches = items.filter((p) => {
          if ((p?.ChangeType || "").trim() !== "New") {
            return false;
          }
          if (this._normalizeRowId(replacedOrderProductIdFromRow(p))) {
            return false;
          }
          const startYmd = this._normalizeToYyyyMmDd(
            p.ServiceDate || p.EntryDate
          );
          return replacementStartFollowsRemovedEnd(parentEndYmd, startYmd);
        });
        if (dateMatches.length === 1) {
          return dateMatches[0];
        }
        if (dateMatches.length > 1) {
          dateMatches.sort(
            (a, b) => this._rowModifiedTime(b) - this._rowModifiedTime(a)
          );
          return dateMatches[0];
        }
      }
    }
    return (
      items.find((p) => {
        if (this._normalizeRowId(replacedOrderProductIdFromRow(p))) {
          return false;
        }
        if ((p?.ChangeType || "").trim() !== "New") {
          return false;
        }
        const orig = this._normalizeRowId(originalOrderProductIdFromRow(p));
        return orig === rid;
      }) || null
    );
  }

  /**
   * Monthly open-ended clears must not strip curtailed ends on superseded / replaced-parent lines
   * (mirrors OrderItemTriggerHandler.clearPackageEndDatesWhenMonthlyAccess).
   */
  _lineMustKeepCurtailedEndForReplacement(sourceRow) {
    if (!sourceRow || this._isTerminatedDraftOrderItemRow(sourceRow)) {
      return false;
    }
    const rowId = sourceRow.LineItemId || sourceRow.Id;
    if (rowId && this._findDirectReplacementForReplacedId(rowId)) {
      return true;
    }
    return (sourceRow.ChangeType || "").trim() === "Removed";
  }

  /**
   * Monthly replaced-parent lines must keep End Date when a replacement child exists.
   * Valid end changes mirror child start (+1 day) via _mergeReplacementMirrorIntoSavePayload.
   */
  _validateReplacedMonthlyParentEndDateEdits(saveDraftValues) {
    if (
      !this.isContract ||
      this.activeTab !== "draft" ||
      !saveDraftValues?.length
    ) {
      return true;
    }
    for (const item of saveDraftValues) {
      if (!Object.prototype.hasOwnProperty.call(item, "EndDate")) {
        continue;
      }
      const sid = item.LineItemId || item.Id;
      const sourceRow = (this.lineItems || []).find(
        (r) => (r.LineItemId || r.Id) === sid
      );
      if (!sourceRow) {
        continue;
      }
      const accessType = this._normalizeAccessTypeForTerminate(
        item.AccessType ?? sourceRow.AccessType ?? sourceRow.Access_Type__c
      );
      if (accessType !== "Monthly") {
        continue;
      }
      if (!this._lineMustKeepCurtailedEndForReplacement(sourceRow)) {
        continue;
      }
      const endYmd = this._normalizeToYyyyMmDd(item.EndDate);
      if (!endYmd) {
        this.showToast(
          "Error",
          this.labels.MonthlyReplacementEndDateRequired,
          "error"
        );
        return false;
      }
      const child = this._findDirectReplacementForReplacedId(sid);
      if (!child) {
        continue;
      }
      const newChildStart = addCalendarDaysYmd(endYmd, 1);
      const childEndYmd = this._normalizeToYyyyMmDd(
        child.EndDate ?? child.End_date__c
      );
      if (newChildStart && childEndYmd && newChildStart > childEndYmd) {
        this.showToast(
          "Error",
          this.labels.MonthlyReplacementEndDateAfterChild,
          "error"
        );
        return false;
      }
    }
    return true;
  }

  /**
   * After draft cell merges, sync replacement ↔ replaced dates (+1 / −1 calendar day) for triggers only.
   * @param {Map} byId draft row map (mutated)
   * @param {Array<{ id: string, hadEnd: boolean, hadEntry: boolean }>} incomingMetas from user incoming rows
   */
  _applyReplacementDateMirrorsToDraftMap(byId, incomingMetas) {
    if (!this._replacementMirrorEligible() || !byId || !incomingMetas?.length)
      return;
    for (const meta of incomingMetas) {
      const id = meta?.id;
      if (!id) continue;
      const sourceRow = (this.lineItems || []).find(
        (r) =>
          this._normalizeRowId(r.LineItemId || r.Id) ===
          this._normalizeRowId(id)
      );
      if (!sourceRow || this._replacementMirrorPeerBlocked(sourceRow)) continue;
      const rowKey = this._normalizeRowId(id);
      const merged = { ...sourceRow, ...(byId.get(rowKey) || {}) };
      const endYmd = meta.hadEnd
        ? this._normalizeToYyyyMmDd(merged.EndDate)
        : null;
      const startRaw = merged.EntryDate ?? merged.ServiceDate;
      const startYmd = meta.hadEntry
        ? this._normalizeToYyyyMmDd(startRaw)
        : null;
      const repChild = this._findDirectReplacementForReplacedId(
        sourceRow.LineItemId || sourceRow.Id
      );
      if (
        meta.hadEnd &&
        repChild &&
        endYmd &&
        !this._replacementMirrorPeerBlocked(repChild)
      ) {
        const nextStart = addCalendarDaysYmd(endYmd, 1);
        if (!nextStart) continue;
        const rid = repChild.LineItemId || repChild.Id;
        const ridKey = this._normalizeRowId(rid);
        const prevPeer = byId.get(ridKey) || {};
        const peerDraft = {
          ...prevPeer,
          LineItemId: rid,
          Id: rid,
          EntryDate: nextStart
        };
        if (!this.isOpportunity) {
          peerDraft.ServiceDate = nextStart;
        }
        byId.set(ridKey, peerDraft);
      }
      const parentLookup = this._replacedParentIdForMirror(sourceRow);
      if (meta.hadEntry && parentLookup && startYmd) {
        const parentRow = this._resolveContractDraftLineForMirror(parentLookup);
        if (!parentRow || this._replacementMirrorPeerBlocked(parentRow))
          continue;
        const parentEnd = addCalendarDaysYmd(startYmd, -1);
        if (!parentEnd) continue;
        const pid = parentRow.LineItemId || parentRow.Id;
        const pidKey = this._normalizeRowId(pid);
        const prevP = byId.get(pidKey) || {};
        byId.set(pidKey, {
          ...prevP,
          LineItemId: pid,
          Id: pid,
          EndDate: parentEnd
        });
      }
    }
  }

  /**
   * Expand save payload (OrderItem fields) with mirrored peer rows/fields. Mutates `arr` in place.
   * @param {Array<object>} arr filtered line save objects
   * @param {Array<object>} saveDraftValues original draftValues from the save event
   */
  _mergeReplacementMirrorIntoSavePayload(arr, saveDraftValues) {
    if (
      !this._replacementMirrorEligible() ||
      !Array.isArray(arr) ||
      !saveDraftValues?.length
    )
      return;
    const triggers = saveDraftValues.filter(
      (s) =>
        Object.prototype.hasOwnProperty.call(s, "EntryDate") ||
        Object.prototype.hasOwnProperty.call(s, "EndDate") ||
        (!this.isOpportunity &&
          Object.prototype.hasOwnProperty.call(s, "ServiceDate"))
    );
    if (!triggers.length) return;
    const rowKey = (id) => this._normalizeRowId(id) || String(id || "");
    const byId = new Map();
    arr.forEach((x) => {
      if (!x?.Id) return;
      byId.set(rowKey(x.Id), { ...x });
    });
    const ensure = (idRaw, patch) => {
      const k = rowKey(idRaw);
      const cur = byId.get(k) || { Id: idRaw, sobjectType: this.sobjectType };
      byId.set(k, { ...cur, ...patch });
    };
    for (const trig of triggers) {
      const tid = String(trig.LineItemId || trig.Id);
      const row = (this.lineItems || []).find(
        (r) =>
          this._normalizeRowId(r.LineItemId || r.Id) ===
          this._normalizeRowId(tid)
      );
      if (!row || this._replacementMirrorPeerBlocked(row)) continue;
      const hadEnd = Object.prototype.hasOwnProperty.call(trig, "EndDate");
      const hadEntry =
        Object.prototype.hasOwnProperty.call(trig, "EntryDate") ||
        (!this.isOpportunity &&
          Object.prototype.hasOwnProperty.call(trig, "ServiceDate"));
      const endYmd = hadEnd ? this._normalizeToYyyyMmDd(trig.EndDate) : null;
      const startYmd = hadEntry
        ? this._normalizeToYyyyMmDd(trig.EntryDate ?? trig.ServiceDate)
        : null;
      const child = this._findDirectReplacementForReplacedId(
        row.LineItemId || row.Id
      );
      if (
        hadEnd &&
        child &&
        endYmd &&
        !this._replacementMirrorPeerBlocked(child)
      ) {
        const ns = addCalendarDaysYmd(endYmd, 1);
        if (!ns) continue;
        const rid = String(child.LineItemId || child.Id);
        const pe = { Id: rid, sobjectType: this.sobjectType, ServiceDate: ns };
        ensure(rid, pe);
      }
      const parentId = this._replacedParentIdForMirror(row);
      if (hadEntry && parentId && startYmd) {
        const parent = this._resolveContractDraftLineForMirror(parentId);
        if (!parent || this._replacementMirrorPeerBlocked(parent)) continue;
        const ne = addCalendarDaysYmd(startYmd, -1);
        if (!ne) continue;
        const pid = String(parent.LineItemId || parent.Id);
        ensure(pid, { Id: pid, sobjectType: this.sobjectType, EndDate: ne });
      }
    }
    const origOrder = [];
    const seenO = new Set();
    arr.forEach((x) => {
      const k = rowKey(x.Id);
      if (!seenO.has(k)) {
        seenO.add(k);
        origOrder.push(k);
      }
    });
    const added = [...byId.keys()].filter((k) => !seenO.has(k));
    arr.length = 0;
    origOrder.forEach((id) => arr.push(byId.get(id)));
    added.forEach((id) => arr.push(byId.get(id)));
  }

  /**
   * Expand OrderItem DML payloads (bulk / mass / terminate) with mirrored peers. Mutates `items` in place.
   */
  _mergeReplacementMirrorIntoOrderItemList(items, triggerIds) {
    if (
      !this._replacementMirrorEligible() ||
      !Array.isArray(items) ||
      !triggerIds?.length
    )
      return;
    const rowKey = (id) => this._normalizeRowId(id) || String(id || "");
    const triggerSet = new Set(triggerIds.map((x) => rowKey(x)));
    const byId = new Map();
    items.forEach((it) => {
      if (it?.Id) byId.set(rowKey(it.Id), { ...it });
    });
    const draftMap = new Map();
    (this.draftValues || []).forEach((d) => {
      const did = d.LineItemId || d.Id;
      if (did) draftMap.set(rowKey(did), d);
    });
    const ensure = (idRaw, patch) => {
      const k = rowKey(idRaw);
      const cur = byId.get(k) || { Id: idRaw, sobjectType: this.sobjectType };
      byId.set(k, { ...cur, ...patch });
    };
    const resolveEff = (idRaw) => {
      const idStr = rowKey(idRaw);
      const row = (this.lineItems || []).find(
        (r) => this._normalizeRowId(r.LineItemId || r.Id) === idStr
      );
      if (!row) return null;
      const p = byId.get(idStr) || {};
      const d = draftMap.get(idStr) || {};
      const endRaw = Object.prototype.hasOwnProperty.call(p, "EndDate")
        ? p.EndDate
        : d.EndDate !== undefined
          ? d.EndDate
          : row.EndDate;
      const svcRaw = Object.prototype.hasOwnProperty.call(p, "ServiceDate")
        ? p.ServiceDate
        : d.EntryDate !== undefined
          ? d.EntryDate
          : (row.EntryDate ?? row.ServiceDate);
      return {
        row,
        endYmd: this._normalizeToYyyyMmDd(endRaw),
        startYmd: this._normalizeToYyyyMmDd(svcRaw),
        patch: p
      };
    };
    for (const tid of triggerSet) {
      const idStr = rowKey(tid);
      const sourceRow = (this.lineItems || []).find(
        (r) => this._normalizeRowId(r.LineItemId || r.Id) === idStr
      );
      if (!sourceRow || this._replacementMirrorPeerBlocked(sourceRow)) continue;
      const patch = byId.get(idStr) || {};
      const endTouched = Object.prototype.hasOwnProperty.call(patch, "EndDate");
      const svcTouched = Object.prototype.hasOwnProperty.call(
        patch,
        "ServiceDate"
      );
      const eff = resolveEff(tid);
      if (!eff) continue;
      const repChild = this._findDirectReplacementForReplacedId(
        sourceRow.LineItemId || sourceRow.Id
      );
      if (
        endTouched &&
        repChild &&
        eff.endYmd &&
        !this._replacementMirrorPeerBlocked(repChild)
      ) {
        const ns = addCalendarDaysYmd(eff.endYmd, 1);
        if (!ns) continue;
        const rid = String(repChild.LineItemId || repChild.Id);
        const pe = { Id: rid, sobjectType: this.sobjectType, ServiceDate: ns };
        ensure(rid, pe);
      }
      const parentLookup = this._replacedParentIdForMirror(sourceRow);
      if (svcTouched && parentLookup && eff.startYmd) {
        const parentRow = this._resolveContractDraftLineForMirror(parentLookup);
        if (!parentRow || this._replacementMirrorPeerBlocked(parentRow))
          continue;
        const ne = addCalendarDaysYmd(eff.startYmd, -1);
        if (!ne) continue;
        const pid = String(parentRow.LineItemId || parentRow.Id);
        ensure(pid, { Id: pid, sobjectType: this.sobjectType, EndDate: ne });
      }
    }
    const origOrder = [];
    const seenO = new Set();
    items.forEach((x) => {
      const k = rowKey(x.Id);
      if (!seenO.has(k)) {
        seenO.add(k);
        origOrder.push(k);
      }
    });
    const added = [...byId.keys()].filter((k) => !seenO.has(k));
    items.length = 0;
    origOrder.forEach((id) => items.push(byId.get(id)));
    added.forEach((id) => items.push(byId.get(id)));
  }

  /**
   * Draft contract: baseline end for "cannot shorten without Terminate" validation.
   * Prefer the activated order line linked by Original_Order_Product__c so users can
   * shorten a draft line back toward the activated row (e.g. draft EndDate 2026-11-26 vs
   * activated 2026-11-24) without a false error. When the activated line has no end
   * (e.g. Monthly), returns null so callers fall back to last persisted draft EndDate.
   */
  _findActiveOrderLineForDraftRow(draftRow) {
    return findActiveOrderLineForDraftRow(draftRow, this.activeProducts, (id) =>
      this._normalizeRowId(id)
    );
  }

  _draftBackwardEndBaselineYmd(originalRecord) {
    if (!this.isContract || !originalRecord) {
      return null;
    }
    const activeLine = this._findActiveOrderLineForDraftRow(originalRecord);
    return activeOrderLineEndDateYmd(activeLine);
  }

  /**
   * Order_Start_Date__c only from getOrderDetails (strict floor for Contract Terms replace sheet validation).
   */
  _orderStartDateYmdFromDetails(details) {
    if (!details) return null;
    return this._normalizeToYyyyMmDd(details.orderStartDateOnly);
  }

  /** Latest of two YYYY-MM-DD strings; null if both sides unset after normalize. */
  _maxYmd(a, b) {
    const na = this._normalizeToYyyyMmDd(a);
    const nb = this._normalizeToYyyyMmDd(b);
    if (!na) return nb || null;
    if (!nb) return na;
    return na >= nb ? na : nb;
  }

  /**
   * Replaced order line: latest normalized start among entry and original-start fields (table row = draft-aware).
   */
  _replacedLineCommercialStartMaxYmd(row) {
    if (!this.isContract || !row) return null;
    const rawList = [
      row.EntryDate,
      row.Entry_Date__c,
      row.ServiceDate,
      row.OriginalStartDate
    ];
    let best = null;
    for (const raw of rawList) {
      const y = this._normalizeToYyyyMmDd(raw);
      if (!y) continue;
      best = best ? (y > best ? y : best) : y;
    }
    return best;
  }

  /**
   * Contract commercial start for replace modals: matches Contract Start Date UX (toolbar, draft, active).
   * Active tab uses saved order effectiveDate, not “today” (differs from entry-clock helper).
   */
  _contractCommercialStartYmdForReplaceModal() {
    if (!this.isContract) return null;
    if (this.activeTab === "active") {
      return this._normalizeToYyyyMmDd(this.activeOrderDetails?.effectiveDate);
    }
    if (
      this.showInMemoryOrderSection &&
      this.inMemoryDraftOrder?.effectiveDate != null
    ) {
      return this._normalizeToYyyyMmDd(this.inMemoryDraftOrder.effectiveDate);
    }
    return (
      this._normalizeToYyyyMmDd(this._toolbarEffectiveDateValue) ||
      this._normalizeToYyyyMmDd(this.draftOrderDetails?.effectiveDate)
    );
  }

  /**
   * Contract: order start for entry-vs-start indicator — Order_Start_Date__c when set (via getOrderDetails.effectiveDate).
   * Active tab = active order; Draft = toolbar override, else saved draft order, else in-memory staged draft.
   */
  _getOrderStartDateForEntryClock() {
    if (!this.isContract) return null;
    if (this.activeTab === "active") {
      // Concluded Terms: compare entry/end signals to today, not Order_Start_Date__c.
      return this._todayYmdUtc();
    }
    if (
      this._toolbarEffectiveDateValue !== undefined &&
      this._toolbarEffectiveDateValue !== ""
    ) {
      return this._toolbarEffectiveDateValue;
    }
    if (this.draftOrderId && this.draftOrderDetails?.effectiveDate != null) {
      return this.draftOrderDetails.effectiveDate;
    }
    if (
      this.showInMemoryOrderSection &&
      this.inMemoryDraftOrder?.effectiveDate != null
    ) {
      return this.inMemoryDraftOrder.effectiveDate;
    }
    return null;
  }

  /** Build replaced-by / replacement-child id sets for draft replacement icon logic. */
  _buildDraftReplacementSets(safe, context) {
    const replacedById = new Set();
    const replacementChildIds = new Set();
    (safe || []).forEach((p) => {
      const replacedId = this._normalizeRowId(p.ReplacedOrderProductId);
      if (replacedId) {
        replacedById.add(replacedId);
      }
    });
    if (context === "contractDraft") {
      (safe || []).forEach((p) => {
        if ((p.ChangeType || "").trim() !== "Removed") {
          return;
        }
        const parentId = this._normalizeRowId(p.LineItemId || p.Id);
        if (!parentId) {
          return;
        }
        const child = this._findDirectReplacementForReplacedId(
          p.LineItemId || p.Id,
          safe
        );
        if (!child) {
          return;
        }
        replacedById.add(parentId);
        const childId = this._normalizeRowId(child.LineItemId || child.Id);
        if (childId) {
          replacementChildIds.add(childId);
        }
      });
    }
    return { replacedById, replacementChildIds };
  }

  /**
   * Recompute replacement moving-in/out icons and replace-button visibility on a normalized row.
   * Called when contract start changes so icons stay in sync with superseded-parent filtering.
   */
  _applyReplacementStatusToRow(
    row,
    allRows,
    context,
    replacedById,
    replacementChildIds,
    isActiveTab
  ) {
    if (!row || context !== "contractDraft") {
      return;
    }
    let changeType = (row.ChangeType || row.ChangeTypeTitle || "").trim();
    const hasOriginal = !!row.OriginalOrderProductId;
    if (!changeType && this.isContract) {
      changeType = hasOriginal ? "No Change" : "New";
    }
    const isNewLine = changeType === "New" || (!hasOriginal && !changeType);
    const normalizeRowIdFn = (id) => this._normalizeRowId(id);
    const replacementStatus = resolveReplacementRowStatus({
      row,
      allRows,
      replacedById,
      replacementChildIds,
      normalizeRowIdFn,
      changeType
    });
    const { showMovingInIcon, blocksReplace, isReplacedLine } =
      replacementStatus;

    let replacementIcon = "";
    let replacementIconUrl = "";
    let replacementIconTitle = "";
    if (showMovingInIcon) {
      replacementIcon = "moving-in";
      replacementIconUrl = this._useEditReplacementIcons(row, allRows)
        ? iconEditPlus
        : iconReplaceMovingIn;
      replacementIconTitle = this._useEditReplacementIcons(row, allRows)
        ? "Replacement product (edit +)"
        : "Moving in (replacement)";
    } else if (isReplacedLine) {
      replacementIcon = "moving-out";
      replacementIconUrl = this._useEditReplacementIcons(row, allRows)
        ? iconEditX
        : iconReplaceMovingOut;
      replacementIconTitle = this._useEditReplacementIcons(row, allRows)
        ? "Replaced product (edit x)"
        : "Moving out (replaced)";
    }

    const changeTypeDot = "";
    const showMonthlyPricingIcon =
      !isActiveTab && this._shouldShowMonthlyPricingIcon(row);
    const statusIconValue = replacementIconUrl || changeTypeDot;
    let statusIconTitle = replacementIconTitle || changeType || "";
    if (showMonthlyPricingIcon) {
      statusIconTitle = statusIconTitle
        ? `${statusIconTitle} · Monthly payment adjusted from original`
        : "Monthly payment adjusted from original";
    }

    const prePersistContractModify = this.isModifyMode && !this.draftOrderId;
    const replaceDisabled =
      this.isContract &&
      (context !== "contractDraft" ||
        prePersistContractModify ||
        isNewLine ||
        blocksReplace ||
        isReplacedLine ||
        this._isReplaceRowEnded(row));

    let replaceDisabledReason = "";
    if (replaceDisabled) {
      if (context !== "contractDraft") {
        replaceDisabledReason = "Replace is available only on the Draft tab.";
      } else if (prePersistContractModify) {
        replaceDisabledReason =
          "Replace is disabled while contract modify mode is active.";
      } else if (isNewLine || blocksReplace) {
        replaceDisabledReason = blocksReplace
          ? "Replacement products cannot be replaced again."
          : "Replace is not available for new lines.";
      } else if (isReplacedLine) {
        replaceDisabledReason = "This line cannot be replaced.";
      } else if (this._isReplaceRowEnded(row)) {
        replaceDisabledReason =
          "Cannot replace a product whose end date is before today.";
      } else {
        replaceDisabledReason = "This row cannot be replaced.";
      }
    }

    row.ReplacementIcon = replacementIcon;
    row.ReplacementIconUrl = replacementIconUrl;
    row.ReplacementIconTitle = replacementIconTitle;
    row.StatusIconValue = statusIconValue;
    row.StatusIconTitle = statusIconTitle;
    row.StatusReplacementHover =
      replacementIcon === "moving-in"
        ? StatusIconReplacementAdded
        : replacementIcon === "moving-out"
          ? StatusIconReplacementRemoved
          : "";
    row.CanReplace = !replaceDisabled;
    row.ReplaceDisabled = replaceDisabled;
    row.ReplaceDisabledReason = replaceDisabledReason;
    row.ReplaceHidden =
      isNewLine ||
      showMovingInIcon ||
      isReplacedLine ||
      (this.isReadOnlyMode && context !== "contractDraft");
    row.ReplaceButtonAltText = replaceDisabledReason || "Replace product";
    row.ReplaceActionHover = replaceDisabledReason || RowActionReplaceProduct;
  }

  _isEntryStrictlyAfterStart(entryRaw, startRaw) {
    const entryIso = this._normalizeToYyyyMmDd(entryRaw);
    const startIso = this._normalizeToYyyyMmDd(startRaw);
    if (!entryIso || !startIso) return false;
    return entryIso > startIso;
  }

  /** Date-only (UTC calendar day) comparison: normalized entry YYYY-MM-DD is strictly after today. */
  _isEntryYmdStrictlyAfterToday(entryYmd) {
    if (!entryYmd) return false;
    const t = new Date();
    const todayYmd = `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
    return entryYmd > todayYmd;
  }

  /** UTC calendar day YYYY-MM-DD (same basis as row ended/today helpers). */
  _todayYmdUtc() {
    const t = new Date();
    return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
  }

  _entryDateClockIconForRow(row, entryOverride) {
    if (!this.isContract) return undefined;
    const entry = entryOverride !== undefined ? entryOverride : row.EntryDate;
    const start = this._getOrderStartDateForEntryClock();
    return this._isEntryStrictlyAfterStart(entry, start)
      ? "utility:clock"
      : undefined;
  }

  /** DraftValues map keyed by normalized line id (unsaved grid edits). */
  _buildDraftValuesMap() {
    const draftMap = new Map();
    (this.draftValues || []).forEach((d) => {
      const id = this._normalizeRowId(d.LineItemId || d.Id);
      if (id) {
        draftMap.set(id, d);
      }
    });
    return draftMap;
  }

  /** Row merged with unsaved EndDate for replace-modal bounds (matches grid display). */
  _rowForReplaceModalDateBounds(row) {
    if (!row) {
      return row;
    }
    return this._mergedEndDateRowForDraft(row, this._buildDraftValuesMap());
  }

  /** Merge unsaved draft EndDate over wire row for display comparisons. */
  _mergedEndDateRowForDraft(prod, draftMap) {
    const id = prod.LineItemId || prod.Id;
    const draft = id ? draftMap.get(id) : null;
    if (draft && Object.prototype.hasOwnProperty.call(draft, "EndDate")) {
      return { ...prod, EndDate: draft.EndDate };
    }
    return prod;
  }

  /**
   * Business order start (YYYY-MM-DD) for “end before start” warning.
   * Contract: same as entry-clock order start. Opportunity: row ParentStartDate.
   */
  _orderStartYmdForEndDateWarning(prod) {
    if (this.isContract) {
      return this._normalizeToYyyyMmDd(this._getOrderStartDateForEntryClock());
    }
    return this._normalizeToYyyyMmDd(prod?.ParentStartDate);
  }

  /**
   * Tooltip / cross alt-text for an end-date that's on or before the comparison baseline.
   * Active contract tab compares to today (see _getOrderStartDateForEntryClock), so wording
   * switches to "...on or before today." there. Draft / Opportunity keep the order-start wording.
   */
  _endDateBeforeStartTooltip(isActiveContractTab) {
    return this.isContract && isActiveContractTab
      ? this.labels.EndDateOnOrBeforeToday
      : this.labels.EndDateBeforeOrderStart;
  }

  /** Prefer Adjusted Total Price when set; else standard TotalPrice. */
  _effectiveLineTotalPrice(p) {
    if (p == null) return 0;
    const adj = p.AdjustedTotalPrice ?? p.Adjusted_Total_Price__c;
    if (adj !== undefined && adj !== null && adj !== "") {
      const n = Number(adj);
      return Number.isFinite(n) ? n : 0;
    }
    return Number(p.TotalPrice) || 0;
  }

  /**
   * Quantity used when deriving UnitPrice from user-entered line total (Product's Price).
   * Prefer draft patch quantity when present and positive; else source row.
   */
  _pbEffectiveQuantityForLinePrice(sourceRow, draftPatch) {
    if (draftPatch != null) {
      const fromDraft = Number(draftPatch.Quantity);
      if (Number.isFinite(fromDraft) && fromDraft > 0) {
        return fromDraft;
      }
    }
    const fromSource = Number(sourceRow?.Quantity);
    if (Number.isFinite(fromSource) && fromSource > 0) {
      return fromSource;
    }
    return null;
  }

  /** UnitPrice = lineTotal / quantity (2 decimal places). Returns null if inputs are invalid. */
  _pbDeriveUnitPriceFromLineTotal(lineTotal, quantity) {
    const qty = quantity == null ? NaN : Number(quantity);
    if (!Number.isFinite(qty) || qty <= 0) {
      return null;
    }
    const total = Number(lineTotal);
    if (!Number.isFinite(total)) {
      return null;
    }
    return Math.round((total / qty) * 100) / 100;
  }

  /** Line total = unitPrice * quantity (2 decimal places). Returns null if inputs are invalid. */
  _pbLineTotalFromUnitAndQty(unitPrice, quantity) {
    const qty = quantity == null ? NaN : Number(quantity);
    if (!Number.isFinite(qty) || qty <= 0) {
      return null;
    }
    const unit = Number(unitPrice);
    if (!Number.isFinite(unit)) {
      return null;
    }
    return Math.round(unit * qty * 100) / 100;
  }

  /**
   * Unit price to keep when the user edits quantity (do not derive from stale line TotalPrice).
   */
  _pbPreservedUnitPriceForQuantityEdit(row, prev, sourceRow) {
    if (Object.prototype.hasOwnProperty.call(row, "UnitPrice")) {
      const fromRow = Number(row.UnitPrice);
      if (Number.isFinite(fromRow)) {
        return fromRow;
      }
    }
    const fromPrev = Number(prev.UnitPrice);
    if (Number.isFinite(fromPrev)) {
      return fromPrev;
    }
    const fromSource = Number(sourceRow?.UnitPrice);
    if (Number.isFinite(fromSource)) {
      return fromSource;
    }
    const srcQty = this._pbEffectiveQuantityForLinePrice(sourceRow, null);
    const lineTotal = this._effectiveLineTotalPrice(sourceRow);
    return this._pbDeriveUnitPriceFromLineTotal(lineTotal, srcQty);
  }

  /** Inclusive month span from product start/end month. Falls back to 1 when missing/invalid. */
  _productMonthSpan(p) {
    if (!p) return 1;
    const startRaw = p.EntryDate ?? p.Entry_Date__c ?? p.ServiceDate;
    const endRaw =
      p.EndDate ?? p.End_date__c ?? p.End_Date__c ?? p.Original_End_Date__c;
    const start = parseDate(startRaw);
    const end = parseDate(endRaw);
    if (!start || !end) return 1;
    const startMonth = new Date(
      Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), 1)
    );
    const endMonth = new Date(
      Date.UTC(end.getUTCFullYear(), end.getUTCMonth(), 1)
    );
    const months = monthDiffInclusive(startMonth, endMonth);
    return months > 0 ? months : 1;
  }

  /** Money icon: only after manual monthly save or desk UnitPrice save (OrderItem.Show_Financial_Adjustment_Icon__c). */
  _shouldShowMonthlyPricingIcon(prod) {
    if (this.isOpportunity) {
      return false;
    }
    const v =
      prod.ShowFinancialAdjustmentIcon ??
      prod.Show_Financial_Adjustment_Icon__c;
    return v === true;
  }

  /**
   * Size the status icon column from the max visible glyphs in `rows` (per datatable section).
   * Width grows with icon count; cell content uses fit-content so empty space after icons is minimized.
   */
  _patchStatusIconColumn(columns, rows) {
    const base = columns || [];
    const width = statusIconColumnWidthPx(maxVisibleStatusIcons(rows));
    return base.map((col) => {
      if (col.fieldName !== "StatusIconValue") {
        return col;
      }
      return {
        ...col,
        initialWidth: width,
        fixedWidth: width
      };
    });
  }

  /**
   * Refresh entry-date date-indicator icons using draft values (same row object identity; shallow-copy arrays for reactivity).
   */
  _refreshEntryDateClockIcons() {
    const draftMap = new Map();
    (this.draftValues || []).forEach((d) => {
      const id = d.LineItemId || d.Id;
      if (id) draftMap.set(id, d);
    });
    const draftReplacementSets =
      this.isContract &&
      Array.isArray(this.draftProducts) &&
      this.draftProducts.length > 0
        ? (() => {
            const safe = this.draftProducts.map((r) =>
              canonicalPackageBuilderProductWireRow(r)
            );
            return {
              safe,
              ...this._buildDraftReplacementSets(safe, "contractDraft")
            };
          })()
        : null;
    const patch = (arr, isActiveOrderLineItems) => {
      if (!Array.isArray(arr) || arr.length === 0) return;
      const maxEndYmdForArr = this._computeMaxEndYmdFromRows(arr, draftMap);
      arr.forEach((row) => {
        if (
          draftReplacementSets &&
          !isActiveOrderLineItems &&
          arr === this.draftProducts
        ) {
          this._applyReplacementStatusToRow(
            row,
            draftReplacementSets.safe,
            "contractDraft",
            draftReplacementSets.replacedById,
            draftReplacementSets.replacementChildIds,
            false
          );
        }
        const id = row.LineItemId || row.Id;
        const draft = id ? draftMap.get(id) : null;
        const draftEntry =
          draft && Object.prototype.hasOwnProperty.call(draft, "EntryDate")
            ? draft.EntryDate
            : undefined;
        row.entryDateClockIcon = this._entryDateClockIconForRow(
          row,
          draftEntry
        );

        const mergedEndRow = this._mergedEndDateRowForDraft(row, draftMap);
        const endYmdForWarn = this._formatRowEndDateYmd(mergedEndRow);
        const orderStartYmdForWarn = this._orderStartYmdForEndDateWarning(row);
        const endBeforeOrderStart = !!(
          endYmdForWarn &&
          orderStartYmdForWarn &&
          endYmdForWarn <= orderStartYmdForWarn
        );
        const endDateDecoration = this._buildEndDateCellDecoration(
          row,
          draftMap,
          (row.RowCssClass || "").trim(),
          endBeforeOrderStart,
          isActiveOrderLineItems
        );
        row.EndDateCellClass = endDateDecoration.cellClass;
        row.EndDateTooltipMessage = endDateDecoration.tooltip;

        if (this.isContract) {
          if (isActiveOrderLineItems) {
            const ended = this._isRowEndedOrToday(row);
            row.ShowEndedCross = ended;
            row.ShowEndedCrossAltText = ended ? "Ended" : "";
          } else {
            const hideContractTermsCross =
              this._hideEndBeforeStartCrossInContractTerms(
                row,
                isActiveOrderLineItems
              );
            row.ShowEndedCross = endBeforeOrderStart && !hideContractTermsCross;
            row.ShowEndedCrossAltText =
              endBeforeOrderStart && !hideContractTermsCross
                ? this._endDateBeforeStartTooltip(false)
                : "";
          }
        } else {
          row.ShowEndedCross = endBeforeOrderStart;
          row.ShowEndedCrossAltText = endBeforeOrderStart
            ? this._endDateBeforeStartTooltip(false)
            : "";
        }

        row.StatusCrossHover = this._statusCrossHoverLabel(
          row,
          row.ShowEndedCross,
          isActiveOrderLineItems
        );

        if (
          !isActiveOrderLineItems &&
          this.isContract &&
          (this.activeTab === "draft" || arr === this.draftProducts)
        ) {
          const allRows = draftReplacementSets?.safe || arr;
          const repId = draftReplacementSets?.replacedById;
          const replacementStatus = resolveReplacementRowStatus({
            row,
            allRows,
            replacedById: repId,
            replacementChildIds: draftReplacementSets?.replacementChildIds,
            normalizeRowIdFn: (rowId) => this._normalizeRowId(rowId),
            changeType: (row.ChangeType || "").trim()
          });
          this._applyRowEditabilityFlags(
            row,
            "contractDraft",
            allRows,
            repId,
            replacementStatus.isReplacedLine
          );
        }

        this._applyClientStatusIconsToRow(
          row,
          draftMap,
          maxEndYmdForArr,
          isActiveOrderLineItems
        );
      });
    };
    if (!this.isContract) {
      patch(this.productsData, false);
      this.productsData = [...(this.productsData || [])];
    } else {
      patch(this.activeProducts, true);
      patch(this.draftProducts, false);
      this.activeProducts = [...(this.activeProducts || [])];
      this.draftProducts = [...(this.draftProducts || [])];
    }
  }

  /**
   * Max YYYY-MM-DD end date across rows (merged draft EndDate); ignores open-ended lines.
   * Contract Terms (Contract Terms) lines are excluded: their ends are not comparable to
   * Rooms / Extra (parking) for the “line end before order max” status icon.
   */
  _computeMaxEndYmdFromRows(rows, draftMap) {
    let max = null;
    const dm = draftMap || new Map();
    for (const p of rows || []) {
      if (this._isContractTermsRow(p)) {
        continue;
      }
      const merged = this._mergedEndDateRowForDraft(p, dm);
      const ymd = this._formatRowEndDateYmd(merged);
      if (ymd && (!max || ymd > max)) max = ymd;
    }
    return max;
  }

  /** Hover for ended / end-before-order-start cross (same `c-ers-tooltip` pattern as Terminate Products). */
  _statusCrossHoverLabel(prod, showEndedCross, isActiveTab) {
    if (!showEndedCross) return "";
    if (isActiveTab && this._isRowEndedOrToday(prod)) {
      return StatusIconProductEnded;
    }
    return StatusIconCrossOrderStart;
  }

  /**
   * Client SVGs in the status column (cross, future +/x, money, new +); replacement URLs stay on StatusIconValue.
   * @param {boolean} isContractActiveContext true for Concluded Terms line items (same as normalize `isActiveTab` for contractActive).
   * Future-plus (entry) icon: Draft = entry after order start; Active = entry after today (not contract / order effective date).
   */
  _applyClientStatusIconsToRow(
    row,
    draftMap,
    maxEndYmd,
    isContractActiveContext
  ) {
    const id = row.LineItemId || row.Id;
    const draft = id ? (draftMap || new Map()).get(id) : null;
    const draftEntry =
      draft && Object.prototype.hasOwnProperty.call(draft, "EntryDate")
        ? draft.EntryDate
        : undefined;

    const endedCrossFromRow = snapshotShowEndedCrossForStatusIcons(row);
    if (shouldSuppressStatusEndedCrossForMovingOut(row)) {
      row.ShowEndedCross = false;
      row.ShowEndedCrossAltText = "";
      row.StatusCrossHover = "";
    }

    row.StatusCrossIconUrl = row.ShowEndedCross ? iconOrderStartWarning : null;

    const entryRawForFutureStart =
      draftEntry !== undefined
        ? draftEntry
        : (row?.EntryDate ?? row?.ServiceDate ?? row?.Entry_Date__c ?? null);
    const showFuturePlusEntryIcon =
      this.isContract && isContractActiveContext
        ? this._isEntryYmdStrictlyAfterToday(
            this._normalizeToYyyyMmDd(entryRawForFutureStart)
          )
        : !!this._entryDateClockIconForRow(row, draftEntry);

    if (showFuturePlusEntryIcon) {
      row.StatusEntryAfterStartUrl = iconFuturePlus;
      row.TooltipFuturePlusEntry =
        this.isContract && isContractActiveContext
          ? StatusIconFuturePlusEntryActive
          : StatusIconFuturePlusEntry;
      row.entryDateClockIcon = undefined;
    } else {
      row.StatusEntryAfterStartUrl = null;
      row.TooltipFuturePlusEntry = "";
      row.entryDateClockIcon = undefined;
    }

    const mergedEnd = this._mergedEndDateRowForDraft(
      row,
      draftMap || new Map()
    );
    const endYmd = this._formatRowEndDateYmd(mergedEnd);
    const excludeFutureEndBeforeMaxForContractTerms =
      this._isContractTermsRow(row);
    row.StatusFutureEndBeforeMaxUrl =
      !shouldSuppressFutureEndBeforeMaxForReplacement(row?.ReplacementIcon) &&
      !excludeFutureEndBeforeMaxForContractTerms &&
      !endedCrossFromRow &&
      maxEndYmd &&
      endYmd &&
      endYmd < maxEndYmd
        ? iconFutureEndBeforeMax
        : null;

    row.StatusMonthlyMoneyIconUrl = row.ShowMonthlyPricingIcon
      ? iconMoney
      : null;

    const isEffectiveNew = this._isEffectiveNewProductRow(row);
    row.StatusNewProductIconUrl = shouldShowStatusNewProductPlusIcon({
      isContractActiveContext,
      isEffectiveNew,
      replacementIcon: row.ReplacementIcon,
      replacedOrderProductId:
        row.ReplacedOrderProductId ||
        replacedOrderProductIdFromRow(row) ||
        inferReplacedOrderProductIdForRow(
          row,
          this.draftProducts || this.activeProducts || []
        )
    })
      ? iconNewPlus
      : null;
  }

  /** "New" row logic shared with status icon behavior: explicit New OR inferred New when no original product link exists. */
  _isEffectiveNewProductRow(row) {
    const changeType = (row?.ChangeType || row?.ChangeTypeTitle || "").trim();
    const inferredNewWithoutOriginal =
      !changeType && !row?.OriginalOrderProductId;
    return changeType === "New" || inferredNewWithoutOriginal;
  }

  // ─── NORMALIZATION (UI-ONLY FIELDS) ──────────────────────

  normalizeProducts(data, context) {
    const safe = Array.isArray(data)
      ? data.map((r) => canonicalPackageBuilderProductWireRow(r))
      : [];
    const isActiveTab = context === "contractActive";
    const { replacedById, replacementChildIds } =
      this._buildDraftReplacementSets(safe, context);
    let debugCount = 0;
    const debugEnabled = this._pbDebugEnabled();

    const firstDefinedDate = (...candidates) => {
      for (const v of candidates) {
        if (v !== undefined && v !== null && v !== "") return v;
      }
      return null;
    };

    const draftMap = new Map();
    (this.draftValues || []).forEach((d) => {
      const id = d.LineItemId || d.Id;
      if (id) draftMap.set(id, d);
    });
    const maxEndYmdForGrid = this._computeMaxEndYmdFromRows(safe, draftMap);

    const rows = safe.map((rawProd) => {
      const prod = this._reconcileDraftRowEndAfterClearedTermination(rawProd);
      let changeType = (prod.ChangeType || "").trim(); // OrderItem only
      const hasOriginal = !!prod.OriginalOrderProductId;
      // Infer change type when missing (e.g. Active order or legacy data) so dot still gets a color
      if (
        !changeType &&
        this.isContract &&
        (context === "contractDraft" || context === "contractActive")
      ) {
        changeType = hasOriginal ? "No Change" : "New";
      }
      const isNewLine = changeType === "New" || (!hasOriginal && !changeType);
      const normalizeRowIdFn = (id) => this._normalizeRowId(id);
      const replacementStatus = resolveReplacementRowStatus({
        row: prod,
        allRows: safe,
        replacedById,
        replacementChildIds,
        normalizeRowIdFn,
        changeType
      });
      const { isMovingInRow, showMovingInIcon, blocksReplace, isReplacedLine } =
        replacementStatus;
      const canDeleteBecauseFutureStart =
        this.isContract &&
        context === "contractDraft" &&
        this._isRowStartAfterToday(prod);
      // Replace/delete only blocked before a DB draft exists — not after draftOrderId is set (avoids stale isModifyMode / wire races).
      const prePersistContractModify = this.isModifyMode && !this.draftOrderId;
      const extraMeterHideDelete =
        context === "contractDraft" &&
        this._isContractTermsRow(prod) &&
        !isMovingInRow;
      const deleteDisabled =
        this.isContract &&
        (extraMeterHideDelete ||
          context !== "contractDraft" ||
          prePersistContractModify ||
          isReplacedLine ||
          (!isNewLine && !canDeleteBecauseFutureStart));
      const replaceDisabled =
        this.isContract &&
        (context !== "contractDraft" ||
          prePersistContractModify ||
          isNewLine ||
          blocksReplace ||
          isReplacedLine ||
          this._isReplaceRowEnded(prod));
      let deleteDisabledReason = "";
      if (deleteDisabled) {
        if (extraMeterHideDelete) {
          deleteDisabledReason =
            "Contract Terms lines cannot be deleted here; delete only applies to replacement products.";
        } else if (context !== "contractDraft") {
          deleteDisabledReason = "Delete is available only on the Draft tab.";
        } else if (prePersistContractModify) {
          deleteDisabledReason =
            "Delete is disabled while contract modify mode is active.";
        } else if (isReplacedLine) {
          deleteDisabledReason = "Replaced products cannot be deleted.";
        } else if (!isNewLine && !canDeleteBecauseFutureStart) {
          deleteDisabledReason =
            "Only newly added or future-start products can be deleted.";
        } else {
          deleteDisabledReason = "This row cannot be deleted.";
        }
      }
      let replaceDisabledReason = "";
      if (replaceDisabled) {
        if (context !== "contractDraft") {
          replaceDisabledReason = "Replace is available only on the Draft tab.";
        } else if (prePersistContractModify) {
          replaceDisabledReason =
            "Replace is disabled while contract modify mode is active.";
        } else if (isNewLine || blocksReplace) {
          replaceDisabledReason = blocksReplace
            ? "Replacement products cannot be replaced again."
            : "Replace is not available for new lines.";
        } else if (isReplacedLine) {
          replaceDisabledReason = "This line cannot be replaced.";
        } else if (this._isReplaceRowEnded(prod)) {
          replaceDisabledReason =
            "Cannot replace a product whose end date is before today.";
        } else {
          replaceDisabledReason = "This row cannot be replaced.";
        }
      }

      const baseRowClass = prod.Temporary === true ? "pb-temp-row" : "";
      let rowClass = baseRowClass;
      if (isActiveTab && this._isRowEndedOrToday(prod)) {
        rowClass = rowClass
          ? `${rowClass} pb-concluded-ended`
          : "pb-concluded-ended";
      }

      const mergedEndRow = this._mergedEndDateRowForDraft(prod, draftMap);
      const endYmdForWarn = this._formatRowEndDateYmd(mergedEndRow);
      const orderStartYmdForWarn = this._orderStartYmdForEndDateWarning(prod);
      const endBeforeOrderStart = !!(
        endYmdForWarn &&
        orderStartYmdForWarn &&
        endYmdForWarn <= orderStartYmdForWarn
      );
      const endDateDecoration = this._buildEndDateCellDecoration(
        prod,
        draftMap,
        rowClass,
        endBeforeOrderStart,
        isActiveTab
      );
      let endDateCellClass = endDateDecoration.cellClass;

      const entryDateEditable = this._canEditEntryDateCell(prod, safe, context);
      const endDateEditable = this._canEditEndDateCell(
        prod,
        safe,
        replacedById,
        context
      );

      // Change type icon: only on Draft tab. New = client SVG; Modified = no icon (product request); No Change = no icon.
      // Status column: omit pb-concluded-ended so strike line / decoration does not cover the icon column.
      let changeTypeDot = "";
      let changeTypeCellClass = isActiveTab ? baseRowClass : rowClass;
      if (!isActiveTab && changeType) {
        // New: client SVG via StatusNewProductIconUrl (no emoji placeholder).
        changeTypeDot = changeType === "New" ? "" : "";
      }

      // Replacement icon: URL for custom datatable column (image inside table)
      let replacementIcon = "";
      let replacementIconUrl = "";
      let replacementIconTitle = "";
      if (showMovingInIcon) {
        replacementIcon = "moving-in";
        replacementIconUrl = this._useEditReplacementIcons(prod, safe)
          ? iconEditPlus
          : iconReplaceMovingIn;
        replacementIconTitle = this._useEditReplacementIcons(prod, safe)
          ? "Replacement product (edit +)"
          : "Moving in (replacement)";
      } else if (isReplacedLine) {
        replacementIcon = "moving-out";
        replacementIconUrl = this._useEditReplacementIcons(prod, safe)
          ? iconEditX
          : iconReplaceMovingOut;
        replacementIconTitle = this._useEditReplacementIcons(prod, safe)
          ? "Replaced product (edit x)"
          : "Moving out (replaced)";
      }

      // Monthly-pricing glyph should appear only on Draft tab, not Active.
      const showMonthlyPricingIcon =
        !isActiveTab && this._shouldShowMonthlyPricingIcon(prod);
      // Single status column: moving icon takes precedence, else change-type emoji
      const statusIconValue = replacementIconUrl || changeTypeDot;
      let statusIconTitle = replacementIconTitle || changeType || "";
      if (showMonthlyPricingIcon) {
        statusIconTitle = statusIconTitle
          ? `${statusIconTitle} · Monthly payment adjusted from original`
          : "Monthly payment adjusted from original";
      }

      // Active order lines: cross when end date is on/before today. Draft / opportunity: cross when end is on/before order start (Active contract uses today as baseline via _getOrderStartDateForEntryClock).
      const hideContractTermsCross =
        this._hideEndBeforeStartCrossInContractTerms(prod, isActiveTab);
      const showEndedCross =
        (isActiveTab && this._isRowEndedOrToday(prod)) ||
        (!isActiveTab && endBeforeOrderStart && !hideContractTermsCross);
      const showEndedCrossAltText =
        !isActiveTab && endBeforeOrderStart
          ? this._endDateBeforeStartTooltip(false)
          : isActiveTab && this._isRowEndedOrToday(prod)
            ? "Ended"
            : "";
      if (debugEnabled && debugCount < 5) {
        debugCount += 1;

        console.debug("[packageBuilder] rowDebug", {
          context,
          isOpportunity: this.isOpportunity,
          isContract: this.isContract,
          activeTab: this.activeTab,
          id: prod.LineItemId || prod.Id,
          endCandidates: {
            EndDate: prod.EndDate,
            End_date__c: prod.End_date__c,
            End_Date__c: prod.End_Date__c,
            EndDate__c: prod.EndDate__c
          },
          endYmd: this._formatRowEndDateYmd(prod),
          showEndedCross
        });
      } else if (showEndedCross) {
        console.debug("[packageBuilder] endedCross", {
          id: prod.LineItemId || prod.Id,
          endYmd: this._formatRowEndDateYmd(prod),
          context
        });
      }

      const statusCrossHover = this._statusCrossHoverLabel(
        prod,
        showEndedCross,
        isActiveTab
      );
      const statusReplacementHover =
        replacementIcon === "moving-in"
          ? StatusIconReplacementAdded
          : replacementIcon === "moving-out"
            ? StatusIconReplacementRemoved
            : "";

      const rowOut = {
        ...prod,
        CpiDate: firstDefinedDate(
          prod.CpiDateIso,
          prod.cpiDateIso,
          prod.CpiDate,
          prod.cpiDate,
          prod.CPI_Date__c,
          prod.cPI_Date__c
        ),
        AvailabilityIcon: this.getProductAvailabilityIcon(prod.Availability),

        RowCssClass: rowClass,
        /** Replace/delete column: no concluded strikethrough class (avoids line through controls). */
        /** Includes `pb-dual-action-td` so datatable injected CSS can vertically center replace/delete in the cell. */
        RowCssClassForActions: [baseRowClass, "pb-dual-action-td"]
          .filter(Boolean)
          .join(" ")
          .trim(),
        // Dividers: keep header-only styling; rows should not show vertical dividers.
        EndDateCellClass: endDateCellClass,
        TemporaryCellClass: baseRowClass || "",
        EndDateTooltipMessage: endDateDecoration.tooltip,
        IsExistingDraftProduct: this._isExistingDraftProductRow(prod),
        IsNewOrReplacementDraftProduct:
          this._isNewOrReplacementDraftProductRow(prod),
        EntryDateEditable: entryDateEditable,
        EndDateEditable: endDateEditable,
        TemporaryEditable: this._canEditTemporaryCell(
          prod,
          !this.isReadOnlyMode,
          isReplacedLine
        ),
        EarlyExitRequestEditable: this._canEditEarlyExitRequestCell(
          prod,
          true,
          isReplacedLine
        ),
        ContractTermEndDateEditable: this._canEditContractTermEndDateCell(
          prod,
          replacedById,
          context
        ),
        /** Inline picklist editability for the Termination Reason column (Draft tab only). */
        TerminationReasonEditable: false,
        AccessTypePicklistMap: accessTypePicklistMapForRow(prod, false),
        AccessTypeEditable: false,
        AccessTypePastStartSplit: false,
        ChangedAccessType: prod.ChangedAccessType === true,
        QuantityEditable: false,
        QuantityPastStartSplit: false,
        UnitPriceEditable: false,
        UnitPricePastStartSplit: false,
        TotalPriceEditable: false,
        TotalPricePastStartSplit: false,

        // Divider columns should not render a glyph in rows (header debugging only).
        DividerAfterStartDate: "",
        DividerAfterEndDate: "",

        ChangeTypeDot: changeTypeDot,
        ChangeTypeTitle: changeType,
        ChangeTypeCellClass: changeTypeCellClass.trim(),

        ReplacementIcon: replacementIcon,
        ReplacementIconUrl: replacementIconUrl,
        ReplacementIconTitle: replacementIconTitle,

        StatusIconValue: statusIconValue,
        StatusIconTitle: statusIconTitle,
        ShowEndedCross: showEndedCross,
        ShowEndedCrossAltText: showEndedCrossAltText,
        ShowMonthlyPricingIcon: showMonthlyPricingIcon,
        ShowPriceProjectionInfo:
          prod.ShowPriceProjectionInfo === true &&
          !this._isContractTermsRow(prod),
        PriceProjectionInfoTooltip:
          prod.ShowPriceProjectionInfo === true &&
          !this._isContractTermsRow(prod) &&
          typeof prod.PriceProjectionInfoTooltip === "string"
            ? prod.PriceProjectionInfoTooltip
            : "",
        StatusCrossHover: statusCrossHover,
        StatusReplacementHover: statusReplacementHover,

        CanDelete: !deleteDisabled,
        DeleteDisabled: deleteDisabled,
        DeleteHidden: deleteDisabled,
        DeleteDisabledReason: deleteDisabledReason,
        DeleteButtonAltText: deleteDisabledReason || "Delete product",
        DeleteActionHover: deleteDisabledReason || RowActionDeleteProduct,
        CanReplace: !replaceDisabled,
        ReplaceDisabled: replaceDisabled,
        ReplaceDisabledReason: replaceDisabledReason,
        // Keep replace visibility tied to the row context, not the tab state at normalize time.
        // Draft rows can be normalized while active tab is still visible during draft creation.
        ReplaceHidden:
          isNewLine ||
          showMovingInIcon ||
          isReplacedLine ||
          (this.isReadOnlyMode && context !== "contractDraft"),
        ReplaceButtonAltText: replaceDisabledReason || "Replace product",
        ReplaceActionHover: replaceDisabledReason || RowActionReplaceProduct,

        /** Per-row URLs so lightning-datatable passes icon src into nested custom cells (literals are dropped). */
        PbReplaceActionIconUrl: this._isContractTermsRow(prod)
          ? iconEditButton
          : iconReplaceButton,
        PbDeleteActionIconUrl: iconTrash
      };
      this._applyRowEditabilityFlags(
        rowOut,
        context,
        safe,
        replacedById,
        isReplacedLine
      );
      this._applyClientStatusIconsToRow(
        rowOut,
        draftMap,
        maxEndYmdForGrid,
        isActiveTab
      );
      rowOut.IterationsDisplay = formatIterationsDisplay(
        rowOut.RemainingIterations ?? rowOut.remainingIterations,
        rowOut.ConfiguredIterations ?? rowOut.configuredIterations
      );
      return rowOut;
    });
    // One layout per normalize batch so single-icon rows do not center while multi-icon rows use grid.
    const maxStatusIcons = maxVisibleStatusIcons(rows);
    const statusLayoutMode = maxStatusIcons <= 1 ? "compact" : "grid";
    rows.forEach((row) => {
      row.StatusLayoutMode = statusLayoutMode;
    });
    return rows;
  }

  _refreshApexSafe(wireResult) {
    if (!wireResult) {
      return Promise.resolve();
    }
    return refreshApex(wireResult).catch((e) => {
      console.warn(
        "[packageBuilder] refreshApex skipped due to unavailable wire result",
        e
      );
    });
  }

  /** Refresh monthly-payment rollup wires (payable + one-minus-discount maps) for Package Builder KPIs. */
  _refreshMonthlyPaymentKpiWires() {
    if (this.isContract) {
      return Promise.all([
        this._refreshApexSafe(this.wiredActiveMpPayableSumsResult),
        this._refreshApexSafe(this.wiredDraftMpPayableSumsResult),
        this._refreshApexSafe(this.wiredActiveMpOneMinusSumsResult),
        this._refreshApexSafe(this.wiredDraftMpOneMinusSumsResult)
      ]);
    }
    return Promise.all([
      this._refreshApexSafe(this.wiredOppMpPayableSumsResult),
      this._refreshApexSafe(this.wiredOppMpOneMinusSumsResult)
    ]);
  }

  _sleep(ms) {
    return new Promise((resolve) => {
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- polling delay helper
      setTimeout(resolve, ms);
    });
  }

  async _refreshDraftHydrationBundle() {
    await Promise.all([
      this._refreshApexSafe(this.wiredDraftLineItemsResult),
      this._refreshApexSafe(this.wiredDraftSummaryResult),
      this._refreshApexSafe(this.wiredDraftOrderDetailsResult),
      this._refreshApexSafe(this.wiredDraftMpPayableSumsResult),
      this._refreshApexSafe(this.wiredDraftMpOneMinusSumsResult)
    ]);
  }

  async _startDraftHydrationPolling(
    maxAttempts = 10,
    delayMs = 700,
    roundsRemaining = 4
  ) {
    if (!this.isContract || !this.draftOrderId) {
      return;
    }
    this.isDraftHydrating = true;
    const token = ++this._draftHydrationPollToken;
    for (let i = 0; i < maxAttempts; i++) {
      if (token !== this._draftHydrationPollToken) {
        return;
      }
      if (!this.draftOrderId) {
        this.isDraftHydrating = false;
        return;
      }
      if ((this.draftProducts?.length || 0) > 0) {
        this.isDraftHydrating = false;
        return;
      }
      // eslint-disable-next-line no-await-in-loop -- intentional draft hydration polling
      await this._refreshDraftHydrationBundle();
      if ((this.draftProducts?.length || 0) > 0) {
        this.isDraftHydrating = false;
        return;
      }
      // eslint-disable-next-line no-await-in-loop -- intentional draft hydration polling
      await this._sleep(delayMs);
    }
    if (
      token === this._draftHydrationPollToken &&
      roundsRemaining > 0 &&
      this.isDraftTab &&
      this.draftOrderId &&
      (this.draftProducts?.length || 0) === 0
    ) {
      await this._sleep(900);
      await this._startDraftHydrationPolling(
        Math.max(4, maxAttempts - 2),
        Math.min(1500, delayMs + 150),
        roundsRemaining - 1
      );
      return;
    }
    this.isDraftHydrating = false;
  }

  async _waitForActiveOrderSwitch(
    previousActiveOrderId,
    activatedOrderId = null
  ) {
    if (!this.isContract) {
      return;
    }
    const maxAttempts = 12;
    const delayMs = 250;
    for (let i = 0; i < maxAttempts; i++) {
      if (activatedOrderId && this.activeOrderId === activatedOrderId) {
        return;
      }
      if (
        previousActiveOrderId &&
        this.activeOrderId &&
        this.activeOrderId !== previousActiveOrderId
      ) {
        return;
      }
      if (!previousActiveOrderId && this.activeOrderId) {
        return;
      }
      // eslint-disable-next-line no-await-in-loop -- wait for active order switch after activation
      await this._refreshApexSafe(this.wiredOrdersResult);
      // eslint-disable-next-line no-await-in-loop -- wait for active order switch after activation
      await this._sleep(delayMs);
    }
  }

  @api
  async refreshProductsTable() {
    if (this.isContract) {
      await Promise.all([
        this._refreshApexSafe(this.wiredOrdersResult),
        this._refreshApexSafe(this.wiredContractDatesResult),
        this._refreshApexSafe(this.wiredActiveLineItemsResult),
        this._refreshApexSafe(this.wiredDraftLineItemsResult),
        this._refreshApexSafe(this.wiredActiveSummaryResult),
        this._refreshApexSafe(this.wiredDraftSummaryResult),
        this._refreshApexSafe(this.wiredDraftOrderDetailsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
    } else {
      await Promise.all([
        this._refreshApexSafe(this.wiredLineItemsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
    }
  }

  updateContainerButtons() {
    // Modify: shown on Active tab or when single-view (no draft); disabled when a real draft already exists
    const showModify =
      this.isContract &&
      (this.activeTab === "active" || this.showModifyContractOnly);
    const modifyDisabled =
      !!this.draftOrderId ||
      this._isModifyContractDisabledForTerminatedActivatedPlan();
    // Activate is now driven by the status Path on Draft tab.
    const showActivate = false;
    const activateDisabled = false;
    const modifyButtonLabel = this.isContract ? "Modify Contract" : "Modify";
    // Cancel draft is now shown next to the Draft tab (not in container header actions).
    const showCancelDraft = false;
    const cancellingDraft = this.cancellingDraft;
    this.dispatchEvent(
      new CustomEvent("updatevisibility", {
        detail: {
          showModify,
          showActivate,
          modifyDisabled,
          activateDisabled,
          modifyButtonLabel,
          showCancelDraft,
          cancellingDraft
        },
        bubbles: true,
        composed: true
      })
    );
    try {
      const container = this.template.host?.closest(
        "c-package-builder-container"
      );
      if (container && container.updateButtonVisibility) {
        container.updateButtonVisibility(
          showModify,
          showActivate,
          modifyDisabled,
          activateDisabled,
          modifyButtonLabel,
          false,
          showCancelDraft,
          cancellingDraft
        );
      }
    } catch {
      /* cross-shadow boundary */
    }
  }

  // ─── STATUS PATH (Draft → Negotiation → Signed; order status remains Activated) ──────────────────

  get showStatusPath() {
    return this.isContract && this.isDraftTab && !!this.draftOrderId;
  }

  get currentDraftStatus() {
    return (this.draftOrderDetails?.status || "Draft").trim();
  }

  _statusRank(status) {
    const s = (status || "").trim();
    if (s === "Draft") return 1;
    if (s === "Negotiation") return 2;
    if (s === "Activated") return 3;
    return 0;
  }

  _pathClassFor(targetStatus) {
    const base = "status-path__step";
    const currentRank = this._statusRank(this.currentDraftStatus);
    const targetRank = this._statusRank(targetStatus);
    if (targetRank === 0) return base;
    if (currentRank === targetRank) return `${base} status-path__step--current`;
    if (currentRank > targetRank) return `${base} status-path__step--complete`;
    return base;
  }

  get draftPathClass() {
    return this._pathClassFor("Draft");
  }
  get negotiationPathClass() {
    return this._pathClassFor("Negotiation");
  }
  get activatedPathClass() {
    const base = this._pathClassFor("Activated");
    return this.activatePathDisabled
      ? `${base} status-path__step--disabled`
      : base;
  }

  get activatePathDisabled() {
    return !this.canActivateDraft;
  }

  /** User-visible reason the Activated step is blocked (for toast / title). */
  get activatePathBlockedMessage() {
    if (!this.isContract || !this.draftOrderId) {
      return "";
    }
    const v = this.validateDraftForActivation();
    return v.valid
      ? ""
      : v.message ||
          "Complete all required fields and fix dates before signing.";
  }

  get activatedPathTitle() {
    if (this.isActivatingDraft) {
      return "Signing…";
    }
    return this.activatePathDisabled
      ? this.activatePathBlockedMessage
      : "Sign draft order";
  }

  _activationErrorMessage(error) {
    if (!error) return "Failed to activate draft.";
    if (error.body?.message)
      return this._normalizeStartDateUserMessage(error.body.message);
    if (typeof error.body === "string")
      return this._normalizeStartDateUserMessage(error.body);
    if (error.message)
      return this._normalizeStartDateUserMessage(error.message);
    if (Array.isArray(error.body) && error.body[0]?.message) {
      return this._normalizeStartDateUserMessage(error.body[0].message);
    }
    return "Failed to activate draft.";
  }

  async handleStatusPathClick(event) {
    const status = event?.currentTarget?.dataset?.status;
    if (!status || !this.draftOrderId) return;
    if (this.isActivatingDraft) return;

    if (status === "Activated") {
      if (this.activatePathDisabled) {
        this.showToast("Cannot sign", this.activatePathBlockedMessage, "error");
        return;
      }
      try {
        await this.handleActivateDraftFromContainer();
      } catch (e) {
        console.error("handleStatusPathClick Activated:", e);
        this.showToast("Error", this._activationErrorMessage(e), "error");
      }
      return;
    }

    try {
      await setOrderStatus({ orderId: this.draftOrderId, newStatus: status });
      await Promise.all([
        refreshApex(this.wiredOrdersResult),
        refreshApex(this.wiredDraftOrderDetailsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
      this.showToast("Success", `Order status updated to ${status}`, "success");
    } catch (error) {
      this.showToast(
        "Error",
        this._reduceServerError(error) || "Failed to update order status",
        "error"
      );
    }
  }

  // ─── COLUMN SETUP ─────────────────────────────────────────

  setColumns() {
    const isEditable = !this.isReadOnlyMode;
    // Align UX across Opportunity record types: same table/columns and behaviors.
    this.setStandardColumns(isEditable);
  }

  setStandardColumns(isEditable) {
    const entryDateCol = {
      label: EntryDateLabel,
      type: "dateInput",
      fieldName: "EntryDate",
      editable: { fieldName: "EntryDateEditable" },
      typeAttributes: {
        editable: { fieldName: "EntryDateEditable" },
        fieldName: "EntryDate",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" }
      },
      initialWidth: 118,
      wrapText: true
    };
    const endDateCol = {
      label: this.labels.EndDate,
      type: "dateInput",
      fieldName: "EndDate",
      editable: { fieldName: "EndDateEditable" },
      typeAttributes: {
        editable: { fieldName: "EndDateEditable" },
        fieldName: "EndDate",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" },
        tooltipMessage: { fieldName: "EndDateTooltipMessage" }
      },
      initialWidth: 118,
      wrapText: true,
      cellAttributes: { class: { fieldName: "EndDateCellClass" } }
    };
    const cpiDateCol = {
      label: this.labels.CpiDate,
      type: "dateInput",
      fieldName: "CpiDate",
      editable: false,
      typeAttributes: {
        editable: isEditable,
        fieldName: "CpiDate",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" },
        hideEmptyDash: true
      },
      initialWidth: 110,
      wrapText: true
    };
    const statusIconCol = {
      label: "",
      fieldName: "StatusIconValue",
      type: "replacementIcon",
      hideDefaultActions: true,
      typeAttributes: {
        showCross: { fieldName: "ShowEndedCross" },
        showCrossAltText: { fieldName: "ShowEndedCrossAltText" },
        showMonthlyPricingIcon: { fieldName: "ShowMonthlyPricingIcon" },
        entryClockIcon: { fieldName: "entryDateClockIcon" },
        layoutMode: { fieldName: "StatusLayoutMode" },
        statusCrossIconUrl: { fieldName: "StatusCrossIconUrl" },
        statusEntryAfterStartUrl: { fieldName: "StatusEntryAfterStartUrl" },
        statusFutureEndBeforeMaxUrl: {
          fieldName: "StatusFutureEndBeforeMaxUrl"
        },
        statusMonthlyMoneyIconUrl: { fieldName: "StatusMonthlyMoneyIconUrl" },
        statusNewProductIconUrl: { fieldName: "StatusNewProductIconUrl" },
        tooltipCross: { fieldName: "StatusCrossHover" },
        tooltipReplacement: { fieldName: "StatusReplacementHover" },
        tooltipNewProduct: StatusIconNewProduct,
        tooltipFuturePlusEntry: { fieldName: "TooltipFuturePlusEntry" },
        tooltipFutureXOtherProducts: StatusIconFutureXOtherProducts,
        tooltipMoneyFinancial: StatusIconMoneyFinancial,
        tooltipModified: StatusIconModified
      },
      initialWidth: 104,
      sortable: false,
      cellAttributes: {
        alignment: "left",
        class: { fieldName: "ChangeTypeCellClass" },
        title: { fieldName: "StatusIconTitle" }
      }
    };
    const nameCol = {
      label: this.labels.PackageBuilderTblName,
      fieldName: "Name",
      initialWidth: 150
    };
    const useContractPencilCols =
      this.isContract && this.activeTab === "draft" && isEditable;

    const accessTypeCol = {
      label: this.labels.AccessType,
      fieldName: "AccessType",
      type: "combobox",
      editable: { fieldName: "AccessTypeEditable" },
      initialWidth: 140,
      wrapText: true,
      typeAttributes: {
        editable: { fieldName: "AccessTypeEditable" },
        fieldName: "AccessType",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" },
        picklistValues: { fieldName: "AccessTypePicklistMap" },
        alignment: "slds-text-align_left",
        pastStartSplit: { fieldName: "AccessTypePastStartSplit" }
      }
    };
    const unitPriceCol = useContractPencilCols
      ? {
          label: DeskUnitPrice,
          fieldName: "UnitPrice",
          type: "pencilEditable",
          editable: { fieldName: "UnitPriceEditable" },
          initialWidth: 150,
          wrapText: true,
          typeAttributes: {
            editable: { fieldName: "UnitPriceEditable" },
            fieldName: "UnitPrice",
            keyField: "LineItemId",
            keyFieldValue: { fieldName: "LineItemId" },
            inputType: "currency",
            step: "any",
            pastStartSplit: { fieldName: "UnitPricePastStartSplit" },
            alignment: "slds-text-align_left"
          }
        }
      : {
          label: DeskUnitPrice,
          type: "currency",
          cellAttributes: { alignment: "left" },
          typeAttributes: { maximumFractionDigits: 2 },
          fieldName: "UnitPrice",
          editable: { fieldName: "UnitPriceEditable" },
          initialWidth: 150,
          wrapText: true
        };
    // Always use pencilEditable on Contract so Product's Price can host the MP info icon
    // (Active/read-only still renders value + icon; pencil only when editable).
    const totalPriceCol = this.isContract
      ? {
          label: PRODUCT_PRICE_LABEL,
          fieldName: "TotalPrice",
          type: "pencilEditable",
          editable: { fieldName: "TotalPriceEditable" },
          initialWidth: 168,
          wrapText: true,
          typeAttributes: {
            editable: { fieldName: "TotalPriceEditable" },
            fieldName: "TotalPrice",
            keyField: "LineItemId",
            keyFieldValue: { fieldName: "LineItemId" },
            inputType: "currency",
            step: "any",
            pastStartSplit: { fieldName: "TotalPricePastStartSplit" },
            alignment: "slds-text-align_left",
            showPriceProjectionInfo: {
              fieldName: "ShowPriceProjectionInfo"
            },
            tooltipPriceProjection: {
              fieldName: "PriceProjectionInfoTooltip"
            }
          }
        }
      : {
          label: PRODUCT_PRICE_LABEL,
          type: "currency",
          cellAttributes: { alignment: "left" },
          typeAttributes: { maximumFractionDigits: 2 },
          fieldName: "TotalPrice",
          editable: { fieldName: "TotalPriceEditable" },
          initialWidth: 138,
          wrapText: true
        };
    const quantityCol = {
      label: this.labels.Quantity,
      type: "number",
      cellAttributes: { alignment: "left" },
      fieldName: "Quantity",
      editable: false,
      initialWidth: 140,
      wrapText: true
    };
    const parkingQuantityCol = useContractPencilCols
      ? {
          label: this.labels.Quantity,
          fieldName: "Quantity",
          type: "pencilEditable",
          editable: { fieldName: "QuantityEditable" },
          initialWidth: 140,
          wrapText: true,
          typeAttributes: {
            editable: { fieldName: "QuantityEditable" },
            fieldName: "Quantity",
            keyField: "LineItemId",
            keyFieldValue: { fieldName: "LineItemId" },
            inputType: "number",
            step: "any",
            pastStartSplit: { fieldName: "QuantityPastStartSplit" },
            alignment: "slds-text-align_left"
          }
        }
      : {
          ...quantityCol,
          editable: { fieldName: "QuantityEditable" }
        };
    this._parkingQuantityColumnDef = parkingQuantityCol;
    const listPriceCol = {
      label: PRODUCT_LIST_PRICE_LABEL,
      type: "currency",
      cellAttributes: { alignment: "left" },
      typeAttributes: { maximumFractionDigits: 2 },
      fieldName: "Products_List_Price",
      initialWidth: 168,
      wrapText: true
    };
    const subTypeCol = {
      label: this.labels.ProductTableSubType,
      fieldName: "ProductSubType",
      initialWidth: 120
    };
    const sizeM2Col = {
      label: "Size (m²)",
      fieldName: "SizeM2",
      type: "number",
      editable: false,
      initialWidth: 110,
      typeAttributes: { maximumFractionDigits: 2 },
      cellAttributes: { alignment: "left" }
    };
    const temporaryCol = {
      label: this.labels.Temporary,
      fieldName: "Temporary",
      type: "booleanCheckbox",
      editable: false,
      initialWidth: 120,
      wrapText: true,
      typeAttributes: {
        editable: { fieldName: "TemporaryEditable" },
        fieldName: "Temporary",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" }
      },
      cellAttributes: {
        alignment: "center",
        class: { fieldName: "TemporaryCellClass" }
      }
    };
    const terminationReasonCol = {
      label: this.labels.TerminationReason,
      fieldName: "TerminationReason",
      type: "combobox",
      editable: { fieldName: "TerminationReasonEditable" },
      initialWidth: 220,
      wrapText: true,
      typeAttributes: {
        editable: { fieldName: "TerminationReasonEditable" },
        fieldName: "TerminationReason",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" },
        picklistValues: this.terminationReasonPicklistMap,
        alignment: "slds-text-align_left"
      }
    };
    const earlyExitRequestCol = {
      label: this.labels.EarlyExitRequest,
      fieldName: "EarlyExitRequest",
      type: "booleanCheckbox",
      editable: false,
      initialWidth: 140,
      wrapText: true,
      typeAttributes: {
        editable: { fieldName: "EarlyExitRequestEditable" },
        fieldName: "EarlyExitRequest",
        keyField: "LineItemId",
        keyFieldValue: { fieldName: "LineItemId" }
      },
      cellAttributes: {
        alignment: "center"
      }
    };
    const notesCol = {
      label: "Description",
      fieldName: "Description",
      type: "text",
      editable: { fieldName: "DescriptionEditable" },
      initialWidth: 260,
      wrapText: true,
      cellAttributes: { class: { fieldName: "RowCssClass" } }
    };

    // Column order (after row # + selection): action → icons → Name → Access Type →
    // Desk/Unit Price → Product's Price → Desks Count → Product's List Price → Entry → End → Sub Type → …
    const dataColumns = [
      statusIconCol,
      nameCol,
      accessTypeCol,
      unitPriceCol,
      totalPriceCol,
      quantityCol,
      listPriceCol,
      entryDateCol,
      endDateCol,
      subTypeCol,
      sizeM2Col
    ];
    if (this.isOpportunity) {
      dataColumns.push(temporaryCol);
    } else if (this.isContract) {
      dataColumns.push(
        temporaryCol,
        cpiDateCol,
        terminationReasonCol,
        earlyExitRequestCol
      );
    }
    dataColumns.push(notesCol);
    const remainingCol = {
      label: "Iterations",
      fieldName: "IterationsDisplay",
      type: "text",
      editable: false,
      initialWidth: 110
    };
    dataColumns.splice(dataColumns.length - 1, 0, remainingCol);
    this.columns = dataColumns;

    if (this.isContract) {
      // Keep row actions as the first visible column.
      this.columns.unshift({
        type: "dualActionWithTooltip",
        hideDefaultActions: true,
        sortable: false,
        cellAttributes: {
          class: { fieldName: "RowCssClassForActions" },
          alignment: "right"
        },
        typeAttributes: {
          keyField: "LineItemId",
          keyFieldValue: { fieldName: "LineItemId" },
          leftIconName: "utility:replace",
          leftIconSrc: { fieldName: "PbReplaceActionIconUrl" },
          leftName: "replace-btn",
          leftDisabled: { fieldName: "ReplaceDisabled" },
          leftHidden: { fieldName: "ReplaceHidden" },
          leftTooltip: { fieldName: "ReplaceActionHover" },
          leftAlternativeText: { fieldName: "ReplaceButtonAltText" },
          rightIconName: "utility:delete",
          rightIconSrc: { fieldName: "PbDeleteActionIconUrl" },
          rightName: "delete-btn",
          rightDisabled: { fieldName: "DeleteDisabled" },
          rightHidden: { fieldName: "DeleteHidden" },
          rightTooltip: { fieldName: "DeleteActionHover" },
          rightAlternativeText: { fieldName: "DeleteButtonAltText" },
          variant: "bare",
          size: "small"
        },
        fixedWidth: 72
      });
    } else if (isEditable) {
      this.columns.unshift({
        type: "actionWithTooltip",
        cellAttributes: {
          class: "pb-row-action-td",
          alignment: "center"
        },
        typeAttributes: {
          iconName: "utility:delete",
          iconSrc: { fieldName: "PbDeleteActionIconUrl" },
          name: "delete-btn",
          keyField: "LineItemId",
          keyFieldValue: { fieldName: "LineItemId" },
          disabled: false,
          hidden: { fieldName: "DeleteHidden" },
          tooltip: { fieldName: "DeleteActionHover" },
          alternativeText: "Delete product",
          variant: "bare",
          size: "small"
        },
        fixedWidth: 50
      });
    }

    // Apply row highlight class to all non-dot columns (keep Entry Date icon attrs).
    this.columns = this.columns.map((col) => {
      // StatusIconValue / Temporary / EarlyExitRequest columns use dedicated cell classes.
      if (
        col.fieldName === "StatusIconValue" ||
        col.fieldName === "Temporary" ||
        col.fieldName === "EarlyExitRequest"
      )
        return col;
      const cellAttributes = { ...(col.cellAttributes || {}) };
      if (!cellAttributes.class) {
        cellAttributes.class = { fieldName: "RowCssClass" };
      }
      return { ...col, cellAttributes };
    });
  }

  /**
   * Contract Active tab (current + concluded terms): row replace/delete are unavailable but the
   * dual-action column still consumed width — omit it from displayed column defs.
   */
  get _hideContractActiveDualActionColumn() {
    return this.isContract && this.activeTab === "active";
  }

  _withoutDualActionColumn(cols) {
    if (!this._hideContractActiveDualActionColumn || !Array.isArray(cols)) {
      return cols;
    }
    return cols.filter((c) => c?.type !== "dualActionWithTooltip");
  }

  /** Columns for datatable. On Contract Active, first column shows only replacement (moving in/out) icons; draft change-type dots are omitted in normalizeProducts. */
  _patchColumnLabel(cols, fieldName, label) {
    return (Array.isArray(cols) ? cols : []).map((col) => {
      if (col?.fieldName === fieldName) {
        return { ...col, label };
      }
      return col;
    });
  }

  get displayColumnsStandard() {
    const patched = this._patchStatusIconColumn(
      this.columns || [],
      this.standardProducts || []
    );
    const withRoomsLabels = this._patchColumnLabel(
      (Array.isArray(patched) ? patched : []).map((col) => {
        if (col?.fieldName === "Quantity") {
          return {
            ...col,
            label: ROOMS_QUANTITY_LABEL,
            initialWidth: 140,
            wrapText: true
          };
        }
        return col;
      }),
      "UnitPrice",
      ROOMS_UNIT_PRICE_LABEL
    );
    return this._withoutDualActionColumn(withRoomsLabels);
  }

  get displayColumnsParking() {
    const patched = this._patchStatusIconColumn(
      this.columns || [],
      this.parkingProducts || []
    );
    const withExtraUnitPriceLabel = this._patchColumnLabel(
      patched,
      "UnitPrice",
      EXTRA_UNIT_PRICE_LABEL
    );
    const withEditableParkingQty = (cols) =>
      (Array.isArray(cols) ? cols : []).map((col) => {
        if (col?.fieldName === "Quantity" && this._parkingQuantityColumnDef) {
          return { ...this._parkingQuantityColumnDef };
        }
        return col;
      });
    if (!this.isContract) {
      return withEditableParkingQty(
        this._withoutDualActionColumn(withExtraUnitPriceLabel)
      );
    }
    return withEditableParkingQty(
      this._withoutDualActionColumn(
        this._asDeleteOnlyActionColumns(withExtraUnitPriceLabel)
      )
    );
  }

  /**
   * Extra (Contract Terms) section: same leading chrome as other sections, then only
   * Name → Quantity → Total Price → Entry → End → Notes (Description). Subset of `setStandardColumns`.
   */
  _buildExtraDisplayColumns() {
    const cols = this.columns || [];
    const isEditable = !this.isReadOnlyMode;
    const out = [];

    const actionCol = cols.find(
      (c) =>
        c?.type === "dualActionWithTooltip" ||
        (c?.type === "actionWithTooltip" && !c?.fieldName)
    );
    const iconCol = cols.find((c) => c?.fieldName === "StatusIconValue");
    if (
      actionCol &&
      !(
        actionCol.type === "dualActionWithTooltip" &&
        this._hideContractActiveDualActionColumn
      )
    ) {
      out.push({ ...actionCol });
    }
    if (iconCol) {
      out.push({ ...iconCol });
    }

    const byField = (fn) => cols.find((c) => c?.fieldName === fn);

    const nameCol = byField("Name");
    if (nameCol) {
      out.push({ ...nameCol });
    }

    const entryCol = byField("EntryDate");
    const endCol = byField("EndDate");
    const qtyCol = byField("Quantity");
    if (qtyCol) {
      // Contract Terms: quantity is set via replace flow, not inline.
      const qtyLabel = this.isContract
        ? this.labels.Value
        : this.labels.Quantity;
      const qtyEditable = !this.isContract && isEditable;
      out.push({ ...qtyCol, label: qtyLabel, editable: qtyEditable });
    }
    if (entryCol) {
      out.push({ ...entryCol });
    }
    if (endCol) {
      out.push({
        ...endCol,
        editable: { fieldName: "ContractTermEndDateEditable" },
        typeAttributes: {
          ...endCol.typeAttributes,
          editable: { fieldName: "ContractTermEndDateEditable" }
        }
      });
    }

    out.push({
      label: "Description",
      fieldName: "Description",
      type: "text",
      editable: isEditable,
      initialWidth: 260,
      wrapText: true,
      cellAttributes: { class: { fieldName: "RowCssClass" } }
    });

    const patched = this._patchStatusIconColumn(
      out,
      this.contractTermsProducts || []
    );
    return patched.map((col) => {
      if (col.fieldName === "StatusIconValue") {
        return col;
      }
      const cellAttributes = { ...(col.cellAttributes || {}) };
      if (!cellAttributes.class && col.fieldName) {
        cellAttributes.class = { fieldName: "RowCssClass" };
      }
      return { ...col, cellAttributes };
    });
  }

  get displayColumnsExtra() {
    return this._buildExtraDisplayColumns();
  }

  /** Contract datatable class + modifier for Extra slim column layout (nth-child divider fallbacks). */
  get datatableContainerClassExtra() {
    // Keep Extra section row sizing consistent with the main product tables.
    // The extra-slim variant can clip editable custom cells (Access Type combobox).
    return this.datatableContainerClass;
  }

  // ─── TAB HANDLING ─────────────────────────────────────────

  /** Toggle KPI Summary body visibility. */
  handleKpiViewToggle() {
    this.kpiViewExpanded = !this.kpiViewExpanded;
  }

  /** Custom tab bar: click sets tab from data-tab. */
  handleTabClick(event) {
    const newTab = event.currentTarget?.dataset?.tab;
    if (!newTab || newTab === this.activeTab) return;

    // Keep Draft tab when switching to Active while a persisted draft exists; Modify Contract now creates the DB draft immediately.

    this.activeTab = newTab;
    this._setUnifiedSelectedRows([]);
    this.draftValues = [];
    this.setColumns();
    if (this.isContract) {
      this._refreshEntryDateClockIcons();
    }
    if (
      this.isDraftTab &&
      this.draftOrderId &&
      !this.hasDraftProducts &&
      !this.isDraftHydrating
    ) {
      this._startDraftHydrationPolling();
    }
    this.updateContainerButtons();
  }

  // ─── MODIFY / ACTIVATE (Contract flow) ────────────────────

  /**
   * Called from the container's Modify button.
   * Creates a persisted draft order immediately (same Apex path as Save / bulk edit).
   */
  @api async handleModifyFromContainer() {
    this.isCreatingDraftFromModify = true;
    this.isDraftHydrating = false;
    this.draftValues = [];
    this._setUnifiedSelectedRows([]);
    this.draftProducts = this._buildInMemoryDraftProductsFromActive() || [];
    this.seedInMemoryDraftOrderFromActive();
    this.orderSectionEditMode = false;
    this.orderSectionDirty = false;
    this.isModifyMode = true;
    // User chose Draft; do not re-apply landing default (Concluded Terms) when wire refreshes after persist.
    this._defaultTabApplied = true;
    try {
      this.activeTab = "draft";
      this.setColumns();
      this.updateContainerButtons();
      await this._persistDraftFromModifyInBackground();
    } catch (e) {
      if (!e.pbSkipDuplicateToast) {
        this.showToast(
          "Error",
          this._reduceServerError(e) || e.message || "Failed to create draft",
          "error"
        );
      }
      this.activeTab = "active";
      this.isModifyMode = false;
      this.draftProducts = [];
      this.draftSummary = {};
      this.isDraftHydrating = false;
      this.updateContainerButtons();
    } finally {
      this.isCreatingDraftFromModify = false;
    }
  }

  async _persistDraftFromModifyInBackground() {
    if (this._modifyDraftPersistencePromise || this.draftOrderId) {
      return this._modifyDraftPersistencePromise;
    }
    this._modifyDraftPersistencePromise = (async () => {
      try {
        const persisted =
          await this._ensurePersistedDraftFromStagedOrderStart();
        if (this.isDraftTab) {
          this.showToast("Success", "Draft order created", "success");
        }
        return persisted;
      } catch (e) {
        if (!e.pbSkipDuplicateToast) {
          this.showToast(
            "Error",
            this._reduceServerError(e) || e.message || "Failed to create draft",
            "error"
          );
        }
        if (!e.pbSkipDuplicateToast) {
          throw e;
        }
        return undefined;
      } finally {
        this._modifyDraftPersistencePromise = null;
      }
    })();
    return this._modifyDraftPersistencePromise;
  }

  /**
   * Create Draft button in the Draft empty state — persists draft immediately (same as Modify Contract).
   */
  async handleCreateDraft() {
    this.activeTab = "draft";
    this.draftValues = [];
    this._setUnifiedSelectedRows([]);
    this.seedInMemoryDraftOrderFromActive();
    this.orderSectionEditMode = false;
    this.orderSectionDirty = false;
    try {
      await this._ensurePersistedDraftFromStagedOrderStart();
      this.showToast("Success", "Draft order created", "success");
    } catch (e) {
      if (!e.pbSkipDuplicateToast) {
        this.showToast(
          "Error",
          this._reduceServerError(e) || e.message || "Failed to create draft",
          "error"
        );
      }
      this.activeTab = "active";
      this.isModifyMode = false;
      this.draftProducts = [];
      this.draftSummary = {};
      this.updateContainerButtons();
    }
  }

  _isAlreadyActivatedActivationError(message) {
    return (
      typeof message === "string" && message.includes("Draft or Negotiation")
    );
  }

  async _applyPostActivationUiState(
    previousActiveOrderId,
    activatedOrderId,
    { showSuccessToast = true } = {}
  ) {
    if (showSuccessToast) {
      this.showToast(
        "Success",
        "Draft order activated successfully",
        "success"
      );
    }
    this._justActivatedDraft = true;
    this.activeTab = "active";
    this.activeProducts = [];
    this.activeSummary = {};
    this.activeOrderDetails = null;
    this.draftOrderId = null;
    this.isModifyMode = false;
    this.draftProducts = [];
    this.draftSummary = {};
    this.draftValues = [];
    this._setUnifiedSelectedRows([]);
    await this._refreshApexSafe(this.wiredOrdersResult);
    await this._waitForActiveOrderSwitch(
      previousActiveOrderId,
      activatedOrderId
    );
    await Promise.all([
      this._refreshApexSafe(this.wiredContractDatesResult),
      this._refreshApexSafe(this.wiredActiveLineItemsResult),
      this._refreshApexSafe(this.wiredActiveSummaryResult),
      this._refreshApexSafe(this.wiredActiveOrderDetailsResult),
      this._refreshMonthlyPaymentKpiWires()
    ]);
    this.draftOrderId = null;
    this.draftProducts = [];
    this.draftSummary = {};
    this.activeTab = "active";
    this.updateContainerButtons();
  }

  /**
   * Called from the container's Activate button.
   * Validates draft (required fields + dates within contract) then activates the real draft order.
   */
  @api async handleActivateDraftFromContainer() {
    if (this._activationInFlightPromise) {
      return this._activationInFlightPromise;
    }
    this._activationInFlightPromise = this._runDraftActivation();
    try {
      return await this._activationInFlightPromise;
    } finally {
      this._activationInFlightPromise = null;
    }
  }

  async _runDraftActivation() {
    const validation = this.validateDraftForActivation();
    if (!validation.valid) {
      this.showToast(
        "Validation Error",
        validation.message || "Complete all required fields and fix dates.",
        "error"
      );
      return;
    }

    const activatedOrderId = this.draftOrderId;
    const container = this.template.host?.closest(
      "c-package-builder-container"
    );
    this.isActivatingDraft = true;
    if (container && container.setActivating) {
      container.setActivating(true);
    }

    let replacementStartDate = new Date().toISOString().split("T")[0];
    try {
      const draftDetails = await getOrderDetails({ orderId: activatedOrderId });
      if (draftDetails?.effectiveDate) {
        const d = draftDetails.effectiveDate;
        replacementStartDate =
          typeof d === "string"
            ? d
            : `${d.year}-${String(d.month).padStart(2, "0")}-${String(d.day).padStart(2, "0")}`;
      }
    } catch {
      // Keep today if fetch fails
    }

    const previousActiveOrderId = this.activeOrderId;
    try {
      await activateDraftOrder({
        orderId: activatedOrderId,
        replacementStartDate
      });
      await this._applyPostActivationUiState(
        previousActiveOrderId,
        activatedOrderId
      );
    } catch (error) {
      const msg = this._activationErrorMessage(error);
      if (this._isAlreadyActivatedActivationError(msg)) {
        await this._applyPostActivationUiState(
          previousActiveOrderId,
          activatedOrderId,
          { showSuccessToast: false }
        );
        this.showToast(
          "Success",
          "Draft order activated successfully",
          "success"
        );
        return;
      }
      this.showToast("Error", msg, "error");
    } finally {
      this.isActivatingDraft = false;
      if (container && container.setActivating) {
        container.setActivating(false);
      }
    }
  }

  // ─── ROW ACTIONS ──────────────────────────────────────────

  handleRowAction(event) {
    if (this.isReadOnlyMode || this.isModifyMode) return;
    const actionName = event.detail.action.name;
    const row = event.detail.row;
    if (actionName === "delete-btn") {
      if (row.CanDelete === false) {
        this.showToast(
          "Info",
          row.DeleteDisabledReason ||
            "Only newly added or future-start products can be deleted.",
          "info"
        );
        return;
      }
      this.deleteRow(row);
      return;
    }
    if (actionName === "replace-btn") {
      if (row.CanReplace === false) {
        this.showToast(
          "Info",
          row.ReplaceDisabledReason || "This row cannot be replaced.",
          "info"
        );
        return;
      }
      this._setUnifiedSelectedRows([row.LineItemId || row.Id]);
      this.handleReplace();
    }
  }

  handleRowSelection(event) {
    const section =
      String(event?.detail?.section || "standard").trim() || "standard";
    const ids = (event?.detail?.selectedRows || [])
      .map((row) => row?.LineItemId || row?.Id)
      .filter(Boolean);

    this._selectedBySection = mergeSectionSelectionsExclusiveContractTerms({
      prevSelectionMap: this._selectedBySection,
      section,
      selectedIds: new Set(ids)
    });
    this.selectedRows = unionSelectionMap(this._selectedBySection);
  }

  /**
   * Toggle: select every row in Rooms (standard) and Extra (parking), or clear selection for those sections only.
   * Contract Terms (meter / `extra` section) is never bulk-selected; on "select all" it is cleared as before; on deselect it is left unchanged.
   */
  handleSelectAllRoomsAndExtra() {
    if (this.hideCheckboxColumn) {
      return;
    }
    const standardIds = this._allRowIdsForSection("standard");
    const parkingIds = this._allRowIdsForSection("parking");
    this._selectedBySection = ensureSelectionMap(this._selectedBySection);
    const allStandardSelected = standardIds.every((id) =>
      this._selectedBySection.standard.has(id)
    );
    const allParkingSelected = parkingIds.every((id) =>
      this._selectedBySection.parking.has(id)
    );
    const allRoomsAndExtraSelected = allStandardSelected && allParkingSelected;

    if (allRoomsAndExtraSelected) {
      this._selectedBySection.standard = new Set();
      this._selectedBySection.parking = new Set();
    } else {
      this._selectedBySection.standard = new Set(standardIds);
      this._selectedBySection.parking = new Set(parkingIds);
      this._selectedBySection.contractTerms = new Set();
    }
    this.selectedRows = unionSelectionMap(this._selectedBySection);
  }

  _rowIdForTable(row) {
    return row?.LineItemId || row?.Id || null;
  }

  _allRowIdsForSection(section) {
    let rows = [];
    if (section === "standard") rows = this.standardProducts || [];
    else if (section === "parking") rows = this.parkingProducts || [];
    else if (section === "contractTerms")
      rows = this.contractTermsProducts || [];
    return rows.map((r) => this._rowIdForTable(r)).filter(Boolean);
  }

  _sectionForRow(row) {
    if (!row) return "standard";
    if (this._isExtraSectionRow(row)) return "parking";
    if (this._isContractTermsRow(row)) return "contractTerms";
    return "standard";
  }

  _setUnifiedSelectedRows(ids) {
    const clean = [...new Set((ids || []).filter(Boolean))];
    this.selectedRows = clean;

    // Rebuild per-section sets so the next rowselection merge doesn't resurrect stale selections.
    this._selectedBySection = {
      standard: new Set(),
      parking: new Set(),
      contractTerms: new Set()
    };
    if (clean.length === 0) return;

    const byId = new Map();
    (this.lineItems || []).forEach((r) => {
      const id = this._rowIdForTable(r);
      if (id) byId.set(id, r);
    });
    for (const id of clean) {
      const row = byId.get(id);
      const section = this._sectionForRow(row);
      this._selectedBySection[section].add(id);
    }
  }

  deleteRow(row) {
    this.deleteProducts([row.LineItemId]);
  }

  /** Map legacy "Entry Date" copy to "Start Date" in user-facing errors. */
  _normalizeStartDateUserMessage(message) {
    if (!message || typeof message !== "string") return message;
    return message
      .replace(
        /Entry Date can only be edited for today or future dates unless you have admin override permission\./gi,
        "Start Date can only be edited for today or future dates unless you have admin override permission."
      )
      .replace(
        /Entry Date cannot be after End Date/gi,
        "Start Date cannot be after End Date"
      )
      .replace(
        /entry date cannot be before the order start date\./gi,
        "Start date cannot be before the contract start date."
      )
      .replace(
        /entry date cannot be after the order end date\./gi,
        "Start date cannot be after the contract end date."
      );
  }

  /**
   * Readable message from LDS (updateRecord), Apex, or thrown Error objects.
   */
  _reduceServerError(error) {
    if (!error) return this.labels.Error;
    if (typeof error === "string")
      return this._normalizeStartDateUserMessage(error);
    if (Array.isArray(error.body)) {
      const joined = error.body
        .map((e) => e.message)
        .filter(Boolean)
        .join(", ");
      return joined
        ? this._normalizeStartDateUserMessage(joined)
        : this.labels.Error;
    }
    const messages = [];
    if (error.body?.pageErrors?.length) {
      messages.push(
        ...error.body.pageErrors.map((e) => e.message).filter(Boolean)
      );
    }
    if (error.body?.fieldErrors && typeof error.body.fieldErrors === "object") {
      Object.keys(error.body.fieldErrors).forEach((field) => {
        const arr = error.body.fieldErrors[field];
        if (Array.isArray(arr)) {
          arr.forEach((entry) => {
            if (entry?.message) messages.push(entry.message);
          });
        }
      });
    }
    if (error.body?.output?.errors?.length) {
      messages.push(
        ...error.body.output.errors.map((e) => e.message).filter(Boolean)
      );
    }
    if (
      error.body?.output?.fieldErrors &&
      typeof error.body.output.fieldErrors === "object"
    ) {
      Object.keys(error.body.output.fieldErrors).forEach((field) => {
        const arr = error.body.output.fieldErrors[field];
        if (Array.isArray(arr)) {
          arr.forEach((entry) => {
            if (entry?.message) messages.push(entry.message);
          });
        }
      });
    }
    if (messages.length) {
      return this._normalizeStartDateUserMessage(
        [...new Set(messages)].join(", ")
      );
    }
    if (error.body && typeof error.body.message === "string") {
      const bm = error.body.message;
      if (bm && bm !== "Script-thrown exception") {
        return this._normalizeStartDateUserMessage(bm);
      }
    }
    if (error.message && error.message !== "Script-thrown exception") {
      return this._normalizeStartDateUserMessage(error.message);
    }
    return this.labels.Error;
  }

  deleteProducts(lineItemsToDelete) {
    const ids = [...new Set(lineItemsToDelete)].filter(Boolean);
    if (ids.length === 0) {
      return;
    }
    if (this._lineItemDeleteInFlight) {
      return;
    }
    this._lineItemDeleteInFlight = true;
    const beforeState = {
      activeProducts: this.isContract ? [...(this.activeProducts || [])] : null,
      draftProducts: this.isContract ? [...(this.draftProducts || [])] : null,
      productsData: !this.isContract ? [...(this.productsData || [])] : null,
      selectedRows: [...(this.selectedRows || [])]
    };
    if (this.isContract) {
      if (this.activeTab === "active") {
        this.activeProducts = (this.activeProducts || []).filter(
          (item) => !ids.includes(item.LineItemId)
        );
      } else {
        this.draftProducts = (this.draftProducts || []).filter(
          (item) => !ids.includes(item.LineItemId)
        );
      }
    } else {
      this.productsData = (this.productsData || []).filter(
        (item) => !ids.includes(item.LineItemId)
      );
    }
    this._setUnifiedSelectedRows(
      (this.selectedRows || []).filter((id) => !ids.includes(id))
    );
    this.updateContainerButtons();
    deleteLineItems({ itemIds: ids })
      .then(async (result) => {
        const entityDeleted =
          typeof result === "string" && result.includes("ENTITY_IS_DELETED");
        if (result === "Success" || entityDeleted) {
          if (this.isContract) {
            // Refresh in background so replacement metadata stays accurate without delaying UI feedback.
            Promise.all([
              refreshApex(this.wiredDraftLineItemsResult),
              refreshApex(this.wiredDraftSummaryResult),
              this._refreshMonthlyPaymentKpiWires()
            ]).catch(() => {});
          } else {
            Promise.all([
              refreshApex(this.wiredLineItemsResult),
              this._refreshMonthlyPaymentKpiWires()
            ]).catch(() => {});
          }
          this.showToast(
            "Success",
            this.labels.DeleteProductSuccess,
            "success"
          );
        } else {
          if (this.isContract) {
            this.activeProducts = beforeState.activeProducts;
            this.draftProducts = beforeState.draftProducts;
          } else {
            this.productsData = beforeState.productsData;
          }
          this._setUnifiedSelectedRows(beforeState.selectedRows);
          this.updateContainerButtons();
          this.showToast("Error", result, "error");
        }
      })
      .catch((error) => {
        if (this.isContract) {
          this.activeProducts = beforeState.activeProducts;
          this.draftProducts = beforeState.draftProducts;
        } else {
          this.productsData = beforeState.productsData;
        }
        this._setUnifiedSelectedRows(beforeState.selectedRows);
        this.updateContainerButtons();
        const msg = this._reduceServerError(error);
        this.showToast("Error", msg, "error");
        console.error("Error deleting line items:", error);
      })
      .finally(() => {
        this._lineItemDeleteInFlight = false;
      });
  }

  // ─── SAVE (with lazy draft creation for Contracts) ────────

  /**
   * Called when user edits a cell in the Draft tab table. Only updates draft state;
   * actual persist happens when user clicks "Save Changes".
   * Active-tab Early Exit Request toggles persist immediately to OrderItem.
   */
  async handleDraftValueChange(event) {
    const incoming = event.detail?.draftValues ?? [];

    if (
      this.isContract &&
      !this.isOpportunity &&
      this.activeTab === "active" &&
      Array.isArray(incoming) &&
      incoming.length > 0
    ) {
      const earlyExitRows = incoming.filter((row) =>
        Object.prototype.hasOwnProperty.call(row || {}, "EarlyExitRequest")
      );
      if (earlyExitRows.length > 0) {
        await this._persistEarlyExitRequestImmediate(earlyExitRows);
      }
      const hasNonEarlyExit = incoming.some((row) =>
        Object.keys(row || {}).some(
          (k) => k !== "LineItemId" && k !== "Id" && k !== "EarlyExitRequest"
        )
      );
      if (!hasNonEarlyExit) {
        return;
      }
    }

    // Three datatables (Rooms + Parking + Extra) each emit only the rows touched in that
    // event — often a single cell/row. Merge by line id so edits on other rows
    // and in the other section are preserved (the old section-wide filter
    // dropped every standard draft whenever any standard cell changed).
    const byId = new Map();
    const draftRowKey = (row) =>
      this._normalizeRowId(row?.LineItemId || row?.Id);
    const resolveCanonicalLineId = (row, sourceRow) =>
      sourceRow?.LineItemId ||
      sourceRow?.Id ||
      row?.LineItemId ||
      row?.Id ||
      null;

    const mergeDraftRow = (row) => {
      const nk = draftRowKey(row);
      if (!nk) return;
      const prev = byId.get(nk) || {};
      const sourceRow = (this.lineItems || []).find(
        (r) => draftRowKey(r) === nk
      );
      const canonicalId = resolveCanonicalLineId(row, sourceRow);
      byId.set(nk, {
        ...prev,
        ...row,
        LineItemId: canonicalId,
        Id: canonicalId
      });
    };
    (this.draftValues || []).forEach(mergeDraftRow);
    const filteredIncoming = incoming.map((row) => {
      const nk = draftRowKey(row);
      const sourceRow = nk
        ? (this.lineItems || []).find((r) => draftRowKey(r) === nk)
        : null;
      let outRow = row;

      // Prevent edits to historical Original Start Date on existing draft products (locked).
      if (
        this._isExistingDraftProductRow(sourceRow) &&
        Object.prototype.hasOwnProperty.call(outRow, "OriginalStartDate")
      ) {
        const clone = { ...outRow };
        delete clone.OriginalStartDate;
        return clone;
      }
      return outRow;
    });

    for (const row of filteredIncoming) {
      const nk = draftRowKey(row);
      if (!nk) {
        continue;
      }
      const sourceRow = (this.lineItems || []).find(
        (r) => draftRowKey(r) === nk
      );
      const canonicalId = resolveCanonicalLineId(row, sourceRow);
      const prev = byId.get(nk) || {};
      if (sourceRow && this._terminatedDraftSaveBlocked(row, sourceRow)) {
        this.showToast("Error", this.labels.TerminatedOrderItemNoEdit, "error");
        byId.set(nk, prev);
        continue;
      }
      let merged = {
        ...prev,
        ...row,
        LineItemId: canonicalId,
        Id: canonicalId
      };

      const hasTotalPrice = Object.prototype.hasOwnProperty.call(
        row,
        "TotalPrice"
      );
      const hasUnitPrice = Object.prototype.hasOwnProperty.call(
        row,
        "UnitPrice"
      );
      const hasQuantityInRow = Object.prototype.hasOwnProperty.call(
        row,
        "Quantity"
      );

      if (hasQuantityInRow) {
        const rowAccessType = this._readRowAccessType(sourceRow || merged);
        const draftAccessType = this._readRowAccessType(merged);
        const effectiveAccessType = draftAccessType || rowAccessType;
        if (isUsageBased(effectiveAccessType)) {
          this.showToast(
            "Info",
            "Quantity cannot be changed for Usage Based products.",
            "info"
          );
          merged = { ...prev, LineItemId: canonicalId, Id: canonicalId };
          byId.set(nk, merged);
          continue;
        }
        const rawQty = Number(merged.Quantity);
        if (!Number.isFinite(rawQty) || rawQty <= 0) {
          this.showToast(
            "Validation Error",
            "Quantity must be greater than zero to set product price.",
            "error"
          );
          merged = { ...prev, LineItemId: canonicalId, Id: canonicalId };
          Object.keys(row).forEach((k) => {
            if (
              k !== "TotalPrice" &&
              k !== "UnitPrice" &&
              k !== "LineItemId" &&
              k !== "Id"
            ) {
              merged[k] = row[k];
            }
          });
        } else {
          const unitBase = this._pbPreservedUnitPriceForQuantityEdit(
            row,
            prev,
            sourceRow
          );
          if (unitBase === null || !Number.isFinite(Number(unitBase))) {
            this.showToast(
              "Validation Error",
              "Quantity must be greater than zero to set product price.",
              "error"
            );
            merged = { ...prev, LineItemId: canonicalId, Id: canonicalId };
            Object.keys(row).forEach((k) => {
              if (
                k !== "TotalPrice" &&
                k !== "UnitPrice" &&
                k !== "LineItemId" &&
                k !== "Id"
              ) {
                merged[k] = row[k];
              }
            });
          } else {
            const unitRounded = Math.round(Number(unitBase) * 100) / 100;
            const lineTotal = this._pbLineTotalFromUnitAndQty(
              unitRounded,
              rawQty
            );
            merged.UnitPrice = unitRounded;
            merged.TotalPrice = lineTotal;
          }
        }
        merged = this._applyMonthlyClearsDraftEndDates(merged, row, sourceRow);
        merged = this._applyTerminationReasonClearsDraftEndDate(
          merged,
          row,
          sourceRow,
          prev
        );
        byId.set(nk, merged);
        continue;
      }

      if (hasUnitPrice && !hasTotalPrice) {
        delete merged.TotalPrice;
      }
      if (hasTotalPrice) {
        const qty = this._pbEffectiveQuantityForLinePrice(sourceRow, merged);
        const unit = this._pbDeriveUnitPriceFromLineTotal(row.TotalPrice, qty);
        if (unit === null) {
          this.showToast(
            "Validation Error",
            "Quantity must be greater than zero to set product price.",
            "error"
          );
          merged = { ...prev, LineItemId: canonicalId, Id: canonicalId };
          Object.keys(row).forEach((k) => {
            if (
              k !== "TotalPrice" &&
              k !== "UnitPrice" &&
              k !== "LineItemId" &&
              k !== "Id"
            ) {
              merged[k] = row[k];
            }
          });
        } else {
          merged.UnitPrice = unit;
          merged.TotalPrice = row.TotalPrice;
        }
      }
      merged = this._applyMonthlyClearsDraftEndDates(merged, row, sourceRow);
      merged = this._applyTerminationReasonClearsDraftEndDate(
        merged,
        row,
        sourceRow,
        prev
      );
      byId.set(nk, merged);
    }

    const incomingMetas = filteredIncoming
      .map((row) => {
        const nk = draftRowKey(row);
        if (!nk) return null;
        return {
          id: nk,
          hadEnd: Object.prototype.hasOwnProperty.call(row, "EndDate"),
          hadEntry:
            Object.prototype.hasOwnProperty.call(row, "EntryDate") ||
            (!this.isOpportunity &&
              Object.prototype.hasOwnProperty.call(row, "ServiceDate"))
        };
      })
      .filter((m) => m && (m.hadEnd || m.hadEntry));
    this._applyReplacementDateMirrorsToDraftMap(byId, incomingMetas);

    this.draftValues = Array.from(byId.values());
    this._refreshEntryDateClockIcons();
  }

  /**
   * Persist a draft order from staged in-memory order start (Modify Contract / bulk edit path).
   * @returns {Promise<{ idMapping: Record<string, string> }>}
   */
  async _ensurePersistedDraftFromStagedOrderStart() {
    const preserveInMemoryDraftRows =
      this.isContract &&
      this.activeTab === "draft" &&
      this.isModifyMode &&
      !this.draftOrderId &&
      (this.draftProducts?.length || 0) > 0;
    const seededStart = this._normalizeToYyyyMmDd(
      this.inMemoryDraftOrder?.effectiveDate
    );
    const orderStartValidationMsg =
      this._validateOrderStartAgainstContractStart(seededStart);
    if (orderStartValidationMsg) {
      this.showToast("Validation Error", orderStartValidationMsg, "error");
      const err = new Error(orderStartValidationMsg);
      err.pbSkipDuplicateToast = true;
      throw err;
    }
    const draftResult = await ensureDraftOrderWithStartDate({
      contractId: this.recordId,
      initialOrderStartDate: seededStart || null
    });
    if (!draftResult?.draftOrder?.Id) {
      this.showToast("Error", "Failed to create draft order", "error");
      throw new Error("Failed to create draft order");
    }
    this.draftOrderId = draftResult.draftOrder.Id;
    this._authoritativeDraftOrderId = this.draftOrderId;
    this._draftGuardUntilMs = Date.now() + 8000;
    const idMapping = draftResult.itemIdMapping || {};
    this.isModifyMode = false;
    await this.applyInMemoryOrderDetailsToDraft(this.draftOrderId);
    this._clearOrderEditingState();
    this._setUnifiedSelectedRows(
      (this.selectedRows || []).map((oldId) => idMapping[oldId] || oldId)
    );
    if (!preserveInMemoryDraftRows) {
      this.draftProducts = [];
      this.draftSummary = {};
    }
    await this._refreshApexSafe(this.wiredOrdersResult);
    this.draftValues = [];
    await this._refreshDraftHydrationBundle();
    this.setColumns();
    this.updateContainerButtons();
    return { idMapping };
  }

  /** Map line Access_Type__c / AccessType to values expected by bulk terminate modal (Periodic | Monthly). */
  _normalizeAccessTypeForTerminate(raw) {
    const s = String(raw || "").trim();
    if (!s) {
      return null;
    }
    if (s === "Rent" || /^rent$/i.test(s)) {
      return "Periodic";
    }
    if (s === "Periodic" || /^periodic/i.test(s)) {
      return "Periodic";
    }
    if (s === "Monthly" || /^monthly/i.test(s)) {
      return "Monthly";
    }
    return null;
  }

  /**
   * Bulk edit: at least one selected row (non-Contract Terms) will have Monthly access after applying
   * optional access type from the modal.
   */
  _bulkSelectionIncludesMonthlyAccess(bulkResult) {
    const accessFromModal = bulkResult?.accessType
      ? this._normalizeAccessTypeForTerminate(bulkResult.accessType)
      : null;
    for (const id of this.selectedRows || []) {
      const row = (this.lineItems || []).find((p) => p.LineItemId === id);
      if (
        !row ||
        this._isContractTermsRow(row) ||
        this._isTerminatedDraftOrderItemRow(row)
      ) {
        continue;
      }
      const effective =
        accessFromModal ||
        this._normalizeAccessTypeForTerminate(
          row?.AccessType || row?.Access_Type__c
        );
      if (effective === "Monthly") {
        return true;
      }
    }
    return false;
  }

  _isPeriodicAccessTypeValue(raw) {
    return requiresEndDate(raw);
  }

  /** Contract OrderItem: termination reason picklist or grid label populated. */
  _orderItemTerminationReasonPresent(row) {
    return orderItemTerminationReasonPresent(row);
  }

  _isTerminatedDraftOrderItemRow(row) {
    return (
      this.isContract &&
      !this.isOpportunity &&
      this.activeTab === "draft" &&
      this._orderItemTerminationReasonPresent(row)
    );
  }

  /** User cleared Termination Reason on a row that previously had one (inline or save). */
  _isClearingTerminationReasonOnDraftItem(item, sourceRow, prevDraftRow) {
    if (!this.isContract || this.isOpportunity || !item) {
      return false;
    }
    if (!Object.prototype.hasOwnProperty.call(item, "TerminationReason")) {
      return false;
    }
    if (String(item.TerminationReason ?? "").trim()) {
      return false;
    }
    return (
      this._orderItemTerminationReasonPresent(sourceRow) ||
      this._orderItemTerminationReasonPresent(prevDraftRow) ||
      this._orderItemTerminationReasonPresent(item)
    );
  }

  /**
   * Terminated draft rows block most inline/save edits; clearing termination may also
   * restore EndDate / OriginalEndDate and must not be rejected as a blocked field touch.
   */
  _terminatedDraftSaveBlocked(item, sourceRow) {
    if (!sourceRow || !this._isTerminatedDraftOrderItemRow(sourceRow)) {
      return false;
    }
    const clearingTermination = this._isClearingTerminationReasonOnDraftItem(
      item,
      sourceRow
    );
    const allowedWhenClearingTermination = new Set([
      "TerminationReason",
      "EndDate",
      "OriginalEndDate",
      "LineItemId",
      "Id"
    ]);
    return Object.keys(item || {}).some((key) => {
      if (clearingTermination && allowedWhenClearingTermination.has(key)) {
        return false;
      }
      return TERMINATED_DRAFT_BLOCKED_DRAFT_FIELDS.has(key);
    });
  }

  _bulkEditResultHasUnitPriceUpdate(result) {
    return (
      result?.unitPrice !== null &&
      result?.unitPrice !== undefined &&
      result?.unitPrice !== ""
    );
  }

  /** Access type after bulk edit applies (modal override wins over current row). */
  _bulkEditEffectiveAccessType(row, resultAccessType) {
    if (resultAccessType) {
      return resultAccessType;
    }
    return row?.AccessType || row?.Access_Type__c || null;
  }

  _bulkEditResultHasNonEndDateChange(result) {
    if (!result) {
      return false;
    }
    return !!(
      result.accessType ||
      result.entryDate ||
      this._bulkEditResultHasUnitPriceUpdate(result)
    );
  }

  _selectionIncludesTerminatedContractOrderItems(ids) {
    if (!this.isContract || this.isOpportunity || !Array.isArray(ids)) {
      return false;
    }
    const rows = this.lineItems || [];
    return ids.some((id) => {
      const row = rows.find((r) => (r.LineItemId || r.Id) === id);
      return this._orderItemTerminationReasonPresent(row);
    });
  }

  /**
   * Wire load must show persisted OrderItem dates only. Restoring end dates after
   * termination clear is handled on draft edit + save (see _applyTerminationReasonClearsDraftEndDate).
   */
  _reconcileDraftRowEndAfterClearedTermination(prod) {
    return prod;
  }

  /**
   * Draft row: when the user clears Termination Reason via the inline picklist,
   * restore EndDate from the activated order line (or draft Original_End_Date__c).
   */
  _applyTerminationReasonClearsDraftEndDate(
    merged,
    row,
    sourceRow,
    prevDraftRow
  ) {
    if (!this.isContract || this.isOpportunity) {
      return merged;
    }
    if (!Object.prototype.hasOwnProperty.call(row, "TerminationReason")) {
      return merged;
    }
    const hadTermination =
      this._orderItemTerminationReasonPresent(sourceRow) ||
      this._orderItemTerminationReasonPresent(prevDraftRow);
    const newVal = String(row.TerminationReason ?? "").trim();
    if (newVal) {
      return merged;
    }
    if (!hadTermination) {
      return merged;
    }
    const lookupRow = draftRowForClearedTerminationRestore(
      sourceRow,
      prevDraftRow,
      row
    );
    const activeLine = this._findActiveOrderLineForDraftRow(lookupRow);
    const restoredEnd = endDateYmdToRestoreAfterClearedTermination(
      lookupRow,
      activeLine,
      {
        keepCurtailedEndForReplacement:
          this._lineMustKeepCurtailedEndForReplacement(sourceRow)
      }
    );
    if (!restoredEnd) {
      return merged;
    }
    const out = { ...merged };
    out.EndDate = restoredEnd;
    if (!this.isOpportunity) {
      out.OriginalEndDate = restoredEnd;
    }
    return out;
  }

  /** Draft row: access types that require End Date without one — highlight End Date for inline edit. */
  _rowRequiresPeriodicEndDate(row, draftMap) {
    if (!row) {
      return false;
    }
    if (this.isContract) {
      if (this.activeTab !== "draft") {
        return false;
      }
    } else if (!this.isOpportunity || this.isReadOnlyMode) {
      return false;
    }
    const lineId = this._normalizeRowId(row.LineItemId || row.Id);
    const draft =
      lineId && draftMap && draftMap.get ? draftMap.get(lineId) : null;
    const merged = draft ? { ...row, ...draft } : row;
    if (this._isPastStartForSplitChange(merged)) {
      return false;
    }
    if (this._lineMustKeepCurtailedEndForReplacement(row)) {
      return false;
    }
    const accessType = merged?.AccessType ?? merged?.Access_Type__c;
    if (!requiresEndDate(accessType)) {
      return false;
    }
    return !this._formatRowEndDateYmd(merged);
  }

  _endDateRequiredMessageForRow(row, draftMap) {
    if (!row) {
      return endDateRequiredMessage(null);
    }
    const lineId = this._normalizeRowId(row.LineItemId || row.Id);
    const draft =
      lineId && draftMap && draftMap.get ? draftMap.get(lineId) : null;
    const merged = draft ? { ...row, ...draft } : row;
    const rawAccessType = merged?.AccessType ?? merged?.Access_Type__c;
    return endDateRequiredMessage(rawAccessType);
  }

  _buildEndDateCellDecoration(
    row,
    draftMap,
    baseCellClass,
    endBeforeOrderStart,
    isActiveTab
  ) {
    const periodicRequired = this._rowRequiresPeriodicEndDate(row, draftMap);
    let cellClass = (baseCellClass || "").trim();
    let tooltip = "";
    if (endBeforeOrderStart) {
      cellClass = cellClass
        ? `${cellClass} pb-end-date-before-order-start`
        : "pb-end-date-before-order-start";
      tooltip = this._endDateBeforeStartTooltip(isActiveTab);
    }
    if (periodicRequired) {
      cellClass = cellClass
        ? `${cellClass} pb-end-date-required`
        : "pb-end-date-required";
      tooltip = this._endDateRequiredMessageForRow(row, draftMap);
    }
    return { cellClass, tooltip };
  }

  _applyMonthlyClearsDraftEndDates(merged, row, sourceRow) {
    const terminationLookup = { ...sourceRow, ...merged };
    if (Object.prototype.hasOwnProperty.call(row, "TerminationReason")) {
      terminationLookup.TerminationReason = row.TerminationReason;
    }
    if (
      this.isContract &&
      this.activeTab === "draft" &&
      this._orderItemTerminationReasonPresent(terminationLookup)
    ) {
      return merged;
    }
    if (this._lineMustKeepCurtailedEndForReplacement(sourceRow)) {
      return merged;
    }
    const at =
      merged?.AccessType ??
      row?.AccessType ??
      sourceRow?.AccessType ??
      sourceRow?.Access_Type__c;
    if (this._normalizeAccessTypeForTerminate(at) !== "Monthly") {
      return merged;
    }
    const out = { ...merged };
    out.EndDate = null;
    if (!this.isOpportunity) {
      out.OriginalEndDate = null;
    }
    return out;
  }

  async handleSave(event) {
    let saveDraftValues = event.detail.draftValues;

    // --- Lazy draft creation for Contract modify mode ---
    // When the user is in modify mode (in-memory clone) and saves,
    // we create the real draft order in the DB first, then apply edits.
    if (this.isContract && this.isModifyMode && !this.draftOrderId) {
      try {
        const { idMapping } = await this._persistDraftFromModifyInBackground();

        // Re-map saveDraftValues from active OrderItem IDs to new draft IDs
        saveDraftValues = saveDraftValues.map((item) => {
          const oldId = item.LineItemId || item.Id;
          const newId = idMapping[oldId] || oldId;
          return { ...item, LineItemId: newId, Id: newId };
        });

        // If no field edits (user just triggered save without changes),
        // the clone itself is enough
        if (saveDraftValues.length === 0) {
          this.showToast("Success", "Draft order created", "success");
          return;
        }
      } catch (error) {
        if (!error.pbSkipDuplicateToast) {
          this.showToast(
            "Error",
            error.body?.message || error.message || "Failed to create draft",
            "error"
          );
        }
        return;
      }
    }

    /** Persist toolbar Order Start Date (saved draft only): align lines, then update Order_Start_Date__c. */
    let orderStartDateSaved = false;
    if (
      this.isContract &&
      this.draftOrderId &&
      this._toolbarEffectiveDateValue !== undefined
    ) {
      try {
        orderStartDateSaved = await this._persistToolbarOrderStartDate();
      } catch (e) {
        const msg = this._reduceServerError(e);
        this.showToast("Error", msg, "error");
        return;
      }
    }

    for (const item of saveDraftValues) {
      if (!Object.prototype.hasOwnProperty.call(item, "TotalPrice")) {
        continue;
      }
      const sid = item.LineItemId || item.Id;
      const sourceRowForQty = (this.lineItems || []).find(
        (r) => (r.LineItemId || r.Id) === sid
      );
      const qty = this._pbEffectiveQuantityForLinePrice(sourceRowForQty, item);
      if (this._pbDeriveUnitPriceFromLineTotal(item.TotalPrice, qty) === null) {
        this.showToast(
          "Validation Error",
          "Quantity must be greater than zero to set product price.",
          "error"
        );
        return;
      }
    }

    for (const item of saveDraftValues) {
      const sid = item.LineItemId || item.Id;
      const sourceRow = (this.lineItems || []).find(
        (r) => (r.LineItemId || r.Id) === sid
      );
      if (sourceRow && this._terminatedDraftSaveBlocked(item, sourceRow)) {
        this.showToast("Error", this.labels.TerminatedOrderItemNoEdit, "error");
        return;
      }
    }

    if (!this._validateReplacedMonthlyParentEndDateEdits(saveDraftValues)) {
      return;
    }

    // Build the line item payload (TotalPrice is read-only in SF — persist only UnitPrice, derived from line total when needed)
    let lineItemIds = [];
    let lineData = saveDraftValues.map((item) => {
      lineItemIds.push(item.LineItemId || item.Id);
      let obj = {
        Id: item.LineItemId || item.Id,
        sobjectType: this.sobjectType
      };
      const sourceRow = (this.lineItems || []).find(
        (r) => (r.LineItemId || r.Id) === obj.Id
      );
      const qty = this._pbEffectiveQuantityForLinePrice(sourceRow, item);
      const isTerminatedDraftLine =
        this._isTerminatedDraftOrderItemRow(sourceRow);
      if (Object.prototype.hasOwnProperty.call(item, "TotalPrice")) {
        const unitFromTotal = this._pbDeriveUnitPriceFromLineTotal(
          item.TotalPrice,
          qty
        );
        if (unitFromTotal !== null) {
          obj.UnitPrice = unitFromTotal;
        }
      } else if (Object.prototype.hasOwnProperty.call(item, "UnitPrice")) {
        obj.UnitPrice = item.UnitPrice;
      }
      if (Object.prototype.hasOwnProperty.call(item, "AccessType"))
        obj.Access_Type__c = item.AccessType;
      if (Object.prototype.hasOwnProperty.call(item, "Description"))
        obj.Description = item.Description;
      if (Object.prototype.hasOwnProperty.call(item, "TerminationReason")) {
        const reasonVal = String(item.TerminationReason ?? "").trim();
        obj.Termination_Reason__c = reasonVal || null;
        // Clearing the reason restores EndDate from the activated line (including Periodic).
        const hadTermination =
          this._orderItemTerminationReasonPresent(sourceRow) ||
          this._orderItemTerminationReasonPresent(item);
        if (!reasonVal && hadTermination && !this.isOpportunity) {
          const draftPatch = (this.draftValues || []).find(
            (d) =>
              this._normalizeRowId(d?.LineItemId || d?.Id) ===
              this._normalizeRowId(obj.Id)
          );
          const lookupRow = draftRowForClearedTerminationRestore(
            sourceRow,
            draftPatch,
            item
          );
          const activeLine = this._findActiveOrderLineForDraftRow(lookupRow);
          const restoredEnd = endDateYmdToRestoreAfterClearedTermination(
            lookupRow,
            activeLine,
            {
              keepCurtailedEndForReplacement:
                this._lineMustKeepCurtailedEndForReplacement(sourceRow)
            }
          );
          if (restoredEnd) {
            obj.EndDate = restoredEnd;
          }
        }
      }

      if (this.isOpportunity) {
        if (Object.prototype.hasOwnProperty.call(item, "EntryDate"))
          obj.Entry_Date__c = item.EntryDate || null;
        if (Object.prototype.hasOwnProperty.call(item, "EndDate"))
          obj.End_date__c = item.EndDate || null;
        if (Object.prototype.hasOwnProperty.call(item, "CpiDate"))
          obj.CPI_Date__c = item.CpiDate || null;
        if (Object.prototype.hasOwnProperty.call(item, "Temporary"))
          obj.Temporary__c = item.Temporary;
      } else {
        if (Object.prototype.hasOwnProperty.call(item, "EntryDate")) {
          obj.ServiceDate = item.EntryDate || null;
        } else if (Object.prototype.hasOwnProperty.call(item, "ServiceDate")) {
          obj.ServiceDate = item.ServiceDate || null;
        }
        if (Object.prototype.hasOwnProperty.call(item, "EndDate")) {
          obj.EndDate = item.EndDate || null;
        }
        if (Object.prototype.hasOwnProperty.call(item, "CpiDate")) {
          obj.CPI_Date__c = item.CpiDate || null;
        }
        if (Object.prototype.hasOwnProperty.call(item, "Temporary")) {
          obj.Temporary__c = item.Temporary;
        }
        if (Object.prototype.hasOwnProperty.call(item, "EarlyExitRequest")) {
          obj.Early_Exit_Request__c = item.EarlyExitRequest === true;
        }
      }

      const effectiveAccessType =
        (Object.prototype.hasOwnProperty.call(item, "AccessType")
          ? item.AccessType
          : null) ??
        sourceRow?.AccessType ??
        sourceRow?.Access_Type__c;
      if (
        Object.prototype.hasOwnProperty.call(item, "Quantity") &&
        !isUsageBased(effectiveAccessType)
      ) {
        obj.Quantity = item.Quantity;
      }
      if (
        !isTerminatedDraftLine &&
        this._normalizeAccessTypeForTerminate(effectiveAccessType) ===
          "Monthly" &&
        !this._lineMustKeepCurtailedEndForReplacement(sourceRow)
      ) {
        if (this.isOpportunity) {
          obj.End_date__c = null;
        } else {
          obj.EndDate = null;
        }
      }

      return obj;
    });

    const payloadKeys = this.isOpportunity
      ? [
          "UnitPrice",
          "Access_Type__c",
          "Quantity",
          "Description",
          "Entry_Date__c",
          "End_date__c",
          "CPI_Date__c",
          "Temporary__c"
        ]
      : [
          "UnitPrice",
          "Access_Type__c",
          "Quantity",
          "Description",
          "ServiceDate",
          "EndDate",
          "CPI_Date__c",
          "Termination_Reason__c",
          "Temporary__c",
          "Early_Exit_Request__c"
        ];
    let filteredLineData = lineData.filter((item) =>
      payloadKeys.some((k) => Object.prototype.hasOwnProperty.call(item, k))
    );
    this._mergeReplacementMirrorIntoSavePayload(
      filteredLineData,
      saveDraftValues
    );
    const filteredIds = filteredLineData.map((item) => item.Id);

    if (filteredLineData.length === 0) {
      if (orderStartDateSaved) {
        this.showToast("Success", this.labels.AddProductSuccess, "success");
        await Promise.all([
          refreshApex(this.wiredDraftLineItemsResult),
          refreshApex(this.wiredDraftSummaryResult),
          refreshApex(this.wiredDraftOrderDetailsResult),
          this._refreshMonthlyPaymentKpiWires()
        ]);
        this.updateContainerButtons();
        return;
      }
      const msg = this.isOpportunity
        ? "No editable changes to save."
        : "Start Date is read-only for existing draft products. No editable changes to save.";
      this.showToast("Info", msg, "info");
      return;
    }

    let parentEndValidationOverride = null;
    if (this.isContract && this.activeTab === "draft" && this.draftOrderId) {
      try {
        const parentSyncResult =
          await this._autoExtendParentEndDatesBeforeSave(filteredLineData);
        parentEndValidationOverride =
          parentSyncResult?.validationParentEndYmd || null;
      } catch (e) {
        this.showToast(
          "Error",
          this._reduceServerError(e) ||
            "Failed to update contract/order end date.",
          "error"
        );
        return;
      }
    }
    if (
      !this.validateDates(filteredLineData, {
        parentEndOverride: parentEndValidationOverride
      })
    )
      return;

    await this.saveProducts(filteredIds, filteredLineData, null, {
      skipPreExtend: true
    }).catch(() => {});
  }

  /**
   * Platform rules tie line dates to Order.EffectiveDate (set once from Contract on insert). Business
   * start for Package Builder is Order_Start_Date__c — align lines to that date before/after order DML.
   * Later start: raise line dates first, then update the order.
   * Earlier start: update the order first, then pull line dates down — aligning lines before the order
   * causes FIELD_INTEGRITY_EXCEPTION on item DML.
   */
  async _syncDraftOrderStartWithLines(orderId, newStartRaw, currentStartRaw) {
    const newYmd = this._normalizeToYyyyMmDd(newStartRaw);
    const curYmd = this._normalizeToYyyyMmDd(currentStartRaw);
    if (!orderId || !newYmd) {
      return;
    }
    const isBackdate = curYmd && newYmd < curYmd;
    try {
      if (isBackdate) {
        await updateRecord({
          fields: {
            Id: orderId,
            Order_Start_Date__c: newYmd
          }
        });
        await alignOrderItemDatesForStartDateChange({
          orderId,
          newOrderStartDate: newYmd,
          alignChangeTypeNewLines: false
        });
      } else {
        await alignOrderItemDatesForStartDateChange({
          orderId,
          newOrderStartDate: newYmd,
          alignChangeTypeNewLines: true
        });
        await updateRecord({
          fields: {
            Id: orderId,
            Order_Start_Date__c: newYmd
          }
        });
      }
    } catch (e) {
      const detail = this._reduceServerError(e);
      throw new Error(
        detail && detail !== this.labels.Error
          ? detail
          : "Contract start date could not be updated."
      );
    }
  }

  /**
   * Persist toolbar draft order start (align + order DML in platform-safe order).
   * Clears _toolbarEffectiveDateValue when nothing to do or after success.
   */
  async _persistToolbarOrderStartDate() {
    if (this._toolbarOrderStartPersistPromise) {
      return this._toolbarOrderStartPersistPromise;
    }
    this._toolbarOrderStartPersistPromise = (async () => {
      try {
        return await this._persistToolbarOrderStartDateBody();
      } finally {
        this._toolbarOrderStartPersistPromise = null;
      }
    })();
    return this._toolbarOrderStartPersistPromise;
  }

  async _persistToolbarOrderStartDateBody() {
    if (!this.draftOrderId || this._toolbarEffectiveDateValue === undefined) {
      return false;
    }
    const newYmd = this._normalizeToYyyyMmDd(this._toolbarEffectiveDateValue);
    const currentYmd = this._normalizeToYyyyMmDd(
      this.draftOrderDetails?.effectiveDate
    );
    if (!newYmd) {
      this._toolbarEffectiveDateValue = undefined;
      return false;
    }
    const contractStartValidationMsg =
      this._validateOrderStartAgainstContractStart(newYmd);
    if (contractStartValidationMsg) {
      throw new Error(contractStartValidationMsg);
    }
    if (newYmd === currentYmd) {
      this._toolbarEffectiveDateValue = undefined;
      return false;
    }
    const isBackdate = currentYmd && newYmd < currentYmd;
    if (
      !isBackdate &&
      this._draftWouldForwardOrderStartRealignNewLines(newYmd)
    ) {
      const confirmed = await packageBuilderConfirmModal.open({
        size: "small",
        title: "Confirm Contract Start Date Change",
        message:
          "Changing the contract start date will also update start dates for newly added products in this draft.",
        confirmLabel: "Continue",
        cancelLabel: this.labels.Cancel
      });
      if (!confirmed) {
        this._toolbarEffectiveDateValue = undefined;
        this._refreshEntryDateClockIcons();
        return false;
      }
    }
    await this._syncDraftOrderStartWithLines(
      this.draftOrderId,
      newYmd,
      currentYmd
    );
    this._toolbarEffectiveDateValue = undefined;
    return true;
  }

  async _autoSaveToolbarOrderStartDateIfApplicable() {
    if (
      !this.isContract ||
      this.activeTab !== "draft" ||
      !this.draftOrderId ||
      this.showInMemoryOrderSection ||
      this._toolbarEffectiveDateValue === undefined
    ) {
      return;
    }
    try {
      const saved = await this._persistToolbarOrderStartDate();
      if (!saved) return;
      await Promise.all([
        refreshApex(this.wiredDraftLineItemsResult),
        refreshApex(this.wiredDraftSummaryResult),
        refreshApex(this.wiredDraftOrderDetailsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
      this.updateContainerButtons();
      this.showToast("Success", "Contract start date updated.", "success");
    } catch (e) {
      this.showToast("Error", this._reduceServerError(e), "error");
    }
  }

  // ─── Sticky draft Save/Cancel footer (viewport-fixed, clamped below Products toolbar) ───

  _stickyDraftFooterActive = false;
  _draftFooterPositionBound = false;
  _draftFooterRafPending = false;
  _boundDraftFooterScroll = null;
  _draftFooterMeasureRetries = 0;
  /** Hysteresis to avoid top/bottom mode flip when toolbar edge is near threshold. */
  _draftFooterClampModeBottom = true;

  _bindDraftFooterPositionListeners() {
    if (this._draftFooterPositionBound) return;
    this._draftFooterPositionBound = true;
    this._boundDraftFooterScroll = () => this._scheduleDraftFooterPosition();
    window.addEventListener("scroll", this._boundDraftFooterScroll, {
      passive: true
    });
    window.addEventListener("resize", this._boundDraftFooterScroll, {
      passive: true
    });
  }

  _unbindDraftFooterPositionListeners() {
    if (!this._draftFooterPositionBound) return;
    this._draftFooterPositionBound = false;
    if (this._boundDraftFooterScroll) {
      window.removeEventListener("scroll", this._boundDraftFooterScroll);
      window.removeEventListener("resize", this._boundDraftFooterScroll);
      this._boundDraftFooterScroll = null;
    }
  }

  _scheduleDraftFooterPosition() {
    if (!this.showStickyDraftFooter) return;
    if (this._draftFooterRafPending) return;
    this._draftFooterRafPending = true;
    // eslint-disable-next-line @lwc/lwc/no-async-operation -- measure footer after layout
    requestAnimationFrame(() => {
      this._draftFooterRafPending = false;
      this._updateDraftFooterPosition();
    });
  }

  _updateDraftFooterPosition() {
    if (!this.showStickyDraftFooter) return;
    const footer = this.template.querySelector("[data-pb-draft-footer]");
    const panel = this.template.querySelector(
      "c-package-builder-products-panel.pb-products-panel-target"
    );
    if (
      !footer ||
      !panel ||
      typeof panel.getProductsToolbarRect !== "function"
    ) {
      return;
    }
    /** Gap above OS taskbar / browser chrome so Save/Cancel stay fully visible and clickable. */
    const viewportBottomInsetPx = 48;
    const HYST_PX = 12;
    const rect = panel.getProductsToolbarRect();
    const toolbarBottom = rect?.bottom ?? 0;
    let fh = footer.getBoundingClientRect().height;
    if (fh < 24 && this._draftFooterMeasureRetries < 8) {
      this._draftFooterMeasureRetries += 1;
      // eslint-disable-next-line @lwc/lwc/no-async-operation -- re-measure footer height after layout
      requestAnimationFrame(() => this._updateDraftFooterPosition());
      return;
    }
    this._draftFooterMeasureRetries = 0;
    if (fh < 24) {
      fh = 56;
    }
    const h = window.innerHeight;
    const naturalTop = h - fh - viewportBottomInsetPx;
    let useBottom;
    if (toolbarBottom <= naturalTop - HYST_PX) {
      useBottom = true;
    } else if (toolbarBottom >= naturalTop + HYST_PX) {
      useBottom = false;
    } else {
      useBottom = this._draftFooterClampModeBottom;
    }
    this._draftFooterClampModeBottom = useBottom;
    if (useBottom) {
      footer.style.bottom = `${viewportBottomInsetPx}px`;
      footer.style.top = "";
    } else {
      footer.style.top = `${toolbarBottom}px`;
      footer.style.bottom = "";
    }
    // In in-memory draft mode, the order section is rendered below products.
    // Avoid inserting the sticky-footer spacer between table and contract details.
    const suppressSpacer =
      this.isContract &&
      this.activeTab === "draft" &&
      this.showInMemoryOrderSection &&
      this.showOrderSection;
    const spacerH = suppressSpacer ? 0 : Math.ceil(fh + viewportBottomInsetPx);
    this.template.querySelectorAll(".pb-draft-footer-spacer").forEach((el) => {
      el.style.height = `${spacerH}px`;
    });
    const host = this.template.host;
    if (host && host.style) {
      host.style.setProperty("--pb-draft-footer-space", `${spacerH}px`);
    }
  }

  _resetDraftFooterDomStyles() {
    const footer = this.template.querySelector("[data-pb-draft-footer]");
    if (footer) {
      footer.style.bottom = "";
      footer.style.top = "";
    }
    this.template.querySelectorAll(".pb-draft-footer-spacer").forEach((el) => {
      el.style.height = "";
    });
    this._draftFooterMeasureRetries = 0;
    this._draftFooterClampModeBottom = true;
    const host = this.template.host;
    if (host && host.style) {
      host.style.removeProperty("--pb-draft-footer-space");
    }
  }

  async handleCancel() {
    this.draftValues = [];
    this._toolbarEffectiveDateValue = undefined;

    if (this.isModifyMode) {
      this.isModifyMode = false;
      this._clearOrderEditingState();
      this.draftProducts = [];
      this.draftSummary = {};
      this.activeTab = "active";
      this.setColumns();
      this.updateContainerButtons();
      return;
    }

    this._restoreCurrentTableFromPristineSnapshot();
    this.setColumns();
    this.updateContainerButtons();
    await this._reloadCurrentTableDataAfterCancel();
  }

  _cloneRows(rows) {
    return (Array.isArray(rows) ? rows : []).map((row) => ({ ...row }));
  }

  _restoreCurrentTableFromPristineSnapshot() {
    if (this.isContract) {
      if (this.activeTab === "draft") {
        this.draftProducts = this._cloneRows(this._pristineDraftProducts);
      } else {
        this.activeProducts = this._cloneRows(this._pristineActiveProducts);
      }
      return;
    }
    this.productsData = this._cloneRows(this._pristineProductsData);
  }

  /**
   * Cancel should immediately restore table cell values (including custom combobox cells)
   * to persisted values, not only clear draftValues.
   */
  async _reloadCurrentTableDataAfterCancel() {
    try {
      if (this.isContract) {
        if (this.activeTab === "draft" && this.draftOrderId) {
          await this._refreshDraftHydrationBundle();
        } else if (this.activeTab === "active") {
          await Promise.all([
            this._refreshApexSafe(this.wiredActiveLineItemsResult),
            this._refreshApexSafe(this.wiredActiveSummaryResult),
            this._refreshMonthlyPaymentKpiWires()
          ]);
        }
      } else {
        await Promise.all([
          this._refreshApexSafe(this.wiredLineItemsResult),
          this._refreshMonthlyPaymentKpiWires()
        ]);
      }
    } catch (e) {
      // Silent fallback: Cancel already cleared local draft state.

      console.warn("[packageBuilder] cancel reload failed", e);
    }
  }

  /**
   * Hides the saved draft from Package Builder (sets Order.Status = Cancelled). Shows confirmation, then clears draft state and refreshes.
   */
  async handleCancelDraftOrder() {
    const confirmed = await packageBuilderConfirmModal.open({
      size: "small",
      title: this.labels.RemoveDraftConfirmTitle,
      message: this.labels.RemoveDraftConfirm,
      confirmLabel: "OK",
      cancelLabel: this.labels.Cancel
    });
    if (!confirmed) return;

    this.cancellingDraft = true;
    this.updateContainerButtons();
    try {
      await cancelDraftOrder({ draftOrderId: this.draftOrderId });
      this.draftOrderId = null;
      this.draftProducts = [];
      this.draftSummary = {};
      this.draftValues = [];
      this._setUnifiedSelectedRows([]);
      // Single-tab (Concluded Terms) UI: switch before refresh so lineItems/KPIs use active order, not empty draft.
      this.activeTab = "active";
      await Promise.all([
        refreshApex(this.wiredOrdersResult),
        refreshApex(this.wiredDraftLineItemsResult),
        refreshApex(this.wiredDraftSummaryResult),
        refreshApex(this.wiredDraftOrderDetailsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
      this.updateContainerButtons();
      this.showToast("Success", this.labels.RemoveDraftSuccess, "success");
    } catch (error) {
      this.showToast(
        "Error",
        this._reduceServerError(error) || "Failed to cancel draft order",
        "error"
      );
    } finally {
      this.cancellingDraft = false;
      this.updateContainerButtons();
    }
  }

  /** Called from the container's Cancel draft order button. */
  @api handleCancelDraftFromContainer() {
    return this.handleCancelDraftOrder();
  }

  async handleSaveChanges() {
    this.savingDraft = true;
    try {
      await this.handleSave({ detail: { draftValues: this.draftValues } });
    } finally {
      this.savingDraft = false;
    }
  }

  // ─── BULK UPDATE / TERMINATE MODALS (Contract toolbar) ─────────────────

  handleBulkEdit() {
    if (this.isContract && this.activeTab === "active") {
      this.showToast(
        "Info",
        "Bulk Edit is available only on Draft tab.",
        "info"
      );
      return;
    }
    this._openBulkUpdateModal("edit");
  }

  handleTerminateProducts() {
    this._openBulkUpdateModal("terminate");
  }

  async handleOpenIterations() {
    const selected = this.selectedRows || [];
    if (!selected.length) {
      this.showToast("Error", "Select at least one product.", "error");
      return;
    }
    const movingOutIds = [];
    const eligible = [];
    for (const id of selected) {
      const row = (this.lineItems || []).find(
        (r) => (r.LineItemId || r.Id) === id
      );
      if (row?.ReplacementIcon === "moving-out") {
        movingOutIds.push(id);
      } else {
        eligible.push(id);
      }
    }
    if (!eligible.length) {
      this.showToast(
        "Error",
        "Iterations are not available for replaced products.",
        "error"
      );
      return;
    }
    if (movingOutIds.length) {
      this.showToast(
        "Info",
        "Replaced products were skipped. Opening Iterations for eligible products only.",
        "info"
      );
    }
    this.iterationLineIds = eligible;
    this.showIterationsModal = true;
  }

  handleCloseIterations() {
    this.showIterationsModal = false;
  }

  async handleIterationsSaved() {
    await this.refreshProductsTable();
  }

  async _openBulkUpdateModal(mode) {
    if (!this.selectedRows?.length) {
      this.showToast(
        "Info",
        "Select at least one product to bulk update.",
        "info"
      );
      return;
    }
    if (
      mode !== "terminate" &&
      this._selectionIncludesTerminatedContractOrderItems(this.selectedRows) &&
      !(this.isContract && this.activeTab === "draft")
    ) {
      this.showToast(
        "Error",
        this.labels.TerminatedProductSelectionBlocked,
        "error"
      );
      return;
    }

    let selectedRowsForMode = [...(this.selectedRows || [])];

    // On Contract Active tab or modify mode with no draft yet, create draft first then map selected rows.
    // Terminate applies EndDate / termination reason on the activated order directly; do not create a draft.
    if (
      this.isContract &&
      mode !== "terminate" &&
      !this.draftOrderId &&
      (this.isModifyMode || this.activeTab === "active")
    ) {
      try {
        if (this.activeTab === "active" && !this.isModifyMode) {
          this.seedInMemoryDraftOrderFromActive();
        }
        await this._persistDraftFromModifyInBackground();
      } catch (e) {
        if (!e.pbSkipDuplicateToast) {
          this.showToast(
            "Error",
            e.body?.message || e.message || "Failed to create draft order",
            "error"
          );
        }
        return;
      }
    }

    const selectedIds = new Set(selectedRowsForMode);
    const hasLockedStartInSelection = (this.lineItems || []).some(
      (row) => selectedIds.has(row.LineItemId) && !!row.OriginalOrderProductId
    );

    const selectedAccessTypes = [];
    const selectedProductEndDates = [];
    const selectedProductEntryDates = [];
    for (const id of selectedRowsForMode) {
      const row = (this.lineItems || []).find((p) => p.LineItemId === id);
      if (!row || this._isContractTermsRow(row)) {
        continue;
      }
      const at = row?.AccessType || row?.Access_Type__c;
      const normAt = this._normalizeAccessTypeForTerminate(at);
      if (normAt) {
        selectedAccessTypes.push(normAt);
      }
      const rowEndDate = row?.EndDate || row?.End_date__c || null;
      selectedProductEndDates.push(rowEndDate);
      const rowEntryDate =
        row?.EntryDate || row?.Entry_Date__c || row?.ServiceDate || null;
      if (rowEntryDate) {
        selectedProductEntryDates.push(rowEntryDate);
      }
    }

    const isFullTerminationSelection = (() => {
      if (mode !== "terminate" || !this.isContract) return false;
      const allRows = Array.isArray(this.lineItems) ? this.lineItems : [];
      const baseRows = allRows.filter(
        (row) => row && !this._isContractTermsRow(row)
      );
      if (baseRows.length === 0) return false;
      const selectedIdSet = new Set(selectedRowsForMode);
      return baseRows.every((row) => {
        const rowId = row.LineItemId || row.Id;
        const hasTerminationReason =
          String(
            row.TerminationReasonLabel || row.Termination_Reason__c || ""
          ).trim() !== "";
        return hasTerminationReason || selectedIdSet.has(rowId);
      });
    })();

    const bulkLineIdsForPayload =
      mode === "edit" && this.isContract
        ? (this.selectedRows || []).filter((id) => {
            const row = (this.lineItems || []).find(
              (p) => (p.LineItemId || p.Id) === id
            );
            return row && !this._isContractTermsRow(row);
          })
        : [...selectedRowsForMode];

    if (
      mode === "edit" &&
      this.isContract &&
      bulkLineIdsForPayload.length === 0
    ) {
      this.showToast(
        "Info",
        "Bulk edit applies only to Rooms and Extra products. Select at least one row outside Contract Terms, or clear Contract Terms selection.",
        "info"
      );
      return;
    }

    const saveCallback = async (result) => {
      try {
        if (mode === "edit" && this.isContract && result?.endDate) {
          const normalizedNewEnd = this._normalizeToYyyyMmDd(result.endDate);
          const todayIso = new Date().toISOString().split("T")[0];
          const activeEndByOriginalId = new Map();
          (this.activeProducts || []).forEach((p) => {
            const aid = this._normalizeRowId(p.LineItemId || p.Id);
            if (aid) {
              activeEndByOriginalId.set(
                aid,
                p.EndDate ?? p.End_date__c ?? null
              );
            }
          });
          const hasEarlierEndThanSelected = (this.selectedRows || []).some(
            (id) => {
              const row = (this.lineItems || []).find(
                (p) => p.LineItemId === id
              );
              if (!row || this._isContractTermsRow(row)) {
                return false;
              }
              if (this._isTerminatedDraftOrderItemRow(row)) {
                return false;
              }
              const origId = this._normalizeRowId(row.OriginalOrderProductId);
              if (origId && activeEndByOriginalId.has(origId)) {
                const activeEndRaw = activeEndByOriginalId.get(origId);
                const normalizedActiveEnd =
                  this._normalizeToYyyyMmDd(activeEndRaw);
                if (
                  normalizedActiveEnd &&
                  normalizedNewEnd &&
                  normalizedNewEnd < normalizedActiveEnd
                ) {
                  return true;
                }
              }
              const existingEnd = row?.EndDate || row?.End_date__c || null;
              const normalizedExistingEnd =
                this._normalizeToYyyyMmDd(existingEnd);
              if (normalizedExistingEnd && normalizedNewEnd) {
                return normalizedNewEnd < normalizedExistingEnd;
              }
              const normalizedAccessType =
                this._normalizeAccessTypeForTerminate(
                  row?.AccessType || row?.Access_Type__c
                );
              if (normalizedAccessType === "Monthly" && normalizedNewEnd) {
                return normalizedNewEnd < todayIso;
              }
              return false;
            }
          );
          if (hasEarlierEndThanSelected) {
            const msg =
              "To set an earlier end date, use the Terminate Products button.";
            this.showToast("Error", msg, "error");
            const err = new Error(msg);
            err.pbSkipModalErrorToast = true;
            throw err;
          }
        }
        let lineItemIdsToUpdate = bulkLineIdsForPayload;
        let terminateSkippedCount = 0;
        if (mode === "terminate" && result?.exitDate) {
          const exitYmd = this._normalizeToYyyyMmDd(result.exitDate);
          const applicableIds = [];
          for (const id of bulkLineIdsForPayload) {
            const row = (this.lineItems || []).find(
              (p) => (p.LineItemId || p.Id) === id
            );
            const productEndYmd = this._normalizeToYyyyMmDd(
              row?.EndDate || row?.End_date__c
            );
            if (shouldApplyTerminateToProduct(productEndYmd, exitYmd)) {
              applicableIds.push(id);
            } else {
              terminateSkippedCount += 1;
            }
          }
          if (applicableIds.length === 0) {
            const msg =
              "No selected products qualify for termination at the chosen exit date. Products that already end before the exit date are skipped.";
            this.showToast("Info", msg, "info");
            const err = new Error(msg);
            err.pbSkipModalErrorToast = true;
            throw err;
          }
          lineItemIdsToUpdate = applicableIds;
        }
        let terminatedBulkFieldsSkipped = false;
        let usageBasedUnitPriceSkippedCount = 0;
        const bulkEditHasUnitPriceUpdate =
          mode === "edit" && this._bulkEditResultHasUnitPriceUpdate(result);
        const lineItemsToUpdate = lineItemIdsToUpdate.map((id) => {
          const row = (this.lineItems || []).find(
            (p) => (p.LineItemId || p.Id) === id
          );
          const isTerminatedDraftLine =
            this._isTerminatedDraftOrderItemRow(row);
          let lineItem = { Id: id, sobjectType: this.sobjectType };

          if (mode === "edit") {
            if (isTerminatedDraftLine) {
              if (result.endDate) {
                lineItem.EndDate = result.endDate;
              }
              if (this._bulkEditResultHasNonEndDateChange(result)) {
                terminatedBulkFieldsSkipped = true;
              }
            } else {
              if (result.accessType)
                lineItem.Access_Type__c = result.accessType;
              if (bulkEditHasUnitPriceUpdate) {
                const effectiveAccessType = this._bulkEditEffectiveAccessType(
                  row,
                  result.accessType
                );
                if (isUsageBased(effectiveAccessType)) {
                  usageBasedUnitPriceSkippedCount += 1;
                } else {
                  lineItem.UnitPrice = result.unitPrice;
                }
              }
              if (this.isOpportunity) {
                if (result.entryDate) lineItem.Entry_Date__c = result.entryDate;
                if (result.endDate) lineItem.End_date__c = result.endDate;
                if (
                  result.accessType &&
                  this._normalizeAccessTypeForTerminate(result.accessType) ===
                    "Monthly" &&
                  !this._lineMustKeepCurtailedEndForReplacement(row)
                ) {
                  lineItem.End_date__c = null;
                }
              } else {
                if (result.entryDate) lineItem.ServiceDate = result.entryDate;
                if (result.endDate) {
                  lineItem.EndDate = result.endDate;
                }
                if (
                  result.accessType &&
                  this._normalizeAccessTypeForTerminate(result.accessType) ===
                    "Monthly" &&
                  !this._lineMustKeepCurtailedEndForReplacement(row)
                ) {
                  lineItem.EndDate = null;
                }
              }
            }
          } else {
            if (this.isOpportunity) {
              if (result.exitDate) lineItem.End_date__c = result.exitDate;
            } else {
              if (result.exitDate) lineItem.EndDate = result.exitDate;
              if (
                result.showExitFields &&
                result.terminationReason &&
                row &&
                !this._isContractTermsRow(row)
              ) {
                lineItem.Termination_Reason__c = result.terminationReason;
              }
            }
          }
          return lineItem;
        });

        if (this._replacementMirrorEligible()) {
          const triggerIds = [];
          if (mode === "edit" && (result.entryDate || result.endDate)) {
            lineItemIdsToUpdate.forEach((lid) => triggerIds.push(lid));
          } else if (mode === "terminate" && result.exitDate) {
            lineItemIdsToUpdate.forEach((lid) => triggerIds.push(lid));
          }
          if (triggerIds.length) {
            this._mergeReplacementMirrorIntoOrderItemList(
              lineItemsToUpdate,
              triggerIds
            );
          }
        }

        const editPayloadKeys = this.isOpportunity
          ? ["Access_Type__c", "UnitPrice", "Entry_Date__c", "End_date__c"]
          : ["Access_Type__c", "UnitPrice", "ServiceDate", "EndDate"];
        const terminatePayloadKeys = this.isOpportunity
          ? ["End_date__c"]
          : ["EndDate", "Termination_Reason__c"];
        const payloadKeys =
          mode === "edit" ? editPayloadKeys : terminatePayloadKeys;

        const itemsWithChanges = lineItemsToUpdate.filter((item) =>
          payloadKeys.some(
            (key) =>
              item[key] !== undefined && item[key] !== null && item[key] !== ""
          )
        );

        if (itemsWithChanges.length === 0) {
          const noUpdatesMessage =
            usageBasedUnitPriceSkippedCount > 0 && bulkEditHasUnitPriceUpdate
              ? "No updates to apply. Usage Based products keep unit price at 0 and were skipped."
              : "No updates to apply. Leave fields empty to keep current values.";
          this.showToast("Info", noUpdatesMessage, "info");
          const err = new Error("No updates to apply.");
          err.pbSkipModalErrorToast = true;
          throw err;
        }

        let parentEndValidationOverride = null;
        const shouldPreExtendParentEnd =
          this.isContract &&
          ((mode === "edit" &&
            this.activeTab === "draft" &&
            this.draftOrderId) ||
            (mode === "terminate" &&
              ((this.activeTab === "draft" && this.draftOrderId) ||
                (this.activeTab === "active" && this.activeOrderId))));
        if (shouldPreExtendParentEnd) {
          try {
            const parentSyncResult =
              await this._autoExtendParentEndDatesBeforeSave(itemsWithChanges, {
                allowActiveOrder:
                  mode === "terminate" && this.activeTab === "active"
              });
            parentEndValidationOverride =
              parentSyncResult?.validationParentEndYmd || null;
          } catch (e) {
            this.showToast(
              "Error",
              this._reduceServerError(e) ||
                "Failed to update contract/order end date.",
              "error"
            );
            const err = new Error("Parent end date sync failed.");
            err.pbSkipModalErrorToast = true;
            throw err;
          }
        }

        if (
          !this.validateDates(itemsWithChanges, {
            bulkTerminate: mode === "terminate",
            parentEndOverride: parentEndValidationOverride
          })
        ) {
          // validateDates already showed the specific error toast — avoid duplicate generic toast in bulkUpdateModal.
          const err = new Error("Date validation failed.");
          err.pbSkipModalErrorToast = true;
          throw err;
        }

        const activePenaltyNum = Number(
          this.activeOrderDetails?.earlyTerminationFee
        );
        const draftPenaltyNum = Number(
          this.draftOrderDetails?.earlyTerminationFee
        );
        const currentOrderPenaltyAmount =
          this.activeTab === "draft"
            ? Number.isFinite(draftPenaltyNum)
              ? draftPenaltyNum
              : 0
            : Number.isFinite(activePenaltyNum)
              ? activePenaltyNum
              : 0;

        const bulkExitContext =
          mode === "terminate" && this.isContract
            ? {
                showExitFields: !!result.showExitFields,
                penaltyAmount: result.penaltyAmount,
                currentPenaltyAmount: currentOrderPenaltyAmount,
                movedTo: result.movedTo || null
              }
            : null;
        const appendMonthlyEndDateNote =
          mode === "edit" &&
          result?.endDate &&
          this._bulkSelectionIncludesMonthlyAccess(result);
        const bulkSuccessToastMessage = terminatedBulkFieldsSkipped
          ? this.labels.TerminatedProductsPartialBulkUpdate
          : appendMonthlyEndDateNote
            ? `${this.labels.AddProductSuccess}\n${this.labels.BulkSaveMonthlyEndDateCleared}`
            : null;
        if (
          mode === "terminate" &&
          this.isContract &&
          this.activeTab === "draft" &&
          this.draftOrderId &&
          result.exitDate
        ) {
          await reconcileContractTermsForCutoff({
            draftOrderId: this.draftOrderId,
            cutoffDate: result.exitDate
          });
        }
        await this.saveProducts(
          itemsWithChanges.map((i) => i.Id),
          itemsWithChanges,
          bulkExitContext,
          {
            suppressSuccessToast: mode === "terminate",
            successToastMessage: bulkSuccessToastMessage || undefined,
            skipPreExtend:
              (mode === "edit" || mode === "terminate") &&
              this.isContract &&
              this.activeTab === "draft" &&
              this.draftOrderId &&
              shouldPreExtendParentEnd
          }
        );
        if (usageBasedUnitPriceSkippedCount > 0) {
          this.showToast(
            "Info",
            `${usageBasedUnitPriceSkippedCount} Usage Based product(s) were skipped — unit price stays at 0.`,
            "info"
          );
        }
        this.draftValues = [];
        if (
          mode === "terminate" &&
          this.isContract &&
          this.activeTab === "draft" &&
          isFullTerminationSelection
        ) {
          await finalizeTerminateAll({
            contractId: this.recordId,
            draftOrderId: this.draftOrderId,
            terminationReason: result.terminationReason || null,
            exitDate: result.exitDate || null
          });
        }
        if (mode === "terminate" && this.isContract) {
          await Promise.all([
            this._refreshApexSafe(this.wiredOrdersResult),
            this._refreshApexSafe(this.wiredContractDatesResult),
            this._refreshApexSafe(this.wiredActiveOrderDetailsResult),
            this._refreshMonthlyPaymentKpiWires()
          ]);
          this.updateContainerButtons();
          if (terminateSkippedCount > 0) {
            this.showToast(
              "Info",
              `${terminateSkippedCount} product(s) were skipped because their end date is before the selected exit date.`,
              "info"
            );
          }
          this.showToast(
            "Success",
            "The products were updated successfully",
            "success"
          );
        }
      } catch (e) {
        this.draftValues = [];
        if (e?.pbSkipModalErrorToast) {
          throw e;
        }
        const msg =
          this._reduceServerError(e) ||
          e?.body?.message ||
          e?.message ||
          "Save failed.";
        // Ensure the modal always has a meaningful message to show.
        throw new Error(msg);
      }
    };

    const modalParams = {
      size: "small",
      mode,
      accessTypeOptions: this._buildBulkAccessTypeOptions(
        bulkLineIdsForPayload
      ),
      isContractContext: this.isContract,
      isOpportunityContext: this.isOpportunity,
      selectionIncludesLockedStart: hasLockedStartInSelection,
      startDateLockedMessage: this.startDateLockedMessage,
      saveCallback
    };
    if (this.isContract) {
      const notice =
        this.draftOrderDetails?.noticePeriodMonths ??
        this.activeOrderDetails?.noticePeriodMonths ??
        null;
      const activeOrderStartDate = this._normalizeToYyyyMmDd(
        this.activeOrderDetails?.effectiveDate
      );
      const draftOrderStartDate = this._normalizeToYyyyMmDd(
        this.draftOrderDetails?.effectiveDate
      );
      const movedToDefault =
        this.draftOrderDetails?.movedTo ??
        this.activeOrderDetails?.movedTo ??
        null;
      const activePenaltyNum = Number(
        this.activeOrderDetails?.earlyTerminationFee
      );
      const draftPenaltyNum = Number(
        this.draftOrderDetails?.earlyTerminationFee
      );
      modalParams.currentPenaltyAmount =
        this.activeTab === "draft"
          ? Number.isFinite(draftPenaltyNum)
            ? draftPenaltyNum
            : 0
          : Number.isFinite(activePenaltyNum)
            ? activePenaltyNum
            : 0;
      modalParams.orderStartDate =
        this.activeTab === "draft"
          ? draftOrderStartDate || null
          : activeOrderStartDate || null;
      modalParams.contractEndDate = this.contractEndDate || null;
      modalParams.noticeMonths = notice;
      modalParams.selectedAccessTypes = selectedAccessTypes;
      modalParams.selectedProductEndDates = selectedProductEndDates;
      modalParams.selectedProductEntryDates = selectedProductEntryDates;
      modalParams.exitDateMaxYmd =
        mode === "terminate"
          ? maxSelectedProductEndDateYmd(selectedProductEndDates)
          : null;
      modalParams.showMovedToField = isFullTerminationSelection;
      modalParams.movedToDefault = movedToDefault;
    }

    await bulkUpdateModal.open(modalParams);
  }

  // ─── COMMON SAVE ──────────────────────────────────────────

  async saveProducts(
    lineItemIds,
    lineItemsToUpdate,
    bulkExitContext = null,
    options = {}
  ) {
    let result;
    const suppressSuccessToast = options?.suppressSuccessToast === true;
    const skipPreExtend = options?.skipPreExtend === true;
    if (!skipPreExtend) {
      try {
        await this._autoExtendParentEndDatesBeforeSave(lineItemsToUpdate);
      } catch (parentSyncError) {
        const msg =
          this._reduceServerError(parentSyncError) ||
          "Failed to update contract/order end date.";
        this.showToast("Error", msg, "error");
        throw parentSyncError;
      }
    }
    try {
      result = await saveLineItems({
        recordTypeName: this.oppRecordTypeName,
        itemIds: lineItemIds,
        lineItems: lineItemsToUpdate
      });
    } catch (error) {
      const message = this._reduceServerError(error);
      this.showToast("Error", message, "error");
      console.error("Error updating LineItems:", error);
      throw error;
    }

    if (result.hasErrors) {
      this.showToast("Error", this.labels.Error, "error");
      throw new Error(this.labels.Error);
    }

    const penaltyOrderId =
      this.isContract && (this.draftOrderId || this.activeOrderId)
        ? this.draftOrderId || this.activeOrderId
        : null;
    const shouldUpdatePenalty = false;
    const shouldUpdateMovedTo = !!bulkExitContext?.movedTo;
    if (penaltyOrderId && (shouldUpdatePenalty || shouldUpdateMovedTo)) {
      try {
        const orderFields = { Id: penaltyOrderId };
        if (shouldUpdatePenalty) {
          orderFields.Early_Termination_Fee__c =
            (Number.isFinite(Number(bulkExitContext.currentPenaltyAmount))
              ? Number(bulkExitContext.currentPenaltyAmount)
              : 0) + Number(bulkExitContext.penaltyAmount);
        }
        if (shouldUpdateMovedTo) {
          orderFields.Moved_To__c = bulkExitContext.movedTo;
        }
        await updateRecord({
          fields: orderFields
        });
      } catch (orderUpdateErr) {
        const msg =
          orderUpdateErr.body?.message ||
          orderUpdateErr.message ||
          this.labels.Error;
        this.showToast("Error", msg, "error");
        console.error("Order terminate updates failed:", orderUpdateErr);
        throw orderUpdateErr;
      }
    }

    if (!suppressSuccessToast) {
      const successMsg =
        options.successToastMessage || this.labels.AddProductSuccess;
      this.showToast("Success", successMsg, "success");
    }
    this.draftValues = [];
    if (this.isContract) {
      await Promise.all([
        refreshApex(this.wiredContractDatesResult),
        refreshApex(this.wiredActiveLineItemsResult),
        refreshApex(this.wiredDraftLineItemsResult),
        refreshApex(this.wiredActiveSummaryResult),
        refreshApex(this.wiredDraftSummaryResult),
        refreshApex(this.wiredDraftOrderDetailsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
    } else {
      await Promise.all([
        refreshApex(this.wiredLineItemsResult),
        this._refreshMonthlyPaymentKpiWires()
      ]);
    }
  }

  // ─── ADD PRODUCT (dispatches to container) ────────────────

  /**
   * When user clicks Add Product on Draft tab before a draft order Id exists, persist the draft first
   * then open the Add Product modal with the new draft order Id.
   */
  async handleAddProduct() {
    if (this.isContract && this.activeTab === "active") {
      this.showToast(
        "Error",
        "This order is Activated, so Order Products cannot be added or removed. Please move the order to Draft or use the change process.",
        "error"
      );
      return;
    }

    if (this.isContract && this.activeTab === "draft" && !this.draftOrderId) {
      try {
        this.seedInMemoryDraftOrderFromActive();
        await this._ensurePersistedDraftFromStagedOrderStart();
        this.dispatchEvent(
          new CustomEvent("addproduct", {
            detail: {
              orderId: this.draftOrderId,
              ...this._getOrderDateBoundsForAddProductModal()
            },
            bubbles: true,
            composed: true
          })
        );
        return;
      } catch (e) {
        if (!e.pbSkipDuplicateToast) {
          this.showToast(
            "Error",
            e.body?.message || e.message || "Failed to create draft order",
            "error"
          );
        }
        return;
      }
    }

    this.dispatchEvent(
      new CustomEvent("addproduct", {
        detail: {
          orderId: this.currentOrderId,
          ...this._getOrderDateBoundsForAddProductModal()
        },
        bubbles: true,
        composed: true
      })
    );
  }

  /**
   * Open Monthly payments editor modal from the toolbar.
   * For Contract context we pass the current order Id; for Opportunity we let the container
   * use the recordId so monthlyPaymentTable can resolve the correct apex query.
   */
  _buildSelectedLineItemMetaForMonthlyPayments(selectedLineItemIds) {
    const rows = this.lineItems || [];
    return (selectedLineItemIds || []).map((id) => {
      const row = this._findLineItemRowById(rows, id);
      const accessType = row?.AccessType || row?.Access_Type__c || "";
      return {
        id,
        displayName: row?.Name || String(id),
        deskcount: Number(row?.Quantity ?? row?.DeskCount ?? 0) || 0,
        unitPrice: Number(row?.UnitPrice ?? 0) || 0,
        totalPrice: Number(row?.TotalPrice ?? 0) || 0,
        accessType,
        productType: row?.ProductsType || row?.ProductTypeName || "",
        rentEligible: row?.RentEligible === true
      };
    });
  }

  _maxEndDateYmdForRows(selectedLineItemIds) {
    const rows = this.lineItems || [];
    let maxEnd = null;
    (selectedLineItemIds || []).forEach((id) => {
      const row = this._findLineItemRowById(rows, id);
      const endYmd = this._formatRowEndDateYmd(row);
      if (endYmd && (!maxEnd || endYmd > maxEnd)) {
        maxEnd = endYmd;
      }
    });
    return maxEnd;
  }

  handleOpenMonthlyPayments() {
    const selectedLineItemIds = [
      ...new Set((this.selectedRows || []).filter((id) => !!id))
    ];
    if (!selectedLineItemIds.length) {
      return;
    }
    const orderId = this.isContract
      ? this.currentOrderId || this.activeOrderId
      : null;
    const contractStart = this._dealStartDateYmdForMonthlyPayments();
    const detail = {
      orderId,
      tabName: this.isContract ? this.activeTab : null,
      selectedLineItemIds,
      selectedLineItemMeta:
        this._buildSelectedLineItemMetaForMonthlyPayments(selectedLineItemIds),
      readOnly: this.isMonthlyPaymentsReadOnly,
      concludedTermsActiveTab: this.isContract && this.activeTab === "active",
      priceChangeMode: false,
      contractStartDateYmd: contractStart,
      contractEndDateYmd:
        this._maxEndDateYmdForRows(selectedLineItemIds) || null
    };

    this.dispatchEvent(
      new CustomEvent("openmonthlypaymentsdrawer", {
        detail,
        bubbles: true,
        composed: true
      })
    );
  }

  async handleReplace() {
    if (this.isReplaceDisabled || this.selectedRows.length !== 1) return;
    const selectedId = this.selectedRows[0];
    const replacedRow = (this.lineItems || []).find(
      (r) => (r.LineItemId || r.Id) === selectedId
    );
    const replacedRowForBounds =
      this._rowForReplaceModalDateBounds(replacedRow);
    // Draft row end (incl. unsaved grid edits): Period Start max and Period End default in replace modal.
    const replacedProductEndDate =
      this._formatRowEndDateYmd(replacedRowForBounds);
    const activeEndYmd = this._draftBackwardEndBaselineYmd(replacedRow);
    // Period End min + validation floor: activated end, except terminated draft shortened below active.
    const replacedActiveEndDateYmd = replaceModalPeriodEndFloorYmd({
      isTerminatedDraftRow: this._isTerminatedDraftOrderItemRow(replacedRow),
      draftEndYmd: replacedProductEndDate,
      activeEndYmd
    });
    const replacedPricebookEntryId =
      replacedRow?.PricebookEntryId || replacedRow?.pricebookEntryId || null;
    const isExtraCreditReplace = this._isContractTermsRow(replacedRow) === true;

    const openContractTermReplaceSheet = (orderId, replacedOrderItemId) => {
      if (!replacedPricebookEntryId) {
        this.showToast(
          "Error",
          "Missing pricebook entry for this line.",
          "error"
        );
        return;
      }
      const bounds = this._getOrderDateBoundsForAddProductModal();
      const oid = orderId ? String(orderId) : "";
      const detailsForTargetOrder =
        oid && this.draftOrderId && oid === String(this.draftOrderId)
          ? this.draftOrderDetails
          : oid && this.activeOrderId && oid === String(this.activeOrderId)
            ? this.activeOrderDetails
            : oid && this.currentOrderId && oid === String(this.currentOrderId)
              ? this.activeTab === "draft"
                ? this.draftOrderDetails
                : this.activeOrderDetails
              : null;
      // Min / validation floor: strict Order_Start_Date__c from order details (orderStartDateOnly).
      const startFromOrderStartField =
        this._orderStartDateYmdFromDetails(detailsForTargetOrder) || null;
      // Default entry: max(contract commercial start per toolbar/draft/active, replaced line entry/original start).
      const defaultEntryDateYmd =
        this._maxYmd(
          this._contractCommercialStartYmdForReplaceModal(),
          this._replacedLineCommercialStartMaxYmd(replacedRow)
        ) ||
        startFromOrderStartField ||
        null;
      const defaultQty = Number(replacedRow?.Quantity);
      this.dispatchEvent(
        new CustomEvent("opencontracttermreplace", {
          detail: {
            orderId,
            replacedOrderItemId,
            replacedPricebookEntryId,
            orderStartDate: startFromOrderStartField,
            orderEndDate: bounds.orderEndDate || null,
            defaultEntryDateYmd,
            defaultCpiDateYmd:
              this._normalizeToYyyyMmDd(replacedRow?.CpiDate) || null,
            defaultQuantity: Number.isFinite(defaultQty) ? defaultQty : 1
          },
          bubbles: true,
          composed: true
        })
      );
    };

    if (this.isContract && this.activeTab === "draft" && !this.draftOrderId) {
      try {
        this.seedInMemoryDraftOrderFromActive();
        const { idMapping } = await this._persistDraftFromModifyInBackground();
        const replacedOrderItemId = idMapping[selectedId] || selectedId;
        if (isExtraCreditReplace) {
          openContractTermReplaceSheet(this.draftOrderId, replacedOrderItemId);
        } else {
          this.dispatchEvent(
            new CustomEvent("addproduct", {
              detail: {
                orderId: this.draftOrderId,
                replaceMode: true,
                replacedOrderItemId,
                replacedProductEndDate,
                replacedActiveEndDateYmd,
                replacedPricebookEntryId,
                ...this._getReplaceAddProductModalDateProps(replacedRow)
              },
              bubbles: true,
              composed: true
            })
          );
        }
      } catch (e) {
        if (!e.pbSkipDuplicateToast) {
          this.showToast(
            "Error",
            e.body?.message || e.message || "Failed to create draft order",
            "error"
          );
        }
      }
      return;
    }

    if (isExtraCreditReplace) {
      openContractTermReplaceSheet(this.currentOrderId, selectedId);
      return;
    }

    this.dispatchEvent(
      new CustomEvent("addproduct", {
        detail: {
          orderId: this.currentOrderId,
          replaceMode: true,
          replacedOrderItemId: selectedId,
          replacedProductEndDate,
          replacedActiveEndDateYmd,
          replacedPricebookEntryId,
          ...this._getReplaceAddProductModalDateProps(replacedRow)
        },
        bubbles: true,
        composed: true
      })
    );
  }

  // ─── VALIDATION ───────────────────────────────────────────

  /** Format date for error messages (YYYY-MM-DD). */
  formatDateForMessage(d) {
    if (!d) return "";
    const date = typeof d === "string" ? new Date(d) : d;
    return date.toISOString ? date.toISOString().split("T")[0] : String(d);
  }

  /**
   * Order Customer Package Start / End as YYYY-MM-DD for the Add Product modal (Contract context).
   * Ensures period defaults and min date match staged draft / active order, not only the wired Order record.
   */
  _getOrderDateBoundsForAddProductModal() {
    const out = {};
    if (!this.isContract) {
      return out;
    }
    let start = null;
    let end = null;
    const contractEndYmd = this._normalizeToYyyyMmDd(this.contractEndDate);
    if (
      this.activeTab === "draft" &&
      this.showInMemoryOrderSection &&
      this.inMemoryDraftOrder
    ) {
      start = this._normalizeToYyyyMmDd(this.inMemoryDraftOrder.effectiveDate);
      end =
        contractEndYmd ||
        this._normalizeToYyyyMmDd(this.inMemoryDraftOrder.endDate);
    } else if (this.activeTab === "draft" && this.draftOrderDetails) {
      start = this._normalizeToYyyyMmDd(this.draftOrderDetails.effectiveDate);
      end =
        contractEndYmd ||
        this._normalizeToYyyyMmDd(this.draftOrderDetails.endDate);
    } else if (this.activeTab === "active" && this.activeOrderDetails) {
      start = this._normalizeToYyyyMmDd(this.activeOrderDetails.effectiveDate);
      end =
        contractEndYmd ||
        this._normalizeToYyyyMmDd(this.activeOrderDetails.endDate);
    }
    if (start) {
      out.orderStartDate = start;
    }
    if (end) {
      out.orderEndDate = end;
    }
    return out;
  }

  /**
   * Replace-product sheet: toolbar-aware order start, period-end bounds, and max(contract start, line start) default.
   */
  _getReplaceAddProductModalDateProps(row) {
    const bounds = this._getOrderDateBoundsForAddProductModal();
    if (!this.isContract) {
      return {
        orderStartDate: bounds.orderStartDate || null,
        orderEndDate: bounds.orderEndDate || null,
        replaceDefaultPeriodStartYmd: null
      };
    }
    const contractYmd = this._contractCommercialStartYmdForReplaceModal();
    const lineYmd = this._replacedLineCommercialStartMaxYmd(row);
    const replaceDefaultPeriodStartYmd =
      this._maxYmd(contractYmd, lineYmd) || contractYmd || lineYmd || null;
    const orderStartDate = contractYmd || bounds.orderStartDate || null;
    return {
      orderStartDate,
      orderEndDate: bounds.orderEndDate || null,
      replaceDefaultPeriodStartYmd
    };
  }

  _asDeleteOnlyActionColumns(cols) {
    if (!Array.isArray(cols)) return cols;
    return cols.map((col) => {
      if (col?.type !== "dualActionWithTooltip") return col;
      return {
        ...col,
        typeAttributes: {
          ...(col.typeAttributes || {}),
          leftHidden: true,
          leftDisabled: true
        },
        /* One visible 2rem icon + gap + cell padding; 50px was too tight and overlapped the status column. */
        fixedWidth: 64
      };
    });
  }

  /** YYYY-MM-DD for Add Product modal (replace mode period end), or undefined if blank. */
  _formatRowEndDateYmd(row) {
    if (!row) return undefined;
    // Contract payloads can vary by Apex query/alias; tolerate common keys.
    const raw = this.isOpportunity
      ? row.End_date__c || row.End_Date__c || row.EndDate || row.EndDate__c
      : row.EndDate || row.End_date__c || row.End_Date__c || row.EndDate__c;
    if (raw == null || raw === "") return undefined;
    // Salesforce sometimes returns dates as { year, month, day }
    if (typeof raw === "object" && raw.year != null) {
      return `${raw.year}-${String(raw.month).padStart(2, "0")}-${String(raw.day).padStart(2, "0")}`;
    }
    if (typeof raw === "string" && /^\d{4}-\d{2}-\d{2}/.test(raw)) {
      return raw.slice(0, 10);
    }
    const d = raw instanceof Date ? raw : new Date(raw);
    if (Number.isNaN(d.getTime())) return undefined;
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth() + 1).padStart(2, "0");
    const day = String(d.getUTCDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  /** Bounded max line end for auto-extending Contract / Order EndDate on draft save. */
  _computeDraftBoundedMaxEndFromCurrentAndChanges(lineItemsToUpdate = []) {
    return computeBoundedMaxEndFromRowsAndChanges(
      this.lineItems,
      lineItemsToUpdate,
      this.isOpportunity
    );
  }

  async _autoExtendParentEndDatesBeforeSave(
    lineItemsToUpdate = [],
    options = {}
  ) {
    const allowActiveOrder = options.allowActiveOrder === true;

    if (this.isContract && this.activeTab === "draft" && this.draftOrderId) {
      // Server-side reconcileDraftOrderEndBeforeLineItemSave curtails soft-deleted
      // lines and extends Order/Contract end before line DML. Client updateRecord here
      // fails when deleted lines still extend past the target (platform parent/child rule).
    } else if (
      allowActiveOrder &&
      this.isContract &&
      this.activeTab === "active" &&
      this.activeOrderId
    ) {
      // Active-order terminate uses the same Apex pre-save reconcile path.
    } else {
      return { targetEndYmd: null, validationParentEndYmd: null };
    }

    const { targetEndYmd } =
      this._computeDraftBoundedMaxEndFromCurrentAndChanges(lineItemsToUpdate);
    return {
      targetEndYmd,
      validationParentEndYmd: targetEndYmd || null
    };
  }

  _canAutoExtendContractParentEndValidation(
    item,
    bulkTerminate,
    originalRecord,
    options = {}
  ) {
    if (!(this.isContract && this.activeTab === "draft" && this.draftOrderId)) {
      return false;
    }
    const parentEndOverride = this._normalizeToYyyyMmDd(
      options.parentEndOverride
    );
    const proposedEndYmd = this._normalizeToYyyyMmDd(
      this._effectiveEndDateForValidation(item, originalRecord)
    );
    if (!proposedEndYmd) {
      return false;
    }
    if (parentEndOverride && proposedEndYmd <= parentEndOverride) {
      return true;
    }
    if (bulkTerminate) {
      return false;
    }
    const contractEndYmd = this._normalizeToYyyyMmDd(this.contractEndDate);
    const orderEndYmd = this._normalizeToYyyyMmDd(
      this.draftOrderDetails?.endDate
    );
    if (
      hasExtensionBeyondContractEnd(
        [item],
        contractEndYmd,
        this.isOpportunity
      ) ||
      hasExtensionBeyondOrderEnd([item], orderEndYmd, this.isOpportunity)
    ) {
      return true;
    }
    const parentEndYmd = this._normalizeToYyyyMmDd(
      originalRecord?.ParentEndDate
    );
    return !!(parentEndYmd && proposedEndYmd > parentEndYmd);
  }

  /**
   * Validates line item dates. For Contract context uses contract start/end and shows
   * product entry/end date errors; otherwise uses parent (Order/Opp) dates.
   */
  /**
   * @param {Array} lineItems
   * @param {{ bulkTerminate?: boolean }} [options] — bulk terminate may shorten EndDate and should not run replace-pair rules meant for inline edits.
   */
  /**
   * End date shown in validation: if the save payload explicitly includes EndDate / End_date__c
   * (including null / "" to clear), use that value — do not fall back to the wire row, or a cleared
   * cell still looks like the old date and Periodic checks fire incorrectly.
   */
  _effectiveEndDateForValidation(item, originalRecord) {
    if (this.isOpportunity) {
      if (Object.prototype.hasOwnProperty.call(item, "End_date__c")) {
        const v = item.End_date__c;
        return v == null || v === "" ? null : v;
      }
      if (Object.prototype.hasOwnProperty.call(item, "EndDate")) {
        const v2 = item.EndDate;
        return v2 == null || v2 === "" ? null : v2;
      }
    } else if (Object.prototype.hasOwnProperty.call(item, "EndDate")) {
      const v = item.EndDate;
      return v == null || v === "" ? null : v;
    }
    return originalRecord ? originalRecord.EndDate : null;
  }

  validateDates(lineItems, options = {}) {
    const bulkTerminate = options.bulkTerminate === true;
    const parentEndOverride = this._normalizeToYyyyMmDd(
      options.parentEndOverride
    );
    const data = this.lineItems;
    const orderStartForNewProductEntry =
      this._getOrderStartDateForNewProductEntryValidation();
    const contractEnd = this.isContract
      ? parentEndOverride || this.contractEndDate
      : null;
    const draftOrderEndForValidation =
      this.isContract && this.activeTab === "draft"
        ? this.draftOrderDetails?.endDate
        : null;

    const replacementParentIdsInBatch = new Set();
    if (Array.isArray(lineItems)) {
      for (const row of lineItems) {
        const rid = this._normalizeRowId(row?.Id ?? row?.LineItemId);
        const full =
          rid && Array.isArray(data)
            ? this._findLineItemRowById(data, rid)
            : null;
        const repParent =
          row?.ReplacedOrderProductId ??
          row?.Replaced_Order_Product__c ??
          full?.ReplacedOrderProductId ??
          full?.replacedOrderProductId;
        const n = this._normalizeRowId(repParent);
        if (n) {
          replacementParentIdsInBatch.add(n);
        }
      }
    }

    for (let item of lineItems) {
      const originalRecord = this._findLineItemRowById(
        data,
        item.Id ?? item.LineItemId
      );

      let entryDateVal, endDateVal, parentStart, parentEnd;
      const isNewOrReplacementDraft =
        this._isNewOrReplacementDraftProductRow(originalRecord);

      if (this.isOpportunity) {
        entryDateVal =
          item.Entry_Date__c ||
          (originalRecord ? originalRecord.EntryDate : null);
        endDateVal = this._effectiveEndDateForValidation(item, originalRecord);
        parentStart = originalRecord ? originalRecord.ParentStartDate : null;
        parentEnd = originalRecord ? originalRecord.ParentEndDate : null;
      } else {
        entryDateVal =
          item.ServiceDate ||
          (originalRecord
            ? (originalRecord.EntryDate ?? originalRecord.ServiceDate)
            : null);
        endDateVal = this._effectiveEndDateForValidation(item, originalRecord);
        parentStart =
          orderStartForNewProductEntry != null
            ? orderStartForNewProductEntry
            : originalRecord
              ? originalRecord.ParentStartDate
              : null;
        parentEnd =
          contractEnd != null
            ? contractEnd
            : draftOrderEndForValidation != null
              ? draftOrderEndForValidation
              : originalRecord
                ? originalRecord.ParentEndDate
                : null;
      }

      // Contract-only rule (LWC-side): do not shorten below the activated line's end (or below
      // last persisted draft end when activated has no end) without Terminate — not bulk terminate.
      if (
        !bulkTerminate &&
        this.isContract &&
        originalRecord &&
        Object.prototype.hasOwnProperty.call(item, "EndDate") &&
        !this._isEffectiveNewProductRow(originalRecord) &&
        !this._isTerminatedDraftOrderItemRow(originalRecord) &&
        !replacementParentIdsInBatch.has(
          this._normalizeRowId(item.Id ?? item.LineItemId)
        )
      ) {
        const updatedEndYmd = this._normalizeToYyyyMmDd(item.EndDate);
        const baselineFromActive =
          this._draftBackwardEndBaselineYmd(originalRecord);
        const baselineYmd =
          baselineFromActive ??
          this._normalizeToYyyyMmDd(originalRecord.EndDate);
        if (baselineYmd && updatedEndYmd && updatedEndYmd < baselineYmd) {
          if (baselineFromActive) {
            this.showToast(
              this.labels.EndDateBeforeActivatedTitle,
              this.labels.EndDateBeforeActivatedBody,
              "error"
            );
          } else {
            this.showToast(
              "Error",
              "End date may move forward. To move backward use terminate product button.",
              "error"
            );
          }
          return false;
        }
      }

      // Terminated draft: extend End Date inline; shorten only via Terminate Products (or admin override).
      if (
        !bulkTerminate &&
        this.isContract &&
        originalRecord &&
        Object.prototype.hasOwnProperty.call(item, "EndDate")
      ) {
        const updatedEndYmd = this._normalizeToYyyyMmDd(item.EndDate);
        if (
          !this._isClearingTerminationReasonOnDraftItem(item, originalRecord) &&
          this._terminationReasonBlocksEndDateClear(
            originalRecord,
            updatedEndYmd
          )
        ) {
          this._showTerminationReasonBlocksEndDateClearToast();
          return false;
        }
        if (
          this._isTerminatedDraftOrderItemRow(originalRecord) &&
          this._terminatedEndDateShortenBlocked(originalRecord, updatedEndYmd)
        ) {
          this._showTerminatedEndDateShortenBlockedToast();
          return false;
        }
      }

      if (entryDateVal && endDateVal) {
        if (new Date(entryDateVal) > new Date(endDateVal)) {
          this.showToast(
            "Error",
            "Start Date cannot be after End Date.",
            "error"
          );
          return false;
        }
      }

      const accessTypeVal =
        item.Access_Type__c ??
        item.AccessType ??
        originalRecord?.AccessType ??
        originalRecord?.Access_Type__c ??
        "";
      // Un-terminating a contract line clears Termination_Reason__c + EndDate together; skip the
      // Periodic-requires-EndDate gate so the user can restore the row without re-entering the end date.
      const isTerminationReasonCleared =
        !bulkTerminate &&
        Object.prototype.hasOwnProperty.call(item, "Termination_Reason__c") &&
        !item.Termination_Reason__c;
      if (
        this._isPeriodicAccessTypeValue(accessTypeVal) &&
        !endDateVal &&
        !isTerminationReasonCleared
      ) {
        this._refreshEntryDateClockIcons();
        this.showToast("Error", endDateRequiredMessage(accessTypeVal), "error");
        return false;
      }

      if (
        parentStart &&
        entryDateVal &&
        new Date(entryDateVal) < new Date(parentStart) &&
        (!this.isContract || isNewOrReplacementDraft)
      ) {
        const msg = this.isContract
          ? this._productStartBeforeContractStartDateMessage(parentStart)
          : `Product start date can't be earlier than opportunity start date (${this.formatDateForMessage(parentStart)}).`;
        this.showToast("Error", msg, "error");
        return false;
      }

      const endYmd = this._normalizeToYyyyMmDd(endDateVal);
      const parentEndYmd = this._normalizeToYyyyMmDd(parentEnd);
      if (parentEndYmd && endYmd && endYmd > parentEndYmd) {
        if (
          this._canAutoExtendContractParentEndValidation(
            item,
            bulkTerminate,
            originalRecord,
            { parentEndOverride }
          )
        ) {
          continue;
        }
        const msg = this.isContract
          ? `Product end date can't be later than contract end date (${this.formatDateForMessage(parentEnd)}).`
          : this.isOpportunity
            ? `End Date cannot be after the Opportunity End Date (${this.formatDateForMessage(parentEnd)}).`
            : `End Date cannot be after the Order End Date (${this.formatDateForMessage(parentEnd)}).`;
        this.showToast("Error", msg, "error");
        return false;
      }
    }

    // Replacement pair validation (Contract): new product start date cannot be less than old product end date, and vice versa
    if (!bulkTerminate && this.isContract && data && data.length > 0) {
      for (const item of lineItems) {
        const originalRecord = this._findLineItemRowById(
          data,
          item.Id ?? item.LineItemId
        );
        if (!originalRecord) continue;

        const replacementStart = this.isOpportunity
          ? item.Entry_Date__c
          : item.ServiceDate;
        const replacementStartVal =
          replacementStart ||
          (originalRecord
            ? (originalRecord.EntryDate ?? originalRecord.ServiceDate)
            : null);
        const replacedEndVal = this._effectiveEndDateForValidation(
          item,
          originalRecord
        );

        if (originalRecord.ReplacedOrderProductId) {
          // This row is the replacement: its start must be >= replaced row's end
          const repParentId = originalRecord.ReplacedOrderProductId;
          const replacedRow = this._findLineItemRowById(data, repParentId);
          const replacedPayload = lineItems.find(
            (l) =>
              this._normalizeRowId(l.Id ?? l.LineItemId) ===
              this._normalizeRowId(repParentId)
          );
          const replacedEndDate = this.isOpportunity
            ? replacedPayload?.End_date__c || replacedRow?.EndDate
            : replacedPayload?.EndDate || replacedRow?.EndDate;
          const rsY = this._normalizeToYyyyMmDd(replacementStartVal);
          const reY = this._normalizeToYyyyMmDd(replacedEndDate);
          if (rsY && reY && rsY < reY) {
            this.showToast(
              "Error",
              "Replacement product start date must be the calendar day after the replaced product end date.",
              "error"
            );
            return false;
          }
        } else {
          // Replaced row: another line is its replacement. Allow a transient breach when draft
          // mirroring will set replacement start to replaced end + 1 calendar day on save.
          const replacedKey = originalRecord.LineItemId || originalRecord.Id;
          const replacementRow =
            this._findDirectReplacementForReplacedId(replacedKey);
          if (replacementRow) {
            const replKey = replacementRow.LineItemId || replacementRow.Id;
            const replPayload = lineItems.find(
              (l) =>
                this._normalizeRowId(l.Id ?? l.LineItemId) ===
                this._normalizeRowId(replKey)
            );
            const replStart = this.isOpportunity
              ? replPayload?.Entry_Date__c
              : replPayload?.ServiceDate;
            const replStartVal =
              replStart ??
              replacementRow.EntryDate ??
              replacementRow.ServiceDate;
            const reY = this._normalizeToYyyyMmDd(replacedEndVal);
            const rsY = this._normalizeToYyyyMmDd(replStartVal);
            if (reY && rsY && reY > rsY) {
              const willMirrorStart =
                this._replacementMirrorEligible() &&
                !this._replacementMirrorPeerBlocked(replacementRow) &&
                addCalendarDaysYmd(reY, 1);
              if (!willMirrorStart) {
                this.showToast(
                  "Error",
                  "Replaced product end date must be the calendar day before the replacement product start date.",
                  "error"
                );
                return false;
              }
            }
          }
        }
      }
    }
    return true;
  }

  /**
   * Validates that draft order is ready for activation: all products have required fields
   * (Access Type, Entry Date, End Date, Quantity — 0 allowed) and dates are within contract range.
   * Uses current draft values (unsaved edits) if present.
   * Returns { valid: boolean, message?: string }.
   */
  validateDraftForActivation() {
    const orderStartValidationMsg =
      this._validateOrderStartAgainstContractStart(
        this._getDraftOrderStartDateForValidation()
      );
    if (orderStartValidationMsg) {
      return { valid: false, message: orderStartValidationMsg };
    }

    const products = this.draftProducts || [];
    if (products.length === 0) {
      return {
        valid: false,
        message: "Add at least one product before signing."
      };
    }

    const draftMap = new Map();
    (this.draftValues || []).forEach((d) => {
      const id = d.LineItemId || d.Id;
      const nk = this._normalizeRowId(id);
      if (nk) {
        draftMap.set(nk, d);
      }
    });

    const orderStartFloor =
      this._getOrderStartDateForNewProductEntryValidation();
    const contractEnd = this.contractEndDate;

    for (let i = 0; i < products.length; i++) {
      const p = products[i];
      const rowNk = this._normalizeRowId(p.LineItemId || p.Id);
      const draft = rowNk ? draftMap.get(rowNk) : null;
      const entry = this.isContract
        ? draft?.EntryDate !== undefined
          ? draft.EntryDate
          : (p.EntryDate ?? p.ServiceDate)
        : draft?.EntryDate !== undefined
          ? draft.EntryDate
          : p.EntryDate;
      const end = draft?.EndDate !== undefined ? draft.EndDate : p.EndDate;
      const accessType =
        (draft?.AccessType !== undefined ? draft.AccessType : p.AccessType) ||
        "";
      const accessTypeNorm = (accessType + "").trim();
      const isExtraMeter = this._isContractTermsRow(p);
      let isMonthly = accessTypeNorm.toLowerCase() === "monthly";
      if (isExtraMeter && !accessTypeNorm) {
        isMonthly = true;
      }
      const qty = draft?.Quantity !== undefined ? draft.Quantity : p.Quantity;

      if (!isExtraMeter && !accessTypeNorm) {
        return {
          valid: false,
          message: `Product "${p.Name || "Row " + (i + 1)}" must have Access Type.`
        };
      }
      if (!entry) {
        return {
          valid: false,
          message: `Product "${p.Name || "Row " + (i + 1)}" must have Start Date.`
        };
      }
      if (!isMonthly && !end) {
        return {
          valid: false,
          message: `Product "${p.Name || "Row " + (i + 1)}" must have End Date.`
        };
      }
      const qtyTrimmed = typeof qty === "string" ? qty.trim() : "";
      const qtyMissing =
        qty == null ||
        (typeof qty === "string" && !qtyTrimmed) ||
        (typeof qty === "number" && Number.isNaN(qty));
      const qtyParsed =
        typeof qty === "number"
          ? qty
          : qtyTrimmed !== "" && !Number.isNaN(Number(qtyTrimmed))
            ? Number(qtyTrimmed)
            : NaN;
      const qtyFieldLabel = isExtraMeter
        ? this.labels.Value
        : this.labels.Quantity;
      if (
        qtyMissing ||
        (typeof qty === "string" &&
          qtyTrimmed !== "" &&
          Number.isNaN(qtyParsed))
      ) {
        return {
          valid: false,
          message: `Product "${p.Name || "Row " + (i + 1)}" must have ${qtyFieldLabel}.`
        };
      }
      if (Number.isFinite(qtyParsed) && qtyParsed < 0) {
        return {
          valid: false,
          message: `Product "${p.Name || "Row " + (i + 1)}" must have a non-negative ${qtyFieldLabel}.`
        };
      }

      if (
        orderStartFloor &&
        new Date(entry) < new Date(orderStartFloor) &&
        this._isNewOrReplacementDraftProductRow(p)
      ) {
        return {
          valid: false,
          message:
            this._productStartBeforeContractStartDateMessage(orderStartFloor)
        };
      }
      if (end) {
        if (contractEnd && new Date(end) > new Date(contractEnd)) {
          const contractEndYmd = this._normalizeToYyyyMmDd(contractEnd);
          const endYmd = this._normalizeToYyyyMmDd(end);
          const parentWouldExtendAtSave =
            this.isContract &&
            this.draftOrderId &&
            this.recordId &&
            contractEndYmd &&
            endYmd &&
            endYmd > contractEndYmd;
          if (!parentWouldExtendAtSave) {
            return {
              valid: false,
              message: `Product end date can't be later than contract end date (${this.formatDateForMessage(contractEnd)}).`
            };
          }
        }
        if (new Date(entry) > new Date(end)) {
          return {
            valid: false,
            message: "Start Date cannot be after End Date."
          };
        }
      }
    }

    // Replacement pair: replacement start date must be >= replaced end date (and vice versa)
    for (const p of products) {
      const rowNk = this._normalizeRowId(p.LineItemId || p.Id);
      const draft = rowNk ? draftMap.get(rowNk) : null;
      const entry = this.isContract
        ? draft?.EntryDate !== undefined
          ? draft.EntryDate
          : (p.EntryDate ?? p.ServiceDate)
        : draft?.EntryDate !== undefined
          ? draft.EntryDate
          : p.EntryDate;
      const end = draft?.EndDate !== undefined ? draft.EndDate : p.EndDate;
      if (p.ReplacedOrderProductId) {
        const replaced = this._findLineItemRowById(
          products,
          p.ReplacedOrderProductId
        );
        if (replaced) {
          const repNk = this._normalizeRowId(
            replaced.LineItemId || replaced.Id
          );
          const repDraft = repNk ? draftMap.get(repNk) : null;
          const replacedEnd =
            repDraft?.EndDate !== undefined
              ? repDraft.EndDate
              : replaced.EndDate;
          const entryY = this._normalizeToYyyyMmDd(entry);
          const endY = this._normalizeToYyyyMmDd(replacedEnd);
          if (entryY && endY && entryY < endY) {
            return {
              valid: false,
              message:
                "Replacement product start date must be the calendar day after the replaced product end date."
            };
          }
        }
      } else {
        const repChild = this._findDirectReplacementForReplacedId(
          rowNk || p.LineItemId || p.Id
        );
        if (repChild) {
          const replNk = this._normalizeRowId(
            repChild.LineItemId || repChild.Id
          );
          const replDraft = replNk ? draftMap.get(replNk) : null;
          const replEntry = this.isContract
            ? replDraft?.EntryDate !== undefined
              ? replDraft.EntryDate
              : (repChild.EntryDate ?? repChild.ServiceDate)
            : replDraft?.EntryDate !== undefined
              ? replDraft.EntryDate
              : repChild.EntryDate;
          const endY = this._normalizeToYyyyMmDd(end);
          const replY = this._normalizeToYyyyMmDd(replEntry);
          if (endY && replY && endY > replY) {
            const willMirrorStart =
              this._replacementMirrorEligible() &&
              !this._replacementMirrorPeerBlocked(repChild) &&
              addCalendarDaysYmd(endY, 1);
            if (!willMirrorStart) {
              return {
                valid: false,
                message:
                  "Replaced product end date must be the calendar day before the replacement product start date."
              };
            }
          }
        }
      }
    }

    const pastStartMsg = pastStartSignedBlockMessage(
      this._getOrderStartDateForPastStartSignedGate(),
      this._todayYmdUtc(),
      hasSignedPastStartAdminOverride
    );
    if (pastStartMsg) {
      return { valid: false, message: pastStartMsg };
    }

    return { valid: true };
  }

  get canActivateDraft() {
    if (!this.isContract || !this.draftOrderId || this.isModifyMode)
      return false;
    const result = this.validateDraftForActivation();
    return result.valid;
  }

  get saveButtonTitle() {
    return this.savingDraft ? "Saving…" : "Save changes";
  }

  // ─── ORDER SECTION (Draft tab: inline edit) ────────────────

  /**
   * Read live lightning-input values for Order fields that are not lightning-input-field,
   * so Save still persists them if onchange has not committed yet.
   */
  _captureCustomOrderInputEditsFromDom() {
    const customFieldNames = [
      "Renewal_Price_Increase_Percent__c",
      "Google_Drive_Link__c"
    ];
    const captured = {};
    customFieldNames.forEach((fieldName) => {
      const input = this.template.querySelector(
        `lightning-input[data-field="${fieldName}"]`
      );
      if (!input) return;
      const raw = input.value;
      if (fieldName === "Renewal_Price_Increase_Percent__c") {
        captured[fieldName] =
          raw === "" || raw == null || Number.isNaN(Number(raw))
            ? null
            : Number(raw);
      } else {
        captured[fieldName] = raw;
      }
    });
    if (Object.keys(captured).length === 0) return;
    this._orderSectionCustomEdits = {
      ...(this._orderSectionCustomEdits || {}),
      ...captured
    };
  }

  /** Collect any open lightning-input-field values currently on the Order form. */
  _collectOrderSectionInputFieldValues() {
    const fields = {};
    this.template.querySelectorAll("lightning-input-field").forEach((el) => {
      const name = el.fieldName;
      if (!name) return;
      fields[name] = el.value;
    });
    return fields;
  }

  /**
   * Persist Order section via updateRecord so fields edited with lightning-input
   * (Google Drive / Price Increase) are not dropped by record-edit-form.submit().
   */
  async _persistOrderSectionFields(fields) {
    const payload = {
      ...fields,
      Id: this.orderSectionOrderId
    };
    delete payload.EffectiveDate;
    await updateRecord({ fields: payload });
    await this.handleOrderSaveSuccess();
  }

  async handleOrderSubmit(event) {
    // Keep intercepting form submit so Enter-key / other submitters also persist.
    event.preventDefault();
    await this._saveOrderSectionFromUi(event.detail.fields || {});
  }

  /**
   * Build field payload from form (if any) + live DOM inputs and persist via updateRecord.
   */
  async _saveOrderSectionFromUi(baseFields = {}) {
    this._captureCustomOrderInputEditsFromDom();
    const fields = {
      ...baseFields,
      ...this._collectOrderSectionInputFieldValues(),
      ...(this._orderSectionCustomEdits || {})
    };
    delete fields.EffectiveDate;
    if (this._toolbarEffectiveDateValue !== undefined) {
      fields.Order_Start_Date__c = this._toolbarEffectiveDateValue;
    } else if (
      fields.Order_Start_Date__c === undefined &&
      this.draftOrderDetails?.effectiveDate
    ) {
      fields.Order_Start_Date__c = this.draftOrderDetails.effectiveDate;
    }
    const newOrderStartDate = this._normalizeToYyyyMmDd(
      fields?.Order_Start_Date__c
    );
    const currentOrderStartDate = this._normalizeToYyyyMmDd(
      this.draftOrderDetails?.effectiveDate
    );

    if (!this.orderSectionOrderId) {
      this.showToast("Error", "No draft order to save.", "error");
      return;
    }

    if (newOrderStartDate) {
      const contractStartValidationMsg =
        this._validateOrderStartAgainstContractStart(newOrderStartDate);
      if (contractStartValidationMsg) {
        this.showToast("Validation Error", contractStartValidationMsg, "error");
        return;
      }
    }

    try {
      if (
        newOrderStartDate &&
        currentOrderStartDate &&
        newOrderStartDate !== currentOrderStartDate
      ) {
        await this._syncDraftOrderStartWithLines(
          this.orderSectionOrderId,
          newOrderStartDate,
          currentOrderStartDate
        );
      }
      await this._persistOrderSectionFields(fields);
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        this._reduceServerError(e) ||
        "Failed to save order changes.";
      this.showToast("Error", msg, "error");
    }
  }

  async handleOrderSaveClick() {
    if (this._isEditingQuarterlyPaymentOnActiveTab) {
      try {
        await this._persistContractQuarterlyPaymentIfChanged();
        this.showToast("Success", "Contract updated", "success");
        this._clearOrderEditingState();
      } catch (error) {
        this.showToast(
          "Error",
          this._reduceServerError(error) || "Could not save Quarterly Payment.",
          "error"
        );
      }
      return;
    }
    // Do not rely on lightning-record-edit-form.submit() — it can silently drop
    // lightning-input values and/or skip onsubmit when validation short-circuits.
    await this._saveOrderSectionFromUi({});
  }

  async handleOrderSaveSuccess() {
    try {
      await this._persistContractQuarterlyPaymentIfChanged();
    } catch (error) {
      this.showToast(
        "Error",
        this._reduceServerError(error) || "Could not save Quarterly Payment.",
        "error"
      );
      return;
    }
    this.showToast("Success", "Draft order updated", "success");
    this.orderSectionEditMode = false;
    this.orderSectionDirty = false;
    this.orderSectionEditingField = null;
    this.orderSectionEditingFields = [];
    this._orderSectionCustomEdits = {};
    this._toolbarEffectiveDateValue = undefined;
    refreshApex(this.wiredDraftSummaryResult);
    refreshApex(this.wiredDraftLineItemsResult);
    refreshApex(this.wiredDraftOrderDetailsResult);
    this._refreshMonthlyPaymentKpiWires().catch(() => {});
  }

  handleOrderSaveError(event) {
    const msg = this.getOrderSaveErrorMessage(event.detail);
    this.showToast("Validation Error", msg, "error");
  }

  /**
   * Extract the actual error/validation message(s) from lightning-record-edit-form onerror detail.
   * Supports output.errors, output.fieldErrors, body.message, and detail.message so toast shows the real message.
   */
  getOrderSaveErrorMessage(detail) {
    if (!detail) return "Failed to save order changes.";
    const out = detail.output;
    if (out) {
      const messages = [];
      if (Array.isArray(out.errors)) {
        out.errors.forEach((e) => {
          if (e && e.message) messages.push(e.message);
        });
      }
      if (out.fieldErrors && typeof out.fieldErrors === "object") {
        Object.keys(out.fieldErrors).forEach((field) => {
          const errs = out.fieldErrors[field];
          if (Array.isArray(errs)) {
            errs.forEach((e) => {
              if (e && e.message) messages.push(e.message);
            });
          }
        });
      }
      if (messages.length > 0) return messages.join(" ");
    }
    if (detail.body && detail.body.message) return detail.body.message;
    if (detail.message) return detail.message;
    if (typeof detail === "string") return detail;
    return "Failed to save order changes.";
  }

  handleOrderFieldEditIcon(event) {
    const field = event.currentTarget?.dataset?.field;
    if (!field) return;
    this._openOrderFieldEdit(field);
  }

  /** Double-click on field value to edit (same as clicking pencil). */
  handleOrderFieldDblclick(event) {
    const field = event.currentTarget?.dataset?.field;
    if (!field) return;
    this._openOrderFieldEdit(field);
  }

  _snapshotContractQuarterlyPaymentForEdit() {
    this._contractQuarterlyPaymentSnapshot = this.contractQuarterlyPayment;
  }

  _revertContractQuarterlyPaymentFromSnapshot() {
    if (this._contractQuarterlyPaymentSnapshot === undefined) return;
    this.contractQuarterlyPayment = this._contractQuarterlyPaymentSnapshot;
    if (this.showInMemoryOrderSection && this.inMemoryDraftOrder) {
      this.inMemoryDraftOrder = {
        ...this.inMemoryDraftOrder,
        quarterlyPayment: this._contractQuarterlyPaymentSnapshot
      };
    }
    this._contractQuarterlyPaymentSnapshot = undefined;
  }

  async _persistContractQuarterlyPaymentIfChanged() {
    if (!this.recordId) return;
    const baseline =
      this._contractQuarterlyPaymentSnapshot !== undefined
        ? this._contractQuarterlyPaymentSnapshot
        : this.wiredContractDatesResult?.data?.quarterlyPayment === true;
    if (this.contractQuarterlyPayment === baseline) {
      this._contractQuarterlyPaymentSnapshot = undefined;
      return;
    }
    await updateRecord({
      fields: {
        Id: this.recordId,
        Quarterly_Payment__c: this.contractQuarterlyPayment
      }
    });
    this._contractQuarterlyPaymentSnapshot = undefined;
    if (this.wiredContractDatesResult) {
      await refreshApex(this.wiredContractDatesResult);
    }
  }

  _openOrderFieldEdit(field) {
    const isQuarterlyOnActiveTab =
      (field === "Quarterly_Payment__c" || field === "quarterlyPayment") &&
      this.showActiveTabQuarterlyPaymentEdit;
    if (this.isOrderSectionReadOnly && !isQuarterlyOnActiveTab) return;
    if (field === "Quarterly_Payment__c" || field === "quarterlyPayment") {
      this._snapshotContractQuarterlyPaymentForEdit();
    }
    if (this.showInMemoryOrderSection) {
      this._orderSectionEditSnapshot = this._orderSectionEditSnapshot || {
        ...this.inMemoryDraftOrder
      };
      this.orderSectionEditMode = true;
      if (!this.orderSectionEditingFields.includes(field)) {
        this.orderSectionEditingFields = [
          ...this.orderSectionEditingFields,
          field
        ];
      }
      return;
    }
    this.orderSectionEditMode = true;
    if (!this.orderSectionEditingFields.includes(field)) {
      this.orderSectionEditingFields = [
        ...this.orderSectionEditingFields,
        field
      ];
    }
    this.orderSectionDirty = false;
  }

  handleOrderCancel() {
    if (this.showInMemoryOrderSection && this._orderSectionEditSnapshot) {
      this.inMemoryDraftOrder = { ...this._orderSectionEditSnapshot };
    }
    this._revertContractQuarterlyPaymentFromSnapshot();
    this._orderSectionEditSnapshot = null;
    this.orderSectionEditMode = false;
    this.orderSectionDirty = false;
    this.orderSectionEditingField = null;
    this.orderSectionEditingFields = [];
    this._orderSectionCustomEdits = {};
    this._toolbarEffectiveDateValue = undefined;
  }

  handleOrderFieldChange(event) {
    const fieldName = event.target?.dataset?.field;
    const inputType = event.target?.type;
    if (
      fieldName === "Quarterly_Payment__c" ||
      fieldName === "quarterlyPayment"
    ) {
      const checked = event.target.checked === true;
      this.contractQuarterlyPayment = checked;
      if (this.showInMemoryOrderSection) {
        this.inMemoryDraftOrder = {
          ...this.inMemoryDraftOrder,
          quarterlyPayment: checked
        };
      }
      this.orderSectionDirty = true;
      return;
    }
    if (this.showInMemoryOrderSection) {
      const fieldValue =
        inputType === "toggle" || inputType === "checkbox"
          ? event.target.checked
          : (event.detail?.value ?? event.target?.value);
      if (fieldName) {
        this.inMemoryDraftOrder = {
          ...this.inMemoryDraftOrder,
          [fieldName]: fieldValue
        };
        if (fieldName === "effectiveDate") {
          this._refreshEntryDateClockIcons();
        }
      }
    } else if (event.target?.dataset?.field === "Order_Start_Date__c") {
      this._toolbarEffectiveDateValue =
        event.detail?.value ?? event.target?.value ?? "";
      this._refreshEntryDateClockIcons();
      this._autoSaveToolbarOrderStartDateIfApplicable().catch(() => {});
    } else if (
      fieldName === "Renewal_Price_Increase_Percent__c" ||
      fieldName === "Google_Drive_Link__c"
    ) {
      const raw = event.detail?.value ?? event.target?.value;
      let nextVal = raw;
      if (fieldName === "Renewal_Price_Increase_Percent__c") {
        nextVal =
          raw === "" || raw == null || Number.isNaN(Number(raw))
            ? null
            : Number(raw);
      }
      this._orderSectionCustomEdits = {
        ...(this._orderSectionCustomEdits || {}),
        [fieldName]: nextVal
      };
    }
    this.orderSectionDirty = true;
  }

  _clearOrderEditingState() {
    this.orderSectionEditMode = false;
    this.orderSectionDirty = false;
    this.orderSectionEditingField = null;
    this.orderSectionEditingFields = [];
    this._orderSectionCustomEdits = {};
    this._contractQuarterlyPaymentSnapshot = undefined;
    this._toolbarEffectiveDateValue = undefined;
  }

  seedInMemoryDraftOrderFromActive() {
    const d = this.activeOrderDetails;
    const startFromToday = new Date().toISOString().split("T")[0];
    const contractStart = this._normalizeToYyyyMmDd(this.contractStartDate);
    const activeOrderStart = this._normalizeToYyyyMmDd(d?.effectiveDate);
    const startCandidates = [
      startFromToday,
      contractStart,
      activeOrderStart
    ].filter(Boolean);
    const startFromContractOrToday =
      startCandidates.length > 0
        ? startCandidates.reduce((a, b) => (a > b ? a : b))
        : startFromToday;
    const endFromContract = this._normalizeToYyyyMmDd(this.contractEndDate);
    const endFromOrder = this._normalizeToYyyyMmDd(d?.endDate);
    this.inMemoryDraftOrder = {
      orderNumber: "Calculated upon save",
      // Modify Contract rule: default to today, unless Contract Start Date is in the future.
      effectiveDate: startFromContractOrToday || null,
      endDate: endFromContract || endFromOrder || null,
      status: "Draft",
      totalAmount: d?.totalAmount ?? null,
      description: d?.description ?? null,
      numberOfMembers: d?.numberOfMembers ?? null,
      trackCpi: d?.trackCpi ?? null,
      autoRenewal: d?.autoRenewal ?? null,
      noticePeriodMonths: d?.noticePeriodMonths ?? null,
      renewalTotalIterations: d?.renewalTotalIterations ?? null,
      renewalPeriodMonths: d?.renewalPeriodMonths ?? null,
      renewalPriceIncreasePercent: d?.renewalPriceIncreasePercent ?? null,
      googleDriveLink: d?.googleDriveLink ?? null,
      earlyTerminationFee: d?.earlyTerminationFee ?? null,
      paymentMethod: d?.paymentMethod ?? null,
      quarterlyPayment: this.contractQuarterlyPayment === true
    };
    this._refreshEntryDateClockIcons();
  }

  async applyInMemoryOrderDetailsToDraft(orderId) {
    if (!orderId) return;
    const d = this.inMemoryDraftOrder;
    const fields = { Id: orderId };
    if (d?.effectiveDate) fields.Order_Start_Date__c = d.effectiveDate;
    if (d?.endDate) fields.EndDate = d.endDate;
    if (d?.description != null) fields.Description = d.description;
    if (d?.numberOfMembers != null)
      fields.Number_of_members__c = d.numberOfMembers;
    if (d?.autoRenewal != null) fields.Auto_Renewal__c = d.autoRenewal;
    if (d?.renewalTotalIterations != null)
      fields.Renewal_Total_Iterations__c = d.renewalTotalIterations;
    if (d?.noticePeriodMonths != null)
      fields.Lease_Termination_Notice_Months__c = d.noticePeriodMonths;
    if (d?.renewalPeriodMonths != null)
      fields.Renewal_Period_Months__c = d.renewalPeriodMonths;
    if (d?.renewalPriceIncreasePercent != null)
      fields.Renewal_Price_Increase_Percent__c = d.renewalPriceIncreasePercent;
    if (d?.googleDriveLink != null)
      fields.Google_Drive_Link__c = d.googleDriveLink;
    if (d?.paymentMethod != null) fields.Payment_Method__c = d.paymentMethod;
    if (Object.keys(fields).length === 1) return;
    try {
      const hasStart = !!fields.Order_Start_Date__c;
      const curYmd = this._normalizeToYyyyMmDd(
        this.draftOrderDetails?.effectiveDate
      );
      const newYmd = hasStart
        ? this._normalizeToYyyyMmDd(d.effectiveDate)
        : null;
      if (hasStart) {
        const contractStartValidationMsg =
          this._validateOrderStartAgainstContractStart(newYmd);
        if (contractStartValidationMsg) {
          this.showToast(
            "Validation Error",
            contractStartValidationMsg,
            "error"
          );
          return;
        }
      }
      const isBackdate = hasStart && curYmd && newYmd && newYmd < curYmd;
      if (hasStart) {
        if (isBackdate) {
          await updateRecord({ fields });
          await alignOrderItemDatesForStartDateChange({
            orderId,
            newOrderStartDate: fields.Order_Start_Date__c,
            alignChangeTypeNewLines: false
          });
        } else {
          await alignOrderItemDatesForStartDateChange({
            orderId,
            newOrderStartDate: fields.Order_Start_Date__c,
            alignChangeTypeNewLines: true
          });
          await updateRecord({ fields });
        }
        await Promise.all([
          this._refreshApexSafe(this.wiredDraftLineItemsResult),
          this._refreshApexSafe(this.wiredDraftSummaryResult),
          this._refreshApexSafe(this.wiredDraftOrderDetailsResult),
          this._refreshMonthlyPaymentKpiWires()
        ]);
      } else {
        await updateRecord({ fields });
      }
      await this._persistContractQuarterlyPaymentIfChanged();
    } catch (e) {
      console.error(
        "applyInMemoryOrderDetailsToDraft error:",
        JSON.stringify(e)
      );
    }
  }

  /**
   * Earliest allowed toolbar order start: Contract.StartDate, and on draft tab the active order start.
   */
  _toolbarOrderStartMinYmd() {
    if (!this.isContract) return null;
    let floor = this._normalizeToYyyyMmDd(this.contractStartDate);
    if (this.activeTab === "draft") {
      floor = this._maxYmd(
        floor,
        this._normalizeToYyyyMmDd(this.activeOrderDetails?.effectiveDate)
      );
    }
    return floor || null;
  }

  /**
   * Contract start date cannot be earlier than contract start date or previous activated contract start date.
   * Returns a user-facing message when invalid; otherwise null.
   */
  _validateOrderStartAgainstContractStart(orderStartRaw) {
    if (!this.isContract) return null;
    const orderStartYmd = this._normalizeToYyyyMmDd(orderStartRaw);
    if (!orderStartYmd) return null;
    const minYmd = this._toolbarOrderStartMinYmd();
    if (minYmd && orderStartYmd >= minYmd) return null;

    const contractStartYmd = this._normalizeToYyyyMmDd(this.contractStartDate);
    if (contractStartYmd && orderStartYmd < contractStartYmd) {
      return `This can't be earlier than contract start date (${this.formatDateForMessage(contractStartYmd)}).`;
    }
    const previousActivatedStartYmd = this._normalizeToYyyyMmDd(
      this.activeOrderDetails?.effectiveDate
    );
    if (
      this.activeTab === "draft" &&
      previousActivatedStartYmd &&
      orderStartYmd < previousActivatedStartYmd
    ) {
      return `This can't be earlier than previous activated contract start date (${this.formatDateForMessage(previousActivatedStartYmd)}).`;
    }
    return null;
  }

  _getDraftOrderStartDateForValidation() {
    if (!this.isContract) return null;
    if (this.showInMemoryOrderSection) {
      return this.inMemoryDraftOrder?.effectiveDate || null;
    }
    return (
      this._toolbarEffectiveDateValue ||
      this.draftOrderDetails?.effectiveDate ||
      null
    );
  }

  /**
   * Order_Start_Date__c only for past-start Signed gate (PRD: no EffectiveDate / Contract.StartDate fallbacks).
   */
  _getOrderStartDateForPastStartSignedGate() {
    if (!this.isContract) return null;
    if (this.showInMemoryOrderSection) {
      return this.inMemoryDraftOrder?.effectiveDate || null;
    }
    if (this._toolbarEffectiveDateValue !== undefined) {
      return this._toolbarEffectiveDateValue || null;
    }
    return this._orderStartDateYmdFromDetails(this.draftOrderDetails);
  }

  /**
   * Entry-date floor for new/replacement contract lines: Order_Start_Date__c (toolbar / draft / in-memory).
   * UI label is "Contract Start Date"; message uses the same date as validation.
   */
  _getOrderStartDateForNewProductEntryValidation() {
    if (!this.isContract) return null;
    const ymd =
      this._normalizeToYyyyMmDd(this._getDraftOrderStartDateForValidation()) ||
      this._orderStartDateYmdFromDetails(this.draftOrderDetails) ||
      (this.activeTab === "active"
        ? this._normalizeToYyyyMmDd(this.activeOrderDetails?.effectiveDate)
        : null);
    return ymd || null;
  }

  _productStartBeforeContractStartDateMessage(floorDate) {
    return `Product start date can't be earlier than Contract Start Date (${this.formatDateForMessage(floorDate)}).`;
  }

  // ─── TOAST ────────────────────────────────────────────────

  showToast(title, message, variant) {
    const toast = { title, message, variant };
    if (variant === "success" || variant === "info" || variant === "warning") {
      toast.mode = "dismissable";
    }
    this.dispatchEvent(new ShowToastEvent(toast));
  }
}
