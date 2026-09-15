import { LightningElement, api } from "lwc";

export default class PackageBuilderProductsPanel extends LightningElement {
  // Layout
  @api toolbarOnly = false;
  @api showToolbar = false;
  @api enableDraftEdits = false;
  @api showEmptyProductHint = false;
  @api showSectionEmptyMessage = false;

  // KPI-ish header/summary
  @api productsHeaderCount = 0;
  @api showProductsToolbarSummary = false;
  @api productsToolbarTotalMonthlyValue;

  // Section header variant (Opportunity only)
  @api isOnDemandProducts = false;

  // Toolbar buttons
  @api isAddProductDisabled = false;
  @api showReplaceButton = false;
  @api replaceButtonTitle;
  @api isReplaceDisabled = false;
  @api isMonthlyPaymentsDisabled = false;
  @api monthlyPaymentsButtonTitle = "";
  /** When true, toolbar buttons use hover-only c-ers-tooltip wrappers. */
  @api enableToolbarTooltips = false;
  /** Contract Terminated/Expired banner above toolbar row (Contract context only). */
  @api contractStatusBannerMessage = "";
  /** When true, select-all tooltip notes that Contract Terms are excluded (Contract Package Builder only). */
  @api showContractTermsSelectAllDisclaimer = false;
  @api bulkEditDisabled = false;
  @api terminateDisabled = false;
  @api bulkEditButtonTitle = "";
  @api terminateButtonTitle = "";
  @api hideBulkEditButton = false;
  @api hideTerminateButton = false;
  @api showIterationsButton = false;

  // Tables
  @api hasStandardOrExtraProducts = false;
  @api hasParkingProducts = false;
  @api hasContractTermsProducts = false;
  @api parkingProductsCount = 0;
  @api contractTermsCount = 0;

  @api standardProducts = [];
  @api parkingProducts = [];
  @api contractTermsProducts = [];
  @api displayColumnsStandard = [];
  @api displayColumnsParking = [];
  @api displayColumnsExtra = [];
  @api tableContainerClass = "";
  /** Same as `tableContainerClass` plus `datatable-container--extra-slim` for Extra section tables only. */
  @api tableContainerClassExtra = "";

  @api draftValues = [];
  @api selectedRows = [];
  @api hideCheckboxColumn = false;

  @api sectionEmptyMessage = "";

  get primaryProductsCount() {
    return (this.standardProducts || []).length;
  }

  get primaryProductsHeaderTitle() {
    return "Rooms";
  }

  get primaryProductsIconName() {
    return "utility:apps";
  }

  get primaryProductsHeaderClass() {
    return "products-section-header products-section-header--standard";
  }

  // ─── Per-table totals ─────────────────────────────────────────────────────
  get standardTotalMonthlyAmount() {
    const rows = this.standardProducts || [];
    return rows.reduce((sum, p) => sum + (Number(p?.TotalPrice) || 0), 0);
  }

  get parkingTotalMonthlyAmount() {
    const rows = this.parkingProducts || [];
    return rows.reduce((sum, p) => sum + (Number(p?.TotalPrice) || 0), 0);
  }

  get showStandardMonthlyTotal() {
    return this.primaryProductsCount > 0;
  }

  get showParkingMonthlyTotal() {
    return (this.parkingProductsCount || 0) > 0;
  }

  get showTerminateButton() {
    return !this.hideTerminateButton;
  }

  get showBulkEditButton() {
    return !this.hideBulkEditButton;
  }

  get extraSectionTableClass() {
    const extra = (this.tableContainerClassExtra || "").trim();
    return extra || this.tableContainerClass;
  }

  /**
   * Rooms + Extra combined select/deselect-all (header control). Excludes Contract Terms (meter) section.
   */
  get showSelectAllRoomsAndExtra() {
    if (
      !this.enableDraftEdits ||
      this.hideCheckboxColumn ||
      !this.hasStandardOrExtraProducts
    ) {
      return false;
    }
    const rooms = (this.standardProducts || []).length;
    const extraParking = (this.parkingProducts || []).length;
    return rooms + extraParking > 0;
  }

  get selectAllRoomsExtraTooltipMessage() {
    const base = "Select or deselect all products in Rooms and Extra.";
    return this.showContractTermsSelectAllDisclaimer
      ? `${base} Contract Terms are not included.`
      : base;
  }

  // ─── Toolbar event dispatch ──────────────────────────────────────────────
  handleAddProduct() {
    this.dispatchEvent(this._evt("addproduct"));
  }

  handleReplace() {
    this.dispatchEvent(this._evt("replace"));
  }

  handleOpenMonthlyPayments() {
    this.dispatchEvent(this._evt("openmonthlypayments"));
  }

  handleTerminateProducts() {
    this.dispatchEvent(this._evt("terminateproducts"));
  }

  handleBulkEdit() {
    this.dispatchEvent(this._evt("bulkedit"));
  }

  handleIterations() {
    this.dispatchEvent(this._evt("openiterations"));
  }

  // ─── Table event forwarding ──────────────────────────────────────────────
  handleTableSave(event) {
    this._forward(event, "save");
  }

  handleCellChange(event) {
    this._forward(event, "cellchange");
  }

  handleComboValueChange(event) {
    this._forward(event, "combovaluechange");
  }

  handleFieldPencilClick(event) {
    this._forward(event, "fieldpencilclick");
  }

  handleRowSelectionStandard(event) {
    this._forwardWithSection(event, "rowselection", "standard");
  }

  handleRowSelectionParking(event) {
    this._forwardWithSection(event, "rowselection", "parking");
  }

  handleRowSelectionExtra(event) {
    this._forwardWithSection(event, "rowselection", "contractTerms");
  }

  handleSelectAllRoomsAndExtra() {
    this.dispatchEvent(
      new CustomEvent("selectallroomsandextra", {
        bubbles: true,
        composed: true
      })
    );
  }

  handleRowAction(event) {
    // Same `rowaction` is handled on `c-package-builder-table-custom`, then we re-dispatch from
    // this panel. The original event still bubbles (composed) to `c-package-builder-products-panel`,
    // so the parent would run `onrowaction` twice without stopping propagation here.
    this._forward(event, "rowaction");
    event.stopPropagation();
  }

  _forward(event, name) {
    this.dispatchEvent(
      new CustomEvent(name, {
        detail: event.detail,
        bubbles: true,
        composed: true
      })
    );
  }

  _forwardWithSection(event, name, section) {
    const detail = {
      ...(event?.detail || {}),
      section
    };
    this.dispatchEvent(
      new CustomEvent(name, {
        detail,
        bubbles: true,
        composed: true
      })
    );
  }

  _evt(name) {
    return new CustomEvent(name, { bubbles: true, composed: true });
  }

  /**
   * Viewport bounds of the Products toolbar (for sticky Save/Cancel positioning in the parent).
   * @returns {{ top: number, bottom: number, left: number, right: number, width: number, height: number } | null}
   */
  @api
  getProductsToolbarRect() {
    const el = this.template.querySelector(".products-toolbar");
    if (!el) {
      return null;
    }
    const r = el.getBoundingClientRect();
    return {
      top: r.top,
      bottom: r.bottom,
      left: r.left,
      right: r.right,
      width: r.width,
      height: r.height
    };
  }
}
