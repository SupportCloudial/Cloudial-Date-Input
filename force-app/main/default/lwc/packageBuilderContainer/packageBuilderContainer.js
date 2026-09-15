// WI-000168: Package Builder container – Modify/Activate button visibility
import { api, LightningElement } from "lwc";
import LightningConfirm from "lightning/confirm";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { isUsageBased } from "c/accessTypePolicy";

import packagebuilder_title from "@salesforce/label/c.PackageBuilder_Title";
import packagebuilder_add_products from "@salesforce/label/c.PackageBuilder_AddProducts";
import packagebuilder_cancel from "@salesforce/label/c.PackageBuilder_Cancel";
import RemoveDraftIconHelp from "@salesforce/label/c.PackageBuilder_RemoveDraftIconHelp";

export default class PackageBuilderContainer extends LightningElement {
  labels = {
    packagebuilder_title,
    packagebuilder_add_products,
    packagebuilder_cancel,
    RemoveDraftIconHelp
  };

  @api recordId;
  @api objectApiName;
  @api title = this.labels.packagebuilder_title;
  @api buttonLabel = this.labels.packagebuilder_add_products;

  textDirection = "ltr";

  // Button visibility – driven by the child table component
  showModifyButton = false;
  showActivateButton = false;
  showCancelDraftButton = false;
  modifyDisabled = false;
  activateDisabled = false;
  cancellingDraft = false;
  /** True while Modify Contract is persisting a new draft order. */
  creatingDraft = false;
  activating = false;
  modifyButtonLabel = "Modify";

  // Monthly payments drawer state (Option A)
  isMonthlyPaymentsDrawerOpen = false;
  monthlyPaymentsSelectedLineItemIds = [];
  monthlyPaymentsSelectedLineItemMeta = [];
  monthlyPaymentsEffectiveRecordId = null;
  monthlyPaymentsTabName = null;
  monthlyPaymentsReadOnly = false;
  monthlyPaymentsConcludedTermsActiveTab = false;

  // Contract term replace — top sheet, same pattern as Add Products
  isContractTermReplaceSheetOpen = false;
  contractTermSheetOrderId = null;
  contractTermSheetReplacedOrderItemId = null;
  contractTermSheetReplacedPricebookEntryId = null;
  contractTermSheetOrderStartDate = null;
  contractTermSheetOrderEndDate = null;
  contractTermSheetDefaultEntryDateYmd = null;
  contractTermSheetDefaultCpiDateYmd = null;
  contractTermSheetDefaultQuantity = 1;

  // Past-start split modal (869dk2u53)
  isPastStartChangeModalOpen = false;
  pastStartChangeMode = "accessType";
  pastStartSheetOrderId = null;
  pastStartSheetReplacedOrderItemId = null;
  pastStartSheetReplacedPricebookEntryId = null;
  pastStartSheetEntryDateMinYmd = null;
  pastStartSheetEntryDateMaxYmd = null;
  pastStartSheetDefaultEntryDateYmd = null;
  pastStartSheetDefaultEndDateYmd = null;
  pastStartSheetOrderEndDateYmd = null;
  pastStartSheetDefaultQuantity = 1;
  pastStartSheetCurrentAccessType = null;
  pastStartSheetFlippedAccessType = null;
  pastStartSheetShowAccessTypePicker = false;
  pastStartSheetAccessTypePickerOptions = [];
  pastStartSheetDefaultPickerAccessType = null;

  monthlyPaymentsPriceChangeMode = false;
  monthlyPaymentsContractStartDateYmd = null;
  monthlyPaymentsContractEndDateYmd = null;

  // Add Products top sheet state
  isAddProductsSheetOpen = false;
  addProductsRecordId = null;
  addProductsObjectApiName = null;
  addProductsReplaceMode = false;
  addProductsReplacedOrderItemId = null;
  addProductsReplacedPricebookEntryId = null;
  addProductsOrderStartDate = null;
  addProductsOrderEndDate = null;
  addProductsReplaceDefaultPeriodStartYmd = null;
  addProductsReplacedProductEndDate = null;
  addProductsReplacedActiveEndDateYmd = null;
  addProductsSessionKey = 0;

  get monthlyDrawerClass() {
    return `monthly-drawer${this.isMonthlyPaymentsDrawerOpen ? " is-open" : ""}`;
  }

  get monthlyDrawerBackdropClass() {
    return `monthly-drawer-backdrop${this.isMonthlyPaymentsDrawerOpen ? " is-open" : ""}`;
  }

  get monthlyDrawerAriaHidden() {
    return this.isMonthlyPaymentsDrawerOpen ? "false" : "true";
  }

