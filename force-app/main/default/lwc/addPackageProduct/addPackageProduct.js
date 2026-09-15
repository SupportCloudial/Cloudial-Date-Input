import { LightningElement, api, track, wire } from "lwc";

import getProductsWithPeriod from "@salesforce/apex/AddPackageProductController.getProductsByLocationWithPeriod";
import addProducts from "@salesforce/apex/AddPackageProductController.addProducts";
import getContractAgreementType from "@salesforce/apex/AddPackageProductController.getContractAgreementType";
import addReplacementProduct from "@salesforce/apex/AddPackageProductController.addReplacementProduct";
import getDefaultCpiDateForContext from "@salesforce/apex/AddPackageProductController.getDefaultCpiDateForContext";

import AddProductsLabel from "@salesforce/label/c.PackageBuilder_AddProducts";
import Name from "@salesforce/label/c.AddProductsTbl_Name";
import Floor from "@salesforce/label/c.AddProductsTbl_Floor";
import ListPrice from "@salesforce/label/c.AddProductsTbl_ListPrice";
import None from "@salesforce/label/c.PackageBuilder_None";
import Success from "@salesforce/label/c.AddProducts_Success";
import ErrorLabel from "@salesforce/label/c.AddProducts_Error";
import Saving from "@salesforce/label/c.AddProducts_Saving";
import Type from "@salesforce/label/c.AddProductsFltr_Type";
import TypePH from "@salesforce/label/c.AddProductsFltr_TypePH";
import SubType from "@salesforce/label/c.AddProductsFltr_SubType";
import SubTypePH from "@salesforce/label/c.AddProductsFltr_SubTypePH";
import NameSearch from "@salesforce/label/c.AddProductsFltr_NameSearch";
import NameSearchPH from "@salesforce/label/c.AddProductsFltr_NameSearchPH";
import Availability from "@salesforce/label/c.PackageBuilder_Availability";
import AvailableStatus from "@salesforce/label/c.PackageBuilder_AvailableStatus";
import PartlyAvailableStatus from "@salesforce/label/c.PackageBuilder_PartlyAvailableStatus";
import NotAvailableStatus from "@salesforce/label/c.PackageBuilder_NotAvailableStatus";
import PeriodStartLabel from "@salesforce/label/c.AddProducts_PeriodStart";
import PeriodEndLabel from "@salesforce/label/c.AddProducts_PeriodEnd";
import AccessType from "@salesforce/label/c.PackageBuilder_AccessType";
import AccessTypePHLabel from "@salesforce/label/c.PackageBuilder_AccessTypePH";
import OccupiedFromLabel from "@salesforce/label/c.AddProducts_OccupiedFrom";
import OccupiedTillLabel from "@salesforce/label/c.AddProducts_OccupiedTill";
import OccupiedByLabel from "@salesforce/label/c.AddProducts_OccupiedBy";
import SectionFiltersLabel from "@salesforce/label/c.AddProducts_SectionFilters";
import SectionDefaultsLabel from "@salesforce/label/c.AddProducts_SectionDefaults";
import CpiDateLabel from "@salesforce/label/c.AddProducts_CpiDate";
import TemporaryLabel from "@salesforce/label/c.PackageBuilderTbl_Temporary";

import { getFieldValue, getRecord } from "lightning/uiRecordApi";
import {
  getPicklistValuesByRecordType,
  getObjectInfo
} from "lightning/uiObjectInfoApi";
import OPPORTUNITY_OBJECT from "@salesforce/schema/Opportunity";
import ORDERITEM_PRODUCT_TYPE from "@salesforce/schema/OrderItem.Product2.Type__c";
import ORDERITEM_CPI_DATE from "@salesforce/schema/OrderItem.CPI_Date__c";
import ORDERITEM_ACCESS_TYPE from "@salesforce/schema/OrderItem.Access_Type__c";
import ORDERITEM_SERVICE_DATE from "@salesforce/schema/OrderItem.ServiceDate";
import ORDERITEM_END_DATE from "@salesforce/schema/OrderItem.EndDate";

import {
  accessTypeOptionsFromValues,
  allSelectedProductsSupportAccessType,
  eligibleAccessTypes,
  isMonthlyLike,
  PRODUCT_TYPE_EXTRA_ALL,
  PRODUCT_TYPE_EXTRA_METER,
  PRODUCT_TYPE_STANDARD
} from "c/accessTypePolicy";

const OPP_FIELDS = [
  "Opportunity.RecordTypeId",
  "Opportunity.IsClosed",
  "Opportunity.Pricebook2Id"
];
const ORD_FIELDS = [
  "Order.Status",
  "Order.EffectiveDate",
  "Order.EndDate",
  "Order.Pricebook2Id"
];
const REPLACED_ORDER_ITEM_FIELDS = [
  ORDERITEM_PRODUCT_TYPE,
  ORDERITEM_CPI_DATE,
  ORDERITEM_ACCESS_TYPE,
  ORDERITEM_SERVICE_DATE,
  ORDERITEM_END_DATE
];

/** Mirrors AddPackageProductController date validation messages (no custom labels). */
const MSG_PRODUCT_START_BEFORE_CONTRACT =
  "Product start date cannot be earlier than the contract start date.";
const MSG_PRODUCT_START_BEFORE_OPP =
  "Product start date cannot be earlier than the opportunity start date.";
const MSG_PERIOD_END_BEFORE_CONTRACT_START =
  "Period end date cannot be before the contract start date.";
const MSG_PERIOD_END_BEFORE_PRODUCT_START =
  "Period end date cannot be before product start date.";
const MSG_REPLACE_END_BEFORE_ACTIVE_END =
  "End Date cannot be earlier than the replaced product's End Date. Terminate the product instead.";
/** Matches OpportunityLocationService.MSG_LOCATION_IN_USE_LOCK */
const MSG_LOCATION_IN_USE =
  "This opportunity's location is already in use on this account. Use Change Location to pick a different site or go to the active contract.";

/** Hidden from Type picklist in Package Builder Add Product modal (opp + contract). */
const TYPE_FILTER_EXCLUDED = new Set(["Contract Terms", "On demand Products"]);

export default class AddPackageProduct extends LightningElement {
  labels = {
    AddProducts: AddProductsLabel,
    Name,
    Floor,
    ListPrice,
    None,
    Success,
    Error: ErrorLabel,
    Saving,
    Type,
    TypePH,
    SubType,
    SubTypePH,
    NameSearch,
    NameSearchPH,
    Availability,
    AvailableStatus,
    PartlyAvailableStatus,
    NotAvailableStatus,
    PeriodStart: PeriodStartLabel,
    PeriodEnd: PeriodEndLabel,
    AccessType: AccessType,
    AccessTypePH: AccessTypePHLabel,
    OccupiedFrom: OccupiedFromLabel,
    OccupiedTill: OccupiedTillLabel,
    OccupiedBy: OccupiedByLabel,
    SectionFilters: SectionFiltersLabel,
    SectionDefaults: SectionDefaultsLabel,
    CpiDate: CpiDateLabel,
    Temporary: TemporaryLabel,
    Notes: "Description"
  };

  @api recordId;
  @api objectApiName;
  @api replaceMode = false;
  @api replacedOrderItemId;
  @api replacedPricebookEntryId;
  @api orderEndDate; // Optional: from container when it has order context
  @api orderStartDate;
  /** YYYY-MM-DD: replace mode — parent-computed max(contract start, replaced line start) for Period Start default. */
  @api replaceDefaultPeriodStartYmd;
  /** YYYY-MM-DD from parent in replace mode: draft replaced line end (Period Start max, Period End default). */
  _replacedProductEndDateFromParent;
  @api
  get replacedProductEndDate() {
    return this._replacedProductEndDateFromParent;
  }
  set replacedProductEndDate(value) {
    this._replacedProductEndDateFromParent = value;
    this._syncReplacePeriodEndFromParent();
  }
  /** YYYY-MM-DD: activated/concluded line end floor for Period End min in replace mode (869dbt900). */
  @api replacedActiveEndDateYmd;

