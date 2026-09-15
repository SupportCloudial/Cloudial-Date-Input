import LightningDatatable from "lightning/datatable";
import replacementIconCellTemplate from "./replacementIconCell.html";
import comboboxColumnTypeTemplate from "./comboboxColumnType.html";
import dateColumnTypeTemplate from "./dateColumnType.html";
import booleanColumnTypeTemplate from "./booleanColumnType.html";
import actionWithTooltipTypeTemplate from "./actionWithTooltipType.html";
import dualActionWithTooltipTypeTemplate from "./dualActionWithTooltipType.html";
import pencilEditableColumnTypeTemplate from "./pencilEditableColumnType.html";

export default class PackageBuilderTableCustom extends LightningDatatable {
  connectedCallback() {
    if (typeof super.connectedCallback === "function") {
      super.connectedCallback();
    }
    if (!this.getAttribute("wrap-table-header")) {
      this.setAttribute("wrap-table-header", "all");
    }
  }

  static customTypes = {
    replacementIcon: {
      template: replacementIconCellTemplate,
      standardCellLayout: true,
      typeAttributes: [
        "showCross",
        "showCrossAltText",
        "showMonthlyPricingIcon",
        "entryClockIcon",
        "layoutMode",
        "statusCrossIconUrl",
        "statusEntryAfterStartUrl",
        "statusFutureEndBeforeMaxUrl",
        "statusMonthlyMoneyIconUrl",
        "statusNewProductIconUrl",
        "tooltipCross",
        "tooltipReplacement",
        "tooltipNewProduct",
        "tooltipFuturePlusEntry",
        "tooltipFutureXOtherProducts",
        "tooltipMoneyFinancial",
        "tooltipModified"
      ]
    },
    combobox: {
      template: comboboxColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "picklistValues",
        "alignment",
        "pastStartSplit"
      ]
    },
    pencilEditable: {
      template: pencilEditableColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "inputType",
        "pastStartSplit",
        "step",
        "alignment",
        "showPriceProjectionInfo",
        "tooltipPriceProjection"
      ]
    },
    dateInput: {
      template: dateColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "hideEmptyDash",
        "tooltipMessage"
      ]
    },
    booleanCheckbox: {
      template: booleanColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: ["editable", "fieldName", "keyField", "keyFieldValue"]
    },
    actionWithTooltip: {
      template: actionWithTooltipTypeTemplate,
      standardCellLayout: true,
      typeAttributes: [
        "iconName",
        "iconSrc",
        "name",
        "keyField",
        "keyFieldValue",
        "disabled",
        "hidden",
        "tooltip",
        "alternativeText",
        "variant",
        "size"
      ]
    },
    dualActionWithTooltip: {
      template: dualActionWithTooltipTypeTemplate,
      standardCellLayout: true,
      typeAttributes: [
        "keyField",
        "keyFieldValue",
        "leftIconName",
        "leftIconSrc",
        "leftName",
        "leftDisabled",
        "leftHidden",
        "leftTooltip",
        "leftAlternativeText",
        "rightIconName",
        "rightIconSrc",
        "rightName",
        "rightDisabled",
        "rightHidden",
        "rightTooltip",
        "rightAlternativeText",
        "variant",
        "size"
      ]
    }
  };

  /**
   * LWC-scoped CSS often does not match Lightning Datatable's runtime cell DOM. Inject unscoped rules
   * into this shadow root so [class*="pb-concluded-ended"] (from row RowCssClass / cell classes) always paints.
   */
  renderedCallback() {
    if (typeof super.renderedCallback === "function") {
      super.renderedCallback();
    }
    const root = this.shadowRoot;
    if (!root) {
      return;
    }
    const uiStyleStamp = "pb-dt-ui-v14-icon-size-unify";
    if (root.querySelector(`style[data-pb-datatable-ui="${uiStyleStamp}"]`)) {
      return;
    }
    root
      .querySelectorAll("style[data-pb-datatable-ui]")
      .forEach((n) => n.remove());
    const style = document.createElement("style");
    style.dataset.pbDatatableUi = uiStyleStamp;
    style.textContent = `
table thead th .slds-truncate {
  white-space: normal !important;
  overflow: visible !important;
  text-overflow: clip !important;
  max-width: none !important;
  line-height: 1.25 !important;
  word-break: break-word !important;
}
table thead th .slds-th__action {
  height: auto !important;
  min-height: 2rem !important;
  align-items: flex-end !important;
}
table thead th[data-col-key-value="Quantity"],
table thead th[data-col-key-value="Temporary"] {
  min-width: 8.75rem !important;
}
table thead th[data-col-key-value="Quantity"] .slds-cell-fixed,
table thead th[data-col-key-value="Temporary"] .slds-cell-fixed {
  min-width: 8.75rem !important;
  width: auto !important;
}
[class*="pb-concluded-ended"] {
  position: relative !important;
}
[class*="pb-concluded-ended"]::before {
  content: "" !important;
  position: absolute !important;
  left: 0.25rem !important;
  right: 0.25rem !important;
  top: 50% !important;
  border-top: 1.5px solid currentColor !important;
  opacity: 0.9 !important;
  pointer-events: none !important;
  z-index: 5 !important;
}
[class*="pb-concluded-ended"] .slds-truncate,
.slds-truncate[class*="pb-concluded-ended"],
[class*="pb-concluded-ended"] .slds-line-clamp,
[class*="pb-concluded-ended"] .slds-cell-fixed-width {
  text-decoration: line-through !important;
}
td[class*="pb-end-date-before-order-start"],
th[class*="pb-end-date-before-order-start"] {
  background-color: #fecaca !important;
}
td[class*="pb-end-date-required"],
th[class*="pb-end-date-required"] {
  background-color: #fecaca !important;
  box-shadow: inset 0 0 0 2px #c23934 !important;
}
/* Vertically center all cell content so action icons stay in the middle of tall rows. */
table tbody td {
  vertical-align: middle !important;
}
/* Custom-type cells: factory stretches to td height; inner primitive cell fills factory and
   centers content (replace/delete outer uses height:100% + flex to sit mid-cell). */
table tbody td lightning-primitive-custom-cell-factory {
  display: flex !important;
  align-items: center !important;
  align-self: center !important;
  height: 100% !important;
}
table tbody td lightning-primitive-custom-cell-factory lightning-primitive-custom-cell {
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  flex: 1 1 auto !important;
  width: 100% !important;
  height: 100% !important;
}
/* Replace+delete column: center the action stack vertically in the full row height. */
table tbody td[class*="pb-dual-action-td"] lightning-primitive-custom-cell-factory {
  display: flex !important;
  align-items: center !important;
  justify-content: flex-end !important;
  width: 100% !important;
  min-height: 100% !important;
  height: 100% !important;
}
table tbody td[class*="pb-dual-action-td"] lightning-primitive-custom-cell-factory > * {
  display: flex !important;
  align-items: center !important;
  justify-content: flex-end !important;
  flex: 1 1 auto !important;
  width: 100% !important;
  min-height: 100% !important;
}
/* Opportunity single-delete column: same vertical center, horizontal center in narrow column. */
table tbody td[class*="pb-row-action-td"] lightning-primitive-custom-cell-factory {
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  width: 100% !important;
  min-height: 100% !important;
  height: 100% !important;
}
table tbody td[class*="pb-row-action-td"] lightning-primitive-custom-cell-factory > * {
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  flex: 1 1 auto !important;
  width: 100% !important;
  min-height: 100% !important;
}
/* ERS tooltips use position:fixed; intermediate wrappers must not clip (datatable / SLDS). */
table tbody tr,
table tbody td,
table tbody td lightning-primitive-custom-cell-factory,
table tbody td lightning-primitive-custom-cell-factory lightning-primitive-custom-cell {
  overflow: visible !important;
}
/* Status icon column: hug icon row; width comes from JS column patch per section. */
table tbody td[data-col-key-value="StatusIconValue"] {
  min-width: min-content !important;
  width: auto !important;
  overflow: visible !important;
  padding-block: 0.125rem !important;
  padding-right: 0.25rem !important;
}
table tbody td[data-col-key-value="StatusIconValue"] .slds-truncate,
table tbody td[data-col-key-value="StatusIconValue"] .slds-cell-fixed {
  overflow: visible !important;
  text-overflow: clip !important;
  max-width: none !important;
  height: auto !important;
  max-height: none !important;
}
table tbody td[data-col-key-value="StatusIconValue"] lightning-primitive-custom-cell-factory,
table tbody td[data-col-key-value="StatusIconValue"] lightning-primitive-custom-cell-factory lightning-primitive-custom-cell {
  justify-content: flex-end !important;
  align-items: center !important;
  overflow: visible !important;
  max-width: none !important;
  width: 100% !important;
  height: auto !important;
  min-height: 2rem !important;
}
/* Temporary checkbox: centered in column; avoid clipping from lightning-input chrome */
table tbody td[data-col-key-value="Temporary"] {
  text-align: center !important;
  overflow: visible !important;
  vertical-align: middle !important;
}
table tbody td[data-col-key-value="Temporary"] lightning-primitive-custom-cell-factory,
table tbody td[data-col-key-value="Temporary"] lightning-primitive-custom-cell-factory lightning-primitive-custom-cell {
  justify-content: center !important;
  align-items: center !important;
  width: 100% !important;
  overflow: visible !important;
}
table tbody td[data-col-key-value="Temporary"] .boolean-cell {
  margin-left: auto !important;
  margin-right: auto !important;
}
/* While Temporary is focused, do not paint End Date warning/edit tint on the neighbor cell */
table tbody tr:has(td[data-col-key-value="Temporary"]:focus-within) td[data-col-key-value="EndDate"] {
  background-color: transparent !important;
  box-shadow: none !important;
}
table tbody td[data-col-key-value="Temporary"]:focus-within {
  box-shadow: none !important;
  outline: none !important;
}
/* Combobox menus should float above the table instead of clipping inside datatable scroll shells. */
:host,
.slds-table_header-fixed_container,
.slds-scrollable_x,
.slds-scrollable_y {
  overflow: visible !important;
}
`;
    root.appendChild(style);
  }
}