  get isContract() {
    return this.objectApiName === "Contract";
  }

  /** Package Builder is supported on Opportunity and Contract only; not on Order. */
  get isSupportedContext() {
    return (
      this.objectApiName === "Opportunity" || this.objectApiName === "Contract"
    );
  }

  get activateButtonDisabled() {
    return this.activateDisabled || this.activating;
  }

  get cancelDraftButtonDisabled() {
    return this.cancellingDraft;
  }

  get activatingTitle() {
    return this.activating ? "Activating…" : "Activate draft order";
  }

  get modifyDisabledEffective() {
    return this.modifyDisabled || this.creatingDraft;
  }

  get modifyButtonLabelEffective() {
    return this.creatingDraft ? "Creating Draft…" : this.modifyButtonLabel;
  }

  connectedCallback() {
    this.textDirection =
      typeof document !== "undefined" && document.documentElement.dir === "rtl"
        ? "rtl"
        : "ltr";
    if (!this.isContract) {
      this.showModifyButton = false;
      this.showActivateButton = false;
    }
  }

  handleAddProducts(event) {
    event?.stopPropagation?.();

    // For Contract context the child table sends the Order id to add to (draft or active).
    // For Opportunity we must use recordId + objectApiName so the modal loads products by location.
    const isContract = this.objectApiName === "Contract";
    const eventDetail = event?.detail || {};
    if (isContract && !eventDetail.orderId) {
      // Ignore bubbled toolbar/panel addproduct events that have no detail payload.
      return;
    }
    const replaceMode =
      eventDetail.replaceMode === true && eventDetail.replacedOrderItemId;
    const targetRecordId =
      isContract && eventDetail.orderId ? eventDetail.orderId : this.recordId;
    let targetObjectApiName =
      isContract && eventDetail.orderId ? "Order" : this.objectApiName;
    // Infer object type from recordId when page doesn't pass objectApiName (e.g. some record pages)
    if (!targetObjectApiName && targetRecordId) {
      if (String(targetRecordId).startsWith("006"))
        targetObjectApiName = "Opportunity";
      else if (String(targetRecordId).startsWith("801"))
        targetObjectApiName = "Order";
    }

    this.addProductsRecordId = targetRecordId;
    this.addProductsObjectApiName = targetObjectApiName;
    this.addProductsReplaceMode = !!replaceMode;
    this.addProductsReplacedOrderItemId = replaceMode
      ? eventDetail.replacedOrderItemId
      : null;
    this.addProductsReplacedProductEndDate = replaceMode
      ? eventDetail.replacedProductEndDate || null
      : null;
    this.addProductsReplacedActiveEndDateYmd = replaceMode
      ? eventDetail.replacedActiveEndDateYmd || null
      : null;
    this.addProductsReplacedPricebookEntryId = replaceMode
      ? eventDetail.replacedPricebookEntryId || null
      : null;
    this.addProductsOrderStartDate = eventDetail.orderStartDate || null;
    this.addProductsOrderEndDate = eventDetail.orderEndDate || null;
    this.addProductsReplaceDefaultPeriodStartYmd =
      replaceMode && eventDetail.replaceDefaultPeriodStartYmd
        ? eventDetail.replaceDefaultPeriodStartYmd
        : null;
    // Force a fresh Add Products sheet body each time to avoid stale selection/filters persisting between opens.
    this.addProductsSessionKey = (Number(this.addProductsSessionKey) || 0) + 1;
    this.isAddProductsSheetOpen = true;
  }

  handleOpenContractTermReplace(event) {
    const d = event.detail || {};
    if (!d.orderId || !d.replacedOrderItemId || !d.replacedPricebookEntryId) {
      return;
    }
    this.contractTermSheetOrderId = d.orderId;
    this.contractTermSheetReplacedOrderItemId = d.replacedOrderItemId;
    this.contractTermSheetReplacedPricebookEntryId = d.replacedPricebookEntryId;
    this.contractTermSheetOrderStartDate = d.orderStartDate || null;
    this.contractTermSheetOrderEndDate = d.orderEndDate || null;
    this.contractTermSheetDefaultEntryDateYmd = d.defaultEntryDateYmd || null;
    this.contractTermSheetDefaultCpiDateYmd = d.defaultCpiDateYmd || null;
    const dq = Number(d.defaultQuantity);
    this.contractTermSheetDefaultQuantity = Number.isFinite(dq) ? dq : 1;
    this.isContractTermReplaceSheetOpen = true;
  }

  handleCloseContractTermReplaceSheet() {
    this.isContractTermReplaceSheetOpen = false;
    this.contractTermSheetDefaultEntryDateYmd = null;
  }