  // For filtering, we use Opportunity Picklists.
  // We need a valid RecordTypeId for Opportunity.
  // If we are on Opportunity, we use its RT. If on Order, we use Default RT of Opp.
  oppRecordTypeId;

  /** Open Opportunity with Location_In_Use__c (same rule as server lock). */
  opportunityLocationInUseLocked = false;

  isLoading = false;

  textDirection = "ltr";

  /** Shown inside the modal when add/replace fails (toasts from modal body are often not visible). */
  @track inlineErrorMessage = "";
  @track inlineErrorIsLocationInUse = false;

  @track initialProducts = [];
  @track filteredProducts = [];
  @track selectedRows = [];
  @track draftValues = [];
  selectedRowIds = [];
  unitPriceOverridesByEntryId = {};

  transferPrice = false;

  // Filters
  @track typeOptions = [];
  @track subTypeOptions = [];
  @track allSubTypeOptions = [];
  @track subTypeOptionsMap = [];

  selectedType = "";
  selectedSubType = "";
  searchKey = "";

  // Site (Location) first and Period
  @track siteOptions = [];
  selectedSiteId = "";
  periodStartStr = "";
  periodEndStr = "";

  /** Optional CPI_Date__c applied to all new line items (YYYY-MM-DD). */
  defaultCpiDateStr = "";

  /** Default Temporary__c for new line items when adding products. */
  defaultTemporary = false;
  /** Default Description (Notes) for new line items when adding products. */
  defaultNotes = "";
  /** Parent Opportunity/Order location Id (main site). */
  recordLocationId = "";

  // Access Type filter (applies to all selected products on Add Products)
  @track accessTypeOptions = [];
  selectedAccessType = "";
  contractAgreementType = "";
  userChangedAccessType = false;

  /** YYYY-MM-DD: Order.EffectiveDate or Opportunity.Start_Date__c from wire (minimum product period start). */
  _parentStartYmd = "";

  /** Last non-empty period end from wire or user (restore when leaving Monthly). */
  _wiredPeriodEndDefault = "";
  /** Period end snapshot before switching to Monthly (user-driven). */
  _periodEndBackupOnLeaveMonthly = "";

  minDeskVal = 0;
  maxDeskVal = 30;
  deskVal = this.maxDeskVal;

  get columns() {
    const disabledTooltip = {
      title: { fieldName: "SelectionDisabledTooltip" }
    };
    const base = [
      {
        label: "",
        fieldName: "SelectionDisabledIcon",
        initialWidth: 28,
        sortable: false,
        cellAttributes: {
          title: { fieldName: "SelectionDisabledTooltip" },
          alignment: "center"
        }
      },
      {
        label: this.labels.Name,
        fieldName: "Name",
        cellAttributes: disabledTooltip
      },
      {
        label: this.labels.Floor,
        fieldName: "Floor",
        cellAttributes: disabledTooltip
      },
      {
        label: this.labels.ListPrice,
        fieldName: "UnitPrice",
        type: "currency",
        typeAttributes: { maximumFractionDigits: 2 },
        cellAttributes: {
          alignment: "left",
          class: { fieldName: "UnitPriceCellClass" },
          ...disabledTooltip
        },
        editable: true,
        initialWidth: 145
      }
    ];
    if (
      this.showOccupancyColumns &&
      this.periodStartStr &&
      (this.periodEndStr || this.selectedAccessType === "Monthly")
    ) {
      base.push({
        label: this.labels.OccupiedFrom,
        fieldName: "OccupiedFrom",
        type: "date-local",
        typeAttributes: {
          day: "2-digit",
          month: "2-digit",
          year: "numeric",
          timeZone: "UTC"
        },
        cellAttributes: {
          class: { fieldName: "OccupiedFromCellClass" },
          ...disabledTooltip
        }
      });
      base.push({
        label: this.labels.OccupiedTill,
        fieldName: "OccupiedTill",
        type: "date-local",
        typeAttributes: {
          day: "2-digit",
          month: "2-digit",
          year: "numeric",
          timeZone: "UTC"
        },
        cellAttributes: {
          class: { fieldName: "OccupiedTillCellClass" },
          ...disabledTooltip
        }
      });
      base.push({
        label: this.labels.OccupiedBy,
        fieldName: "OccupyingAccountUrl",
        type: "url",
        typeAttributes: {
          label: { fieldName: "OccupyingAccountName" },
          target: "_blank" // open Account record in a new tab
        },
        cellAttributes: disabledTooltip
      });
    }
    return base;
  }

  get showOccupancyColumns() {
    return false;
  }


  // Site/location catalog removed for commercial package.

  loadProducts() {
    if (!this.recordId) return;
    this.isLoading = true;
    this._notifySelectionState();
    getProductsWithPeriod({
      recordId: this.recordId,
      locationId: null,
      periodStartStr: this.periodStartStr || null,
      periodEndStr: this.periodEndStr || null
    })
      .then((data) => {
        const raw = data || [];
        this.initialProducts = raw.map((p) => this._decorateProductRow(p));
        this._decorateRowsWithSelectionState();
        this.filterProducts();
        this._rebuildAccessTypeOptionsFromSelection();
      })
      .catch((err) => {
        console.error("AddPackageProduct - Error fetching products:", err);
      })
      .finally(() => {
        this.isLoading = false;
        this._notifySelectionState();
      });
  }

  _dateToYmd(value) {
    if (!value) return "";
    if (value instanceof Date) return this._formatDateForApex(value);
    if (typeof value === "string") {
      const s = value.trim();
      // Apex: YYYY-MM-DD or YYYY-MM-DD HH:MM:SS
      const iso = s.slice(0, 10);
      if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
      // DD/MM/YYYY (e.g. from locale display)
      const dmy = s.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
      if (dmy) {
        const [, day, month, year] = dmy;
        return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
      }
      try {
        const d = new Date(s);
        return isNaN(d.getTime()) ? "" : this._formatDateForApex(d);
      } catch {
        return "";
      }
    }
    return "";
  }

  _isYmdInRange(ymd, startYmd, endYmd) {
    if (!ymd || !startYmd || !endYmd) return false;
    // YYYY-MM-DD lexical compare is safe
    return ymd >= startYmd && ymd <= endYmd;
  }

  /** Open-ended period (e.g. Monthly): highlight when date is on/after period start (YYYY-MM-DD compare). */
  _isYmdOnOrAfter(ymd, startYmd) {
    if (!ymd || !startYmd) return false;
    return ymd >= startYmd;
  }

  _decorateOccupancyCells(product) {
    const periodStart = this.periodStartStr || "";
    const periodEnd = this.periodEndStr || "";
    const occupiedFrom = this._dateToYmd(product?.OccupiedFrom);
    const occupiedTill = this._dateToYmd(product?.OccupiedTill);

    const openEndedPeriod = !periodEnd;
    const inFromRange = openEndedPeriod
      ? this._isYmdOnOrAfter(occupiedFrom, periodStart)
      : this._isYmdInRange(occupiedFrom, periodStart, periodEnd);
    const inTillRange = openEndedPeriod
      ? this._isYmdOnOrAfter(occupiedTill, periodStart)
      : this._isYmdInRange(occupiedTill, periodStart, periodEnd);

    // Use SLDS theme class so styling applies inside lightning-datatable's shadow DOM
    const inRangeClass = "slds-theme_warning";
    const accountId = product?.OccupyingAccountId;
    const name = product?.OccupyingAccountName;
    // Full URL so the link works when the component is in a modal; open in new tab to avoid modal/iframe issues
    const occupyingAccountUrl = accountId
      ? `${typeof window !== "undefined" ? window.location.origin : ""}/lightning/r/Account/${accountId}/view`
      : name
        ? "#"
        : "";
    return {
      ...product,
      OccupiedFromCellClass: inFromRange ? inRangeClass : "",
      OccupiedTillCellClass: inTillRange ? inRangeClass : "",
      SelectionDisabledTooltip: "",
      SelectionDisabledIcon: "",
      OccupyingAccountUrl: occupyingAccountUrl
    };
  }