  handleContractTermReplaceSheetComplete() {
    this.handleCloseContractTermReplaceSheet();
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (
      tableComponent &&
      typeof tableComponent.refreshProductsTable === "function"
    ) {
      tableComponent.refreshProductsTable();
    }
  }

  handleOpenPastStartChange(event) {
    const d = event.detail || {};
    if (!d.orderId || !d.replacedOrderItemId || !d.replacedPricebookEntryId) {
      return;
    }
    this.pastStartChangeMode = d.mode || "accessType";
    this.pastStartSheetOrderId = d.orderId;
    this.pastStartSheetReplacedOrderItemId = d.replacedOrderItemId;
    this.pastStartSheetReplacedPricebookEntryId = d.replacedPricebookEntryId;
    this.pastStartSheetEntryDateMinYmd = d.entryDateMinYmd || null;
    this.pastStartSheetEntryDateMaxYmd = d.entryDateMaxYmd || null;
    this.pastStartSheetDefaultEntryDateYmd = d.defaultEntryDateYmd || null;
    this.pastStartSheetDefaultEndDateYmd = d.defaultEndDateYmd || null;
    this.pastStartSheetOrderEndDateYmd = d.orderEndDateYmd || null;
    const dq = Number(d.defaultQuantity);
    this.pastStartSheetDefaultQuantity = Number.isFinite(dq) ? dq : 1;
    this.pastStartSheetCurrentAccessType = d.currentAccessType || null;
    this.pastStartSheetFlippedAccessType = d.flippedAccessType || null;
    this.pastStartSheetShowAccessTypePicker = d.showAccessTypePicker === true;
    this.pastStartSheetAccessTypePickerOptions = Array.isArray(
      d.accessTypePickerOptions
    )
      ? d.accessTypePickerOptions
      : [];
    this.pastStartSheetDefaultPickerAccessType =
      d.defaultPickerAccessType || null;
    this.isPastStartChangeModalOpen = true;
  }

  handleClosePastStartChangeModal() {
    this.isPastStartChangeModalOpen = false;
  }

  handlePastStartChangeModalComplete() {
    this.handleClosePastStartChangeModal();
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (
      tableComponent &&
      typeof tableComponent.refreshProductsTable === "function"
    ) {
      tableComponent.refreshProductsTable();
    }
  }

  get monthlyPaymentsShowPriceFields() {
    return (
      this.isContract &&
      (this.monthlyPaymentsSelectedLineItemMeta || []).some(
        (m) => !isUsageBased(m.accessType)
      )
    );
  }

  handleCloseAddProductsSheet() {
    this.isAddProductsSheetOpen = false;
  }

  handleAddProductsSheetComplete() {
    this.handleCloseAddProductsSheet();
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (tableComponent) {
      tableComponent.refreshProductsTable();
    }
  }

  handlePackageBuilderNotify(event) {
    const { title, message, variant, mode } = event.detail || {};
    this.dispatchEvent(
      new ShowToastEvent({
        title: title || "Notice",
        message: message || "",
        variant: variant || "info",
        mode: mode || "dismissable"
      })
    );
  }

  /** Forward Modify click to the child table (persists draft; may take a moment). */
  async handleModify() {
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (
      !tableComponent ||
      typeof tableComponent.handleModifyFromContainer !== "function"
    ) {
      return;
    }
    this.creatingDraft = true;
    try {
      await tableComponent.handleModifyFromContainer();
    } finally {
      this.creatingDraft = false;
    }
  }

  /** Forward Activate click to the child table (await so rapid double-clicks do not stack invocations). */
  async handleActivateDraft() {
    if (this.activating) {
      return;
    }
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (
      tableComponent &&
      typeof tableComponent.handleActivateDraftFromContainer === "function"
    ) {
      await tableComponent.handleActivateDraftFromContainer();
    }
  }

  handleCancelDraftOrder() {
    const tableComponent = this.template.querySelector(
      "c-package-builder-table"
    );
    if (
      tableComponent &&
      typeof tableComponent.handleCancelDraftFromContainer === "function"
    ) {
      tableComponent.handleCancelDraftFromContainer();
    }
  }

  /**
   * Called by the child table component to update which buttons are visible.
   * @param {Boolean} showModify  – show Modify button (Active tab)
   * @param {Boolean} showActivate – show Activate button (Draft tab with real draft)
   * @param {Boolean} modifyDisabled – disable Modify when draft already exists
   * @param {Boolean} activateDisabled – disable Activate when required fields/dates are invalid
   * @param {String} [modifyButtonLabel] – label for Modify button (e.g. "Modify Contract")
   * @param {Boolean} [activating] – true while activation is in progress (shows spinner, disables Activate)
   * @param {Boolean} [showCancelDraft] – show Cancel draft order button (Draft tab with saved draft)
   * @param {Boolean} [cancellingDraft] – true while cancel draft is in progress (disables button, shows spinner)
   */
  @api updateButtonVisibility(
    showModify,
    showActivate,
    modifyDisabled,
    activateDisabled,
    modifyButtonLabel,
    activating,
    showCancelDraft,
    cancellingDraft
  ) {
    this.showModifyButton = showModify;
    this.showActivateButton = showActivate;
    this.showCancelDraftButton = !!showCancelDraft;
    this.modifyDisabled = modifyDisabled || false;
    this.activateDisabled = activateDisabled || false;
    this.cancellingDraft = !!cancellingDraft;
    if (modifyButtonLabel != null && modifyButtonLabel !== "") {
      this.modifyButtonLabel = modifyButtonLabel;
    }
    if (activating !== undefined) {
      this.activating = activating;
    }
  }

  /** Set activating state (spinner) when Activate is in progress. */
  @api setActivating(value) {
    this.activating = !!value;
  }

  /** Set creating-draft state (spinner, disable Modify) while draft order is being created. */
  @api setCreatingDraft(value) {
    this.creatingDraft = !!value;
  }

  handleOpenMonthlyPaymentsDrawer(event) {
    const selectedLineItemIds = event.detail?.selectedLineItemIds || [];
    const selectedLineItemMeta = event.detail?.selectedLineItemMeta || [];
    const orderId = event.detail?.orderId || null;
    const tabName = event.detail?.tabName || null;
    const readOnly = event.detail?.readOnly === true;
    this.monthlyPaymentsConcludedTermsActiveTab =
      event.detail?.concludedTermsActiveTab === true;
    this.monthlyPaymentsPriceChangeMode =
      event.detail?.priceChangeMode === true;
    this.monthlyPaymentsContractStartDateYmd =
      event.detail?.contractStartDateYmd || null;
    this.monthlyPaymentsContractEndDateYmd =
      event.detail?.contractEndDateYmd || null;

    this.monthlyPaymentsSelectedLineItemIds = Array.isArray(selectedLineItemIds)
      ? [...selectedLineItemIds]
      : [];
    this.monthlyPaymentsSelectedLineItemMeta = Array.isArray(
      selectedLineItemMeta
    )
      ? [...selectedLineItemMeta]
      : [];
    this.monthlyPaymentsEffectiveRecordId = orderId || this.recordId;
    this.monthlyPaymentsTabName = tabName;
    this.monthlyPaymentsReadOnly = readOnly;
    this.isMonthlyPaymentsDrawerOpen = true;

    // Focus the drawer close button after render
    // eslint-disable-next-line @lwc/lwc/no-async-operation -- focus drawer close after open
    requestAnimationFrame(() => {
      const el = this.template.querySelector("[data-drawer-close]");
      if (el) el.focus();
    });
  }

  async closeMonthlyPaymentsDrawerWithConfirm() {
    const mp = this.template.querySelector("c-monthly-payment-table");
    if (mp?.hasUnsavedMonthlyChanges) {
      const confirmed = await LightningConfirm.open({
        message:
          "You have unsaved changes to monthly payments. Discard them and close?",
        variant: "header",
        label: "Discard unsaved changes?"
      });
      if (!confirmed) {
        return;
      }
      mp.discardUnsavedMonthlyChanges();
    }
    this.isMonthlyPaymentsDrawerOpen = false;
  }

  handleCloseMonthlyPaymentsDrawer() {
    this.closeMonthlyPaymentsDrawerWithConfirm();
  }

  handleMonthlyPaymentsDrawerKeydown(event) {
    if (!this.isMonthlyPaymentsDrawerOpen) return;
    if (event.key === "Escape") {
      event.preventDefault();
      this.closeMonthlyPaymentsDrawerWithConfirm();
    }
  }

  // Backward compatibility: if a caller still dispatches `openmonthlypayments`,
  // open the drawer (no modal).
  handleOpenMonthlyPayments(event) {
    const orderId = event.detail?.orderId || null;
    const tabName = event.detail?.tabName || null;
    this.handleOpenMonthlyPaymentsDrawer({
      detail: {
        selectedLineItemIds: this.monthlyPaymentsSelectedLineItemIds || [],
        orderId,
        tabName
      }
    });
  }

  handleMonthlyPaymentsSaved() {
    const table = this.template.querySelector("c-package-builder-table");
    if (table && typeof table.refreshProductsTable === "function") {
      table.refreshProductsTable();
    }
  }
}