  _rebuildAccessTypeOptionsFromSelection() {
    const selectedIds = new Set(this.selectedRowIds || []);
    const selectedRows = (this.initialProducts || []).filter((p) =>
      selectedIds.has(p.Id)
    );
    const typeFilter = (this.selectedType || "").trim();
    let allowed = new Set(["Monthly", "Periodic"]);

    if (typeFilter === PRODUCT_TYPE_STANDARD) {
      allowed = new Set(eligibleAccessTypes(PRODUCT_TYPE_STANDARD, true));
      if (selectedRows.length) {
        const allRentEligible = selectedRows.every(
          (p) => p.RentEligible === true
        );
        allowed = new Set(
          eligibleAccessTypes(PRODUCT_TYPE_STANDARD, allRentEligible)
        );
      }
    } else if (typeFilter === PRODUCT_TYPE_EXTRA_ALL) {
      allowed = new Set(eligibleAccessTypes(PRODUCT_TYPE_EXTRA_ALL, false));
    } else if (typeFilter === PRODUCT_TYPE_EXTRA_METER) {
      allowed = new Set(eligibleAccessTypes(PRODUCT_TYPE_EXTRA_METER, false));
    } else if (selectedRows.length) {
      const union = new Set();
      selectedRows.forEach((p) => {
        eligibleAccessTypes(p.ProductType, p.RentEligible === true).forEach(
          (t) => union.add(t)
        );
      });
      if (union.size) {
        allowed = union;
      }
    }

    const options = accessTypeOptionsFromValues([...allowed]);
    this.accessTypeOptions = options;
    if (this.selectedAccessType && !allowed.has(this.selectedAccessType)) {
      this.selectedAccessType = "";
    }
  }

  _decorateProductRow(product) {
    const rawPrice = this.unitPriceOverridesByEntryId[product?.Id];
    const normalizedPrice =
      rawPrice !== undefined && rawPrice !== null
        ? Number(rawPrice)
        : product?.UnitPrice;
    return this._decorateOccupancyCells({
      ...product,
      UnitPrice: Number.isFinite(normalizedPrice)
        ? normalizedPrice
        : product?.UnitPrice
    });
  }

  _decorateRowsWithSelectionState() {
    const selected = new Set(this.selectedRowIds || []);
    const decorate = (row) => {
      const canEdit = selected.has(row.Id);
      return {
        ...row,
        UnitPriceCellClass: canEdit
          ? "pb-unitprice-edit-enabled"
          : "pb-unitprice-edit-disabled"
      };
    };
    this.initialProducts = (this.initialProducts || []).map(decorate);
    this.filteredProducts = (this.filteredProducts || []).map(decorate);
  }

  // Get Current Record Info - also set default Site and Period
  @wire(getRecord, { recordId: "$recordId", fields: "$computedFields" })
  wiredRecord({ error, data }) {
    if (data) {
      if (data.apiName === "Opportunity" && data.fields.RecordTypeId) {
        this.oppRecordTypeId = data.fields.RecordTypeId.value;
      }
      this._parentStartYmd = "";
      this.recordLocationId = "";
      if (!this.replaceMode) {
        this.selectedSiteId = "";
      }
      this._syncTemporaryDefaultForSelectedSite();
      // Default Period: Order = Order_Start_Date__c (else EffectiveDate) / EndDate; Opportunity = Start_Date__c (else today) / today+365
      // Replace mode (Order): Period Start defaults from orderStartDate API / wire; Package Builder may pass replaceDefaultPeriodStartYmd (max of contract start and replaced line).
      // Replace mode Period End: replaced line end when Periodic; Monthly matches add mode (no default end).
      const today = this._formatDateForApex(new Date());
      if (data.apiName === "Order") {
        const orderStartWire =
          data.fields.Order_Start_Date__c &&
          data.fields.Order_Start_Date__c.value
            ? data.fields.Order_Start_Date__c
            : data.fields.EffectiveDate;
        if (orderStartWire && orderStartWire.value) {
          this._parentStartYmd = this._formatDateForApex(
            new Date(orderStartWire.value)
          );
        }
        const orderEndYmd =
          data.fields.EndDate && data.fields.EndDate.value
            ? this._formatDateForApex(new Date(data.fields.EndDate.value))
            : "";
        if (this.replaceMode) {
          const startDefault =
            (this.orderStartDate || "").trim() ||
            (this._parentStartYmd || "").trim() ||
            today;
          this.periodStartStr = startDefault;
          if (this.replacedProductEndDate) {
            this.periodEndStr = this.replacedProductEndDate;
          } else {
            this.periodEndStr = "";
          }
        } else if (orderStartWire && orderStartWire.value) {
          this.periodStartStr = this._formatDateForApex(
            new Date(orderStartWire.value)
          );
          if (orderEndYmd) {
            this.periodEndStr = orderEndYmd;
          } else {
            const d = new Date();
            d.setFullYear(d.getFullYear() + 1);
            this.periodEndStr = this._formatDateForApex(d);
          }
        } else {
          this.periodStartStr = today;
          if (orderEndYmd) {
            this.periodEndStr = orderEndYmd;
          } else {
            const d = new Date();
            d.setFullYear(d.getFullYear() + 1);
            this.periodEndStr = this._formatDateForApex(d);
          }
        }
      } else {
        const oppStart =
          data.fields.Start_Date__c && data.fields.Start_Date__c.value
            ? this._formatDateForApex(new Date(data.fields.Start_Date__c.value))
            : "";
        const oppEnd =
          data.fields.End_Date__c && data.fields.End_Date__c.value
            ? this._formatDateForApex(new Date(data.fields.End_Date__c.value))
            : "";
        this._parentStartYmd = oppStart || "";
        this.periodStartStr = this.replaceMode ? today : oppStart || today;
        if (this.replaceMode && this.replacedProductEndDate) {
          this.periodEndStr = this.replacedProductEndDate;
        } else if (!this.replaceMode) {
          this.periodEndStr = oppEnd || "";
          if (!this.periodEndStr) {
            const d = new Date();
            d.setFullYear(d.getFullYear() + 1);
            this.periodEndStr = this._formatDateForApex(d);
          }
        } else {
          this.periodEndStr = "";
        }
      }
      // `orderStartDate` / `orderEndDate` from Package Builder override wire defaults (draft bounds, parent-aligned start).
      if (this.orderStartDate) {
        this.periodStartStr = this.orderStartDate;
      }
      const replaceDefault = (this.replaceDefaultPeriodStartYmd || "").trim();
      if (this.replaceMode && replaceDefault) {
        this.periodStartStr = replaceDefault;
      }
      if (!this.replaceMode && this.orderEndDate) {
        this.periodEndStr = this.orderEndDate;
      }
      this._wiredPeriodEndDefault = this.periodEndStr || "";
      if (this.selectedAccessType === "Monthly" && this.periodEndStr) {
        if (!this.replaceMode) {
          this._periodEndBackupOnLeaveMonthly = this.periodEndStr;
        }
        this.periodEndStr = "";
        this._wiredPeriodEndDefault = "";
      }
      this._clampPeriodEndToStartIfNeeded();
      this.opportunityLocationInUseLocked = false;
      // Replace: wait for replaced line wire before loading catalog.
      if (!this.replaceMode || this.selectedSiteId) {
        this.loadProducts();
      }
    } else if (error) {
      console.error("Error fetching record:", JSON.stringify(error));
      // Still load catalog — period defaults can come from parent @api props.
      if (!this.replaceMode) {
        const today = this._formatDateForApex(new Date());
        if (!this.periodStartStr) {
          this.periodStartStr = this.orderStartDate || today;
        }
        if (!this.periodEndStr && this.orderEndDate) {
          this.periodEndStr = this.orderEndDate;
        }
        this.loadProducts();
      }
    }
  }

  _formatDateForApex(d) {
    if (!d || !(d instanceof Date)) return "";
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  }

  /** Latest of two YYYY-MM-DD strings; null if both unset. */
  _maxYmd(a, b) {
    const na = (a || "").trim();
    const nb = (b || "").trim();
    if (!na) return nb || null;
    if (!nb) return na;
    return na >= nb ? na : nb;
  }

  /** When Period Start is after Period End, align end to start (defaults and user start edits). */
  _clampPeriodEndToStartIfNeeded() {
    if (this.selectedAccessType === "Monthly") return;
    const ps = (this.periodStartStr || "").trim();
    const pe = (this.periodEndStr || "").trim();
    if (ps && pe && ps > pe) {
      this.periodEndStr = ps;
      this._wiredPeriodEndDefault = ps;
    }
  }

  /** Min date for Period Start: parent order/opportunity start (replace on Order uses same floor as Add). */
  get periodStartMinYmd() {
    const rid = this.recordId ? String(this.recordId) : "";
    const isOrder =
      this.effectiveObjectApiName === "Order" || rid.startsWith("801");
    if (this.replaceMode && !isOrder) {
      return undefined;
    }
    const min = (this.orderStartDate || this._parentStartYmd || "").trim();
    return min || undefined;
  }

  /** Max date for Period Start in replace mode: replaced line end; open-ended when Monthly has no end. */
  get periodStartMaxYmd() {
    if (!this.replaceMode) return undefined;
    const replacedEnd = (this.replacedProductEndDate || "").trim();
    if (replacedEnd) return replacedEnd;
    if (this.selectedAccessType === "Monthly") return undefined;
    return undefined;
  }

  /** Activated/concluded line end only (Period End min); omit draft end when active floor is unset. */
  _replaceActiveEndFloorYmd() {
    return (this.replacedActiveEndDateYmd || "").trim() || null;
  }

  /** Package Builder Order replace: parent draft end wins over persisted OrderItem wire. */
  _syncReplacePeriodEndFromParent() {
    if (this.replaceMode !== true) {
      return;
    }
    const rid = this.recordId ? String(this.recordId) : "";
    const isOrderRecord =
      this.effectiveObjectApiName === "Order" || rid.startsWith("801");
    if (!isOrderRecord) {
      return;
    }
    const draftEnd = (this.replacedProductEndDate || "").trim();
    if (!draftEnd) {
      return;
    }
    if (this.selectedAccessType === "Monthly") {
      this.periodEndStr = "";
    } else {
      this.periodEndStr = draftEnd;
    }
    this._wiredPeriodEndDefault = this.periodEndStr || "";
    this._clampPeriodEndToStartIfNeeded();
  }

  /** Min date for Period End: latest of contract/order floor, active replace floor, and Period Start. */
  get periodEndMinYmd() {
    let floor = this.periodStartMinYmd || null;
    if (this.replaceMode) {
      floor = this._maxYmd(floor, this._replaceActiveEndFloorYmd());
    }
    return this._maxYmd(floor, (this.periodStartStr || "").trim()) || undefined;
  }

  /**
   * Client-side validation aligned with AddPackageProductController (order + opportunity).
   * Replace flow uses Order context only in Package Builder.
   */
  _validatePeriodForAddAndReplace() {
    const minS = (this.orderStartDate || this._parentStartYmd || "").trim();
    const ps = (this.periodStartStr || "").trim();
    const pe = (this.periodEndStr || "").trim();
    const rid = this.recordId ? String(this.recordId) : "";
    const isOrder = this.objectApiName === "Order" || rid.startsWith("801");

    if (minS && ps && ps < minS) {
      return rid.startsWith("006")
        ? MSG_PRODUCT_START_BEFORE_OPP
        : MSG_PRODUCT_START_BEFORE_CONTRACT;
    }
    if (isOrder && minS && pe && pe < minS) {
      return MSG_PERIOD_END_BEFORE_CONTRACT_START;
    }
    if (ps && pe && pe < ps) {
      return MSG_PERIOD_END_BEFORE_PRODUCT_START;
    }
    if (this.replaceMode) {
      const activeFloor = this._replaceActiveEndFloorYmd();
      if (activeFloor && pe && pe < activeFloor) {
        return MSG_REPLACE_END_BEFORE_ACTIVE_END;
      }
    }
    return "";
  }

  _inRangeStyleId = "add-products-in-range-hover-style";

  /** @type {MutationObserver|null} */
  _deskSliderObserver = null;
  /** @type {Element|null} */
  _deskSliderObservedEl = null;
  /** @type {ReturnType<typeof setTimeout>|null} */
  _deskSliderPatchDebounce = null;

  /** @type {ReturnType<typeof setTimeout>|null} */
  _inlineErrorClearTimer = null;

  connectedCallback() {
    this.textDirection =
      typeof document !== "undefined" && document.documentElement.dir === "rtl"
        ? "rtl"
        : "ltr";

    this._notifySelectionState();
    this._injectInRangeHoverStyle();
  }

  renderedCallback() {
    // lightning-slider value may live in nested shadow roots; schedule patches after layout.
    this._scheduleDeskSliderPatch();
  }

  disconnectedCallback() {
    this._clearInlineErrorTimer();
    this._disconnectDeskSliderMutationObserver();
    try {
      // eslint-disable-next-line @lwc/lwc/no-document-query
      const el = document.getElementById(this._inRangeStyleId);
      if (el) el.remove();
    } catch {
      /* Locker / strict doc access should not break teardown */
    }
  }

  _clearInlineErrorTimer() {
    if (this._inlineErrorClearTimer != null) {
      clearTimeout(this._inlineErrorClearTimer);
      this._inlineErrorClearTimer = null;
    }
  }

  /** Show inline alert and auto-clear after 5s (dismiss without requiring user click). */
  _setInlineError(message) {
    this._clearInlineErrorTimer();
    this.inlineErrorIsLocationInUse = message === MSG_LOCATION_IN_USE;
    this.inlineErrorMessage = message || "";
    if (this.inlineErrorMessage) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this._inlineErrorClearTimer = setTimeout(() => {
        this._inlineErrorClearTimer = null;
        this.inlineErrorMessage = "";
        this.inlineErrorIsLocationInUse = false;
      }, 5000);
    }
  }

  _clearInlineErrorBanner() {
    this._clearInlineErrorTimer();
    this.inlineErrorMessage = "";
    this.inlineErrorIsLocationInUse = false;
  }

  _disconnectDeskSliderMutationObserver() {
    if (this._deskSliderObserver) {
      try {
        this._deskSliderObserver.disconnect();
      } catch {
        /* ignore */
      }
      this._deskSliderObserver = null;
    }
    this._deskSliderObservedEl = null;
    if (this._deskSliderPatchDebounce != null) {
      clearTimeout(this._deskSliderPatchDebounce);
      this._deskSliderPatchDebounce = null;
    }
  }

  /**
   * Microtask + double rAF + macrotask so patch runs after platform updates the slider label.
   */
  _scheduleDeskSliderPatch() {
    const run = () => this._patchDeskSliderValueDisplay();
    Promise.resolve().then(run);
    if (typeof requestAnimationFrame === "function") {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      requestAnimationFrame(() => {
        run();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(run);
      });
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(run, 0);
  }

  _ensureDeskSliderMutationObserver(slider) {
    if (!slider?.shadowRoot) {
      return;
    }
    if (this._deskSliderObservedEl === slider && this._deskSliderObserver) {
      return;
    }
    this._disconnectDeskSliderMutationObserver();
    this._deskSliderObservedEl = slider;
    try {
      this._deskSliderObserver = new MutationObserver(() => {
        if (this._deskSliderPatchDebounce != null) {
          clearTimeout(this._deskSliderPatchDebounce);
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._deskSliderPatchDebounce = setTimeout(() => {
          this._deskSliderPatchDebounce = null;
          this._patchDeskSliderValueDisplay();
        }, 0);
      });
      this._deskSliderObserver.observe(slider.shadowRoot, {
        subtree: true,
        childList: true,
        characterData: true
      });
    } catch {
      this._deskSliderObserver = null;
      this._deskSliderObservedEl = null;
    }
  }
  _injectInRangeHoverStyle() {
    try {
      if (typeof document === "undefined" || !document.head) return;
      // eslint-disable-next-line @lwc/lwc/no-document-query
      if (document.getElementById(this._inRangeStyleId)) return;
      const style = document.createElement("style");
      style.id = this._inRangeStyleId;
      style.textContent =
        "td.slds-theme_warning, tr:hover td.slds-theme_warning { background-color: #fff3b0 !important; }" +
        "td.pb-unitprice-edit-disabled button.slds-cell-edit__button { opacity: 0 !important; pointer-events: none !important; }";
      document.head.appendChild(style);
    } catch {
      /* Global style for datatable shadow DOM; skip if document APIs are unavailable */
    }
  }

  // Get Opportunity Object Info to get Default RecordTypeId (Fallback)
  @wire(getObjectInfo, { objectApiName: OPPORTUNITY_OBJECT })
  oppObjectInfo;

  @wire(getContractAgreementType, { recordId: "$recordId" })
  wiredContractAgreementType({ error, data }) {
    if (this.replaceMode) return;
    this.contractAgreementType = data ? String(data).trim() : "";
    this._applyContractAgreementTypeDefault();
    if (error) {
      // Non-blocking: access type will stay blank if we can't resolve the contract agreement type.
      console.error(
        "AddPackageProduct - Error fetching Contract agreement type",
        JSON.stringify(error)
      );
    }
  }

  get computedFields() {
    const apiName = this.effectiveObjectApiName;
    if (apiName === "Opportunity") return OPP_FIELDS;
    if (apiName === "Order") return ORD_FIELDS;
    return undefined;
  }

  get effectiveObjectApiName() {
    if (
      this.objectApiName === "Opportunity" ||
      this.objectApiName === "Order"
    ) {
      return this.objectApiName;
    }
    const rid = this.recordId ? String(this.recordId) : "";
    if (rid.startsWith("006")) return "Opportunity";
    if (rid.startsWith("801")) return "Order";
    return null;
  }

  /** Show CPI Date default field in contract/order and opportunity contexts. */
  get showOrderCpiDateField() {
    return this.effectiveObjectApiName === "Order";
  }

  /** Temporary default checkbox: Opportunity always; Order/Contract Add (not Replace). */
  get showTemporaryDefault() {
    if (this.replaceMode) {
      return false;
    }
    const objectApi = this.effectiveObjectApiName;
    return objectApi === "Opportunity" || objectApi === "Order";
  }

  /** Notes default: same surfaces as Temporary (Add only, Opportunity and Order). */
  get showNotesDefault() {
    return this.showTemporaryDefault;
  }

  get showOpportunityTemporaryDefault() {
    return this.showTemporaryDefault;
  }

  /** Site selectable on Opportunity and Order/Contract Add; Replace stays locked. */
  get isSiteSelectionDisabled() {
    return true;
  }

  get isOtherSiteSelected() {
    return false;
  }

  get isTemporaryDefaultLocked() {
    return false;
  }

  /** Other-site Temporary help on Opportunity and Order/Contract Add. */
  get showTemporaryOtherSiteHelp() {
    return false;
  }

  _syncTemporaryDefaultForSelectedSite() {
    // Opp + Order/Contract Add: other-site → true+locked; same-site → reset false (optional).
    if (!this.showTemporaryDefault) {
      return;
    }
    this.defaultTemporary = this.isTemporaryDefaultLocked;
  }

  get isPeriodEndDisabled() {
    return isMonthlyLike(this.selectedAccessType);
  }

  // Compute the RecordTypeId to use for Picklist Values
  get computedRecordTypeId() {
    if (this.oppRecordTypeId) return this.oppRecordTypeId;
    if (this.oppObjectInfo && this.oppObjectInfo.data) {
      return this.oppObjectInfo.data.defaultRecordTypeId;
    }
    return undefined; // Use undefined to prevent wire calling prematurely
  }

  @wire(getPicklistValuesByRecordType, {
    objectApiName: OPPORTUNITY_OBJECT,
    recordTypeId: "$computedRecordTypeId"
  })
  picklistValues({ error, data }) {
    if (data) {
      console.log("Fetched picklist values successfully");
      const pfv = data.picklistFieldValues || {};
      const parsedTypes = this.parsePicklist(pfv.Product_Type__c).filter(
        (o) => o && !TYPE_FILTER_EXCLUDED.has(o.value)
      );
      this.typeOptions = [
        { label: this.labels.None, value: "" },
        ...parsedTypes
      ];
      const subTypePfv = pfv.Product_Sub_Type__c;
      this.allSubTypeOptions =
        subTypePfv && subTypePfv.controllerValues != null
          ? subTypePfv.controllerValues
          : {};
      this.subTypeOptionsMap =
        subTypePfv && Array.isArray(subTypePfv.values) ? subTypePfv.values : [];

      // Access Type options are computed from selected products + type filter.
      this._rebuildAccessTypeOptionsFromSelection();
      this._applyContractAgreementTypeDefault();
      if (this.replaceMode === true && this.selectedType) {
        this._rebuildSubTypeOptions();
        this.filterProducts();
      }
    } else if (error) {
      console.error("Error fetching picklist values", JSON.stringify(error));
    }
  }

  /** 869ddxhe8: default CPI date from the parent context (Order/Contract/Opportunity).
   *  Only seeds defaultCpiDateStr when empty and not in replace mode (replace mode keeps
   *  seeding from the replaced OrderItem in wiredReplacedOrderItem).
   */
  @wire(getDefaultCpiDateForContext, { recordId: "$recordId" })
  wiredDefaultCpiDate({ data, error }) {
    if (error) {
      console.warn("getDefaultCpiDateForContext failed", JSON.stringify(error));
      return;
    }
    if (this.replaceMode === true) return;
    if (this.defaultCpiDateStr) return;
    if (!data) return;
    this.defaultCpiDateStr = String(data).slice(0, 10);
  }

  @wire(getRecord, {
    recordId: "$replacedOrderItemId",
    fields: REPLACED_ORDER_ITEM_FIELDS
  })
  wiredReplacedOrderItem({ error, data }) {
    if (this.replaceMode !== true) return;
    if (data) {
      const replacedType = String(
        getFieldValue(data, ORDERITEM_PRODUCT_TYPE) || ""
      ).trim();
      this._forceTypeForReplace(replacedType);
      const replacedCpiDate = getFieldValue(data, ORDERITEM_CPI_DATE);
      this.defaultCpiDateStr = replacedCpiDate ? String(replacedCpiDate) : "";
      const replacedAccessType = String(
        getFieldValue(data, ORDERITEM_ACCESS_TYPE) || ""
      ).trim();
      if (replacedAccessType) {
        this.selectedAccessType = replacedAccessType;
      }
      this.selectedSiteId = this.recordLocationId || "";
      this._syncTemporaryDefaultForSelectedSite();
      const replacedServiceDate = getFieldValue(data, ORDERITEM_SERVICE_DATE);
      const replacedEndDate = getFieldValue(data, ORDERITEM_END_DATE);
      const replacedServiceYmd = replacedServiceDate
        ? String(replacedServiceDate).slice(0, 10)
        : "";
      const replacedEndYmd = replacedEndDate
        ? String(replacedEndDate).slice(0, 10)
        : "";
      // Order replace (Package Builder): Period Start from orderStartDate / replaceDefaultPeriodStartYmd; do not use replaced line ServiceDate alone (wire still loads type/CPI for replace).
      const rid = this.recordId ? String(this.recordId) : "";
      const isOrderRecord =
        this.effectiveObjectApiName === "Order" || rid.startsWith("801");
      if (replacedServiceYmd && !isOrderRecord) {
        this.periodStartStr = replacedServiceYmd;
      }
      if (isOrderRecord) {
        this._syncReplacePeriodEndFromParent();
        if (
          !this.periodEndStr &&
          replacedEndYmd &&
          this.selectedAccessType !== "Monthly"
        ) {
          this.periodEndStr = replacedEndYmd;
          this._wiredPeriodEndDefault = this.periodEndStr || "";
          this._clampPeriodEndToStartIfNeeded();
        }
      } else {
        // Periodic: default Period End from replaced line. Monthly: same as add mode — no end date.
        this.periodEndStr =
          this.selectedAccessType === "Monthly" ? "" : replacedEndYmd;
        this._wiredPeriodEndDefault = this.periodEndStr || "";
        this._clampPeriodEndToStartIfNeeded();
      }
      if (this.selectedAccessType === "Monthly") {
        this._clearInlineErrorBanner();
        this._redecorateLoadedProductsForPeriod();
      }
      this.loadProducts();
    } else if (error) {
      console.error(
        "AddPackageProduct - Error fetching replaced OrderItem:",
        JSON.stringify(error)
      );
    }
  }

  _applyContractAgreementTypeDefault() {
    if (this.replaceMode) return;
    if (this.userChangedAccessType) return;
    const v = (this.contractAgreementType || "").trim();
    if (!v) return;
    // Package Builder only supports Monthly/Periodic for Access Type.
    const normalized = v.toLowerCase();
    if (normalized !== "monthly" && normalized !== "periodic") return;

    // Only auto-default until the user changes the combobox.
    if (!this.selectedAccessType) {
      this.selectedAccessType = v;
    }

    // If Access Type options haven't loaded yet, they will include Monthly/Periodic once wired.
    if (
      this.selectedAccessType === "Monthly" &&
      !this.replaceMode &&
      this.periodEndStr
    ) {
      this._periodEndBackupOnLeaveMonthly = this.periodEndStr;
      this.periodEndStr = "";
      this._clearInlineErrorBanner();
      this._redecorateLoadedProductsForPeriod();
      this.loadProducts();
    }
  }

  parsePicklist(picklistField) {
    if (!picklistField || !Array.isArray(picklistField.values)) {
      return [];
    }
    return picklistField.values.map((item) => ({
      label: item.label,
      value: item.value
    }));
  }

  get isTypeDisabled() {
    return this.replaceMode === true;
  }

  _forceTypeForReplace(replacedType) {
    const forcedType =
      replacedType === PRODUCT_TYPE_EXTRA_ALL
        ? PRODUCT_TYPE_EXTRA_ALL
        : PRODUCT_TYPE_STANDARD;
    const changed = this.selectedType !== forcedType;
    this.selectedType = forcedType;
    if (changed) {
      this.selectedSubType = "";
      this._rebuildSubTypeOptions();
      this.updateSelection();
      this.filterProducts();
    } else {
      // Ensure Sub Type options are consistent after async wire ordering.
      this._rebuildSubTypeOptions();
      this.filterProducts();
    }
  }

  _rebuildSubTypeOptions() {
    this.selectedSubType = "";
    const controllerValue = this.allSubTypeOptions
      ? this.allSubTypeOptions[this.selectedType]
      : undefined;
    const subMap = Array.isArray(this.subTypeOptionsMap)
      ? this.subTypeOptionsMap
      : [];
    if (controllerValue !== undefined && controllerValue !== "") {
      this.subTypeOptions = subMap
        .filter(
          (opt) =>
            opt &&
            Array.isArray(opt.validFor) &&
            opt.validFor.includes(controllerValue)
        )
        .map((item) => ({
          label: item.label,
          value: item.value
        }));

      this.subTypeOptions = [
        { label: this.labels.None, value: "" },
        ...this.subTypeOptions
      ];
    } else {
      this.subTypeOptions = [];
    }
  }

  handleTypeChange(event) {
    if (this.isTypeDisabled) return;
    this.selectedType = event.detail.value;
    this._rebuildSubTypeOptions();

    this.updateSelection();
    this.filterProducts();
    this._rebuildAccessTypeOptionsFromSelection();
  }

  handleSubTypeChange(event) {
    this.selectedSubType = event.detail.value;
    this.updateSelection();
    this.filterProducts();
  }

  handleSiteChange(event) {
    this.selectedSiteId = event.detail.value || "";
    this._syncTemporaryDefaultForSelectedSite();
    this.loadProducts();
  }

  handlePeriodStartChange(event) {
    this.periodStartStr = event.detail?.value ?? event.target?.value ?? "";
    this._clampPeriodEndToStartIfNeeded();
    this._clearInlineErrorBanner();
    this._redecorateLoadedProductsForPeriod();
    this.loadProducts();
  }

  handlePeriodEndChange(event) {
    this.periodEndStr = event.detail?.value ?? event.target?.value ?? "";
    this._wiredPeriodEndDefault = this.periodEndStr || "";
    this._clearInlineErrorBanner();
    this._redecorateLoadedProductsForPeriod();
    this.loadProducts();
  }

  handleTemporaryDefaultChange(event) {
    if (this.isTemporaryDefaultLocked) {
      this.defaultTemporary = true;
      return;
    }
    this.defaultTemporary = event.target.checked === true;
  }

  handleNotesDefaultChange(event) {
    this.defaultNotes = event.detail?.value ?? event.target?.value ?? "";
  }

  handleAccessTypeChange(event) {
    const prior = this.selectedAccessType;
    const next = event.detail.value || "";
    this.selectedAccessType = next;
    this.userChangedAccessType = true;
    if (isMonthlyLike(next) && !isMonthlyLike(prior) && !this.replaceMode) {
      this._periodEndBackupOnLeaveMonthly = this.periodEndStr || "";
      this.periodEndStr = "";
      this._clearInlineErrorBanner();
      this._redecorateLoadedProductsForPeriod();
      this.loadProducts();
    } else if (
      isMonthlyLike(prior) &&
      !isMonthlyLike(next) &&
      !this.replaceMode
    ) {
      if (this._periodEndBackupOnLeaveMonthly) {
        this.periodEndStr = this._periodEndBackupOnLeaveMonthly;
      } else if (this.orderEndDate) {
        this.periodEndStr = String(this.orderEndDate).slice(0, 10);
      } else {
        this.periodEndStr = this._wiredPeriodEndDefault || "";
      }
      this._clampPeriodEndToStartIfNeeded();
      this._clearInlineErrorBanner();
      this._redecorateLoadedProductsForPeriod();
      this.loadProducts();
    }
  }

  handleCpiDateChange(event) {
    this.defaultCpiDateStr = event.detail?.value ?? event.target?.value ?? "";
  }

  _redecorateLoadedProductsForPeriod() {
    // Re-evaluate cell highlighting against the current period without requiring a refetch.
    // We still call loadProducts() after changes, but this provides immediate UI feedback.
    if (
      Array.isArray(this.initialProducts) &&
      this.initialProducts.length > 0
    ) {
      this.initialProducts = this.initialProducts.map((p) =>
        this._decorateProductRow(p)
      );
    }
    if (
      Array.isArray(this.filteredProducts) &&
      this.filteredProducts.length > 0
    ) {
      this.filteredProducts = this.filteredProducts.map((p) =>
        this._decorateProductRow(p)
      );
    }
    this._decorateRowsWithSelectionState();
  }

  handleSearchKeyChange(event) {
    const raw = event && event.detail ? event.detail.value : "";
    this.updateSearchKey(raw);
  }

  @api
  updateSearchKey(raw) {
    this.searchKey = String(raw || "").toLowerCase();
    this.updateSelection();
    this.filterProducts();
  }

  updateSelection() {
    const dt = this.template.querySelector('[data-id="datatable"]');
    if (dt) dt.selectedRows = this.selectedRowIds;
  }

  filterProducts() {
    this.filteredProducts = this.initialProducts.filter((product) => {
      const typeMatch = this.selectedType
        ? product.ProductType === this.selectedType
        : true;
      const subTypeMatch = this.selectedSubType
        ? product.ProductSubType === this.selectedSubType
        : true;
      const nameStr = (
        product && product.Name != null ? String(product.Name) : ""
      ).toLowerCase();
      const nameMatch = this.searchKey
        ? nameStr.includes(this.searchKey)
        : true;
      const desksMatch = true;
      const rentMatch =
        this.replaceMode === true && this.selectedAccessType === "Rent"
          ? product.RentEligible === true
          : true;

      return typeMatch && subTypeMatch && nameMatch && desksMatch && rentMatch;
    });
    const visibleIds = new Set(
      (this.filteredProducts || []).map((product) => product.Id)
    );
    this.selectedRowIds = (this.selectedRowIds || []).filter((id) =>
      visibleIds.has(id)
    );
    this._decorateRowsWithSelectionState();
  }

  get disableSubTypeOptions() {
    return this.subTypeOptions.length === 0;
  }

  get selectedRowIdsArray() {
    return this.selectedRowIds;
  }

  _applyDraftValues(drafts, showErrors) {
    const incoming = Array.isArray(drafts) ? drafts : [];
    const selected = new Set(this.selectedRowIds || []);
    const validDrafts = [];
    const blocked = [];
    const invalid = [];
    const accepted = [];

    incoming.forEach((draft) => {
      const id = draft && draft.Id ? draft.Id : null;
      if (!id) return;
      const row = (this.initialProducts || []).find((r) => r.Id === id);
      if (!row) return;
      if (!selected.has(id)) {
        blocked.push(id);
        return;
      }
      const n = Number(draft.UnitPrice);
      if (!Number.isFinite(n) || n < 0) {
        invalid.push(id);
        return;
      }
      validDrafts.push({ Id: id, UnitPrice: n });
      accepted.push({ id, price: n });
    });

    if (showErrors && blocked.length > 0) {
      const msg = "Desk/Unit Price can be edited only for selected products.";
      this._setInlineError(msg);
    }
    if (showErrors && invalid.length > 0) {
      const msg = "Desk/Unit Price must be a non-negative number.";
      this._setInlineError(msg);
    }

    if (accepted.length > 0) {
      const overrides = { ...this.unitPriceOverridesByEntryId };
      accepted.forEach((item) => {
        overrides[item.id] = item.price;
      });
      this.unitPriceOverridesByEntryId = overrides;
      const priceById = accepted.reduce((acc, item) => {
        acc[item.id] = item.price;
        return acc;
      }, {});
      const applyPrice = (item) => {
        if (Object.prototype.hasOwnProperty.call(priceById, item.Id)) {
          return { ...item, UnitPrice: priceById[item.Id] };
        }
        return item;
      };
      this.initialProducts = (this.initialProducts || []).map(applyPrice);
      this.filteredProducts = (this.filteredProducts || []).map(applyPrice);
    }

    this.draftValues = validDrafts;
    return {
      blockedCount: blocked.length,
      invalidCount: invalid.length
    };
  }

  get showTransferPriceCheckbox() {
    return (
      this.replaceMode === true && this.selectedType === PRODUCT_TYPE_STANDARD
    );
  }

  handleTransferPriceChange(event) {
    this.transferPrice = event.target.checked === true;
  }

  get sliderToolTip() {
    return "";
  }

  handleRowSelection(event) {
    if (!event.detail || !event.detail.selectedRows) {
      return;
    }
    const originallySelected = event.detail.selectedRows || [];
    let selectedItems = originallySelected.map((row) => row.Id);
    if (this.replaceMode && selectedItems.length > 1) {
      selectedItems = selectedItems.slice(-1);
    }
    this.selectedRowIds = selectedItems;

    this._rebuildAccessTypeOptionsFromSelection();
    this._notifySelectionState();
    this._applyDraftValues(this.draftValues, false);
    this._decorateRowsWithSelectionState();
  }

  handleCellChange(event) {
    const drafts =
      event.detail && Array.isArray(event.detail.draftValues)
        ? event.detail.draftValues
        : [];
    this._applyDraftValues(drafts, true);
  }

  handleInlineSave(event) {
    const drafts =
      event.detail && Array.isArray(event.detail.draftValues)
        ? event.detail.draftValues
        : [];
    this._applyDraftValues(drafts, true);
    this.draftValues = [];
  }

  _buildSelectedUnitPriceOverrides() {
    const selected = new Set(this.selectedRowIds || []);
    const out = {};
    (this.initialProducts || []).forEach((row) => {
      if (!selected.has(row.Id)) return;
      const n = Number(row.UnitPrice);
      if (Number.isFinite(n) && n >= 0) {
        out[row.Id] = n;
      }
    });
    return out;
  }

  /** Notify modal footer of selection/loading state so Add Products / Replace can be enabled. */
  _notifySelectionState() {
    this.dispatchEvent(
      new CustomEvent("productselect", {
        detail: {
          hasSelection: this.selectedRowIds.length > 0,
          isLoading: this.isLoading
        },
        bubbles: true,
        composed: true
      })
    );
  }

  /** Called by modal footer when user clicks Add Products or Replace. */
  @api
  submit() {
    const dt = this.template.querySelector('[data-id="datatable"]');
    const pendingDrafts =
      dt && Array.isArray(dt.draftValues) ? dt.draftValues : this.draftValues;
    const gate = this._applyDraftValues(pendingDrafts, true);
    if (gate.invalidCount > 0) {
      return;
    }
    this.draftValues = [];
    if (dt) {
      dt.draftValues = [];
    }
    if (this.replaceMode) {
      this.handleReplace();
    } else {
      this.handleAddProducts();
    }
  }

  handleDeskValChange(event) {
    this.deskVal = event.detail.value;
    this.updateSelection();
    this.filterProducts();
    this._scheduleDeskSliderPatch();
  }

  /**
   * Try to set slider value text in a single shadow root (returns true if updated).
   */
  _tryApplyDeskSliderTextInRoot(sr, text) {
    if (!sr) {
      return false;
    }
    const byClass = sr.querySelector(".slds-slider__value");
    if (byClass) {
      if (byClass.textContent !== text) {
        byClass.textContent = text;
      }
      return true;
    }

    const output = sr.querySelector("output");
    if (output) {
      if (output.textContent !== text) {
        output.textContent = text;
      }
      return true;
    }

    const input = sr.querySelector('input[type="range"]');
    const next = input?.nextElementSibling;
    if (next && next.tagName === "SPAN") {
      if (next.textContent !== text) {
        next.textContent = text;
      }
      return true;
    }

    return false;
  }

  /**
   * Walk lightning-slider shadow tree (including nested component shadows) and patch value label.
   * @param {ShadowRoot} root
   * @param {string} text
   * @param {number} depth
   * @returns {boolean}
   */
  _patchDeskSliderValueInShadowTree(root, text, depth) {
    if (!root || depth > 3) {
      return false;
    }
    if (this._tryApplyDeskSliderTextInRoot(root, text)) {
      return true;
    }
    const nodes = root.querySelectorAll("*");
    for (let i = 0; i < nodes.length; i++) {
      const el = nodes[i];
      if (
        el.shadowRoot &&
        this._patchDeskSliderValueInShadowTree(el.shadowRoot, text, depth + 1)
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * Updates the built-in value label next to the slider thumb: "5" … "29", "30+" at max.
   * lightning-slider often nests primitives in inner shadow roots; no public API for the suffix.
   */
  _patchDeskSliderValueDisplay() {
    const slider = this.template.querySelector(".add-products-desk-slider");
    if (!slider?.shadowRoot) {
      return;
    }
    const v = Number(this.deskVal);
    const max = Number(this.maxDeskVal);
    const text = v === max ? `${max}+` : String(v);

    this._patchDeskSliderValueInShadowTree(slider.shadowRoot, text, 0);
    this._ensureDeskSliderMutationObserver(slider);
  }

  get disableAddProducts() {
    return this.selectedRowIds.length === 0 || this.isLoading === true;
  }

  get showReplaceButton() {
    return this.replaceMode === true;
  }

  get disableReplaceButton() {
    return this.selectedRowIds.length !== 1 || this.isLoading === true;
  }

  handleAddProducts() {
    console.log("productEntryIds:", this.selectedRowIds);

    if (this.selectedRowIds.length > 0) {
      this._clearInlineErrorBanner();
      if (this.opportunityLocationInUseLocked) {
        this._setInlineError(MSG_LOCATION_IN_USE);
        return;
      }
      const selectedAccessType = (
        this.selectedAccessType ||
        this.contractAgreementType ||
        ""
      ).trim();
      if (!selectedAccessType) {
        const msg = "Access Type is required.";
        this._setInlineError(msg);
        return;
      }
      const selectedProducts = (this.initialProducts || []).filter((p) =>
        (this.selectedRowIds || []).includes(p.Id)
      );
      if (
        !allSelectedProductsSupportAccessType(
          selectedProducts,
          selectedAccessType
        )
      ) {
        this._setInlineError(
          `Access Type "${selectedAccessType}" is not allowed for one or more selected products.`
        );
        return;
      }
      const periodErr = this._validatePeriodForAddAndReplace();
      if (periodErr) {
        this._setInlineError(periodErr);
        return;
      }
      this.isLoading = true;
      // Calls Generic Controller (passes modal period so OrderItem ServiceDate matches Package Builder filters)
      addProducts({
        productEntryIds: this.selectedRowIds,
        recordId: this.recordId,
        periodStartStr: (this.periodStartStr || "").trim() || null,
        periodEndStr: (this.periodEndStr || "").trim() || null,
        accessTypeStr:
          (
            this.selectedAccessType ||
            this.contractAgreementType ||
            ""
          ).trim() || null,
        unitPriceOverrides: this._buildSelectedUnitPriceOverrides(),
        cpiDateStr: this.showOrderCpiDateField
          ? (this.defaultCpiDateStr || "").trim() || null
          : null,
        temporaryDefault: this.showTemporaryDefault
          ? this.defaultTemporary === true
          : false,
        notesDefault: this.showNotesDefault
          ? (this.defaultNotes || "").trim() || null
          : null
      })
        .then((resultMessage) => {
          if (resultMessage !== "") {
            this._setInlineError(String(resultMessage));
            console.log("Something went wrong:", resultMessage);
          } else {
            this._clearInlineErrorBanner();
            this.showToast("Success", this.labels.Success, "success");
            this.dispatchEvent(new CustomEvent("addproducts"));
          }
        })
        .catch((error) => {
          const msg = this._reduceServerError(error);
          this._setInlineError(msg);
          console.log("Something went wrong:", error);
        })
        .finally(() => {
          this.isLoading = false;
          this._notifySelectionState();
        });
    }
  }

  handleReplace() {
    if (
      !this.replaceMode ||
      !this.replacedOrderItemId ||
      this.selectedRowIds.length !== 1
    )
      return;
    this._clearInlineErrorBanner();
    const ps = (this.periodStartStr || "").trim();
    const pe = (this.periodEndStr || "").trim();
    if (ps && pe && ps > pe) {
      const msg = "Period start date cannot be after period end date.";
      this._setInlineError(msg);
      return;
    }
    const periodErr = this._validatePeriodForAddAndReplace();
    if (periodErr) {
      this._setInlineError(periodErr);
      return;
    }
    const productEntryId = this.selectedRowIds[0];
    const replacementUnitPrice = this.transferPrice
      ? null
      : this._buildSelectedUnitPriceOverrides()[productEntryId];
    const openEndedReplacement = !(this.periodEndStr || "").trim();
    this.isLoading = true;
    addReplacementProduct({
      productEntryId,
      orderId: this.recordId,
      replacedOrderItemId: this.replacedOrderItemId,
      periodStartStr: this.periodStartStr || null,
      periodEndStr: this.periodEndStr || null,
      cpiDateStr: this.showOrderCpiDateField
        ? (this.defaultCpiDateStr || "").trim() || null
        : null,
      replacementQuantity: null,
      replacementDescription: null,
      openEndedReplacement,
      replacementUnitPrice,
      transferPrice: this.transferPrice === true
    })
      .then((resultMessage) => {
        const err = String(resultMessage || "").trim();
        if (err !== "") {
          this._setInlineError(err);
        } else {
          this._clearInlineErrorBanner();
          this.showToast("Success", this.labels.Success, "success");
          this.dispatchEvent(new CustomEvent("replaceproduct"));
        }
      })
      .catch((error) => {
        const msg = this._reduceServerError(error);
        this._setInlineError(msg);
        console.error("Replace product error:", error);
      })
      .finally(() => {
        this.isLoading = false;
        this._notifySelectionState();
      });
  }

  showToast(title, message, variant) {
    // Fire from modal host: ShowToastEvent from inside lightning-modal-body often does not appear.
    this.dispatchEvent(
      new CustomEvent("packagebuildernotify", {
        detail: {
          title,
          message,
          variant,
          mode: variant === "error" ? "pester" : "dismissable"
        },
        bubbles: true,
        composed: true
      })
    );
  }

  _reduceServerError(error) {
    if (!error) return this.labels.Error;
    if (typeof error === "string") return error;
    if (Array.isArray(error.body)) {
      return (
        error.body
          .map((e) => e.message)
          .filter(Boolean)
          .join(", ") || this.labels.Error
      );
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
      return [...new Set(messages)].join(", ");
    }
    if (error.body && typeof error.body.message === "string") {
      const bm = error.body.message;
      if (bm && bm !== "Script-thrown exception") {
        return bm;
      }
    }
    if (error.message && error.message !== "Script-thrown exception")
      return error.message;
    return this.labels.Error;
  }

  formatLabel(label, ...values) {
    return label.replace(/{(\d+)}/g, (match, index) => values[index] || "");
  }
}
