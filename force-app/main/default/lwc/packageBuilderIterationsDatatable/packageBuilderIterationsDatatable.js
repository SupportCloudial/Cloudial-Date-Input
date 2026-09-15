import LightningDatatable from "lightning/datatable";
import {
  createPortalTooltipBubble,
  destroyPortalTooltipBubble,
  positionTooltipBubble
} from "c/ers_datatableUtils";
import comboboxColumnTypeTemplate from "./comboboxColumnType.html";
import workingComboboxColumnTypeTemplate from "./workingComboboxColumnType.html";
import workingValueColumnTypeTemplate from "./workingValueColumnType.html";
import pencilEditableColumnTypeTemplate from "./pencilEditableColumnType.html";
import seqAttentionColumnTypeTemplate from "./seqAttentionColumnType.html";

const COLUMN_HEADER_HINTS = {
  Increase_Type__c:
    "How the renewal price increase is calculated. Leave blank for no increase.",
  _increaseValue: "The increase applied when this iteration renews.",
  Proposed_Increase_Type__c:
    "Optional draft. Copied to Price Increase Type only when you Approve. After save, Working Type/Value are not edited inline — use Bulk, Approve, Revert, or Copy from.",
  _proposedIncreaseValue:
    "Optional draft. Schedule always uses Price Increase until Approve."
};

const LABEL_TO_HINT = {
  "Price Increase Type": COLUMN_HEADER_HINTS.Increase_Type__c,
  "Price Increase Value": COLUMN_HEADER_HINTS._increaseValue,
  "Working Type": COLUMN_HEADER_HINTS.Increase_Type__c,
  "Working Value": COLUMN_HEADER_HINTS._increaseValue,
  "Proposed Type": COLUMN_HEADER_HINTS.Proposed_Increase_Type__c,
  "Proposed Value": COLUMN_HEADER_HINTS._proposedIncreaseValue,
  Proposed:
    "Pending commercial terms for the selected product. Approve copies these into Working."
};

const TOOLTIP_STYLES = `
table thead th {
  white-space: nowrap !important;
  overflow: visible !important;
}
table thead th .slds-truncate {
  white-space: nowrap !important;
  overflow: visible !important;
}

table thead th .slds-cell-fixed {
  overflow: visible !important;
}

.iter-header-info-hint {
  display: inline-flex;
  align-items: center;
  margin-left: 0.2rem;
  flex-shrink: 0;
  cursor: help;
  position: relative;
  z-index: 3;
}
.iter-header-info-hint .slds-icon {
  width: 0.875rem;
  height: 0.875rem;
  fill: #706e6b;
  opacity: 0.72;
}
.iter-header-info-hint:hover .slds-icon {
  opacity: 1;
}
`;

function createHeaderInfoIcon() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "slds-icon slds-icon_xx-small");
  svg.setAttribute("viewBox", "0 0 52 52");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute(
    "d",
    "M26 2C12.7 2 2 12.7 2 26s10.7 24 24 24 24-10.7 24-24S39.3 2 26 2zm0 8c2.2 0 4 1.8 4 4s-1.8 4-4 4-4-1.8-4-4 1.8-4 4-4zm-2 28V22h4v16h-4z"
  );
  svg.appendChild(path);
  return svg;
}

function createHeaderInfoHint(message) {
  const wrap = document.createElement("span");
  wrap.className = "iter-header-info-hint";
  wrap.dataset.iterInfoHint = "true";
  wrap.appendChild(createHeaderInfoIcon());

  let portalBubble = null;
  let boundReposition = null;

  const reposition = () => {
    if (!portalBubble) return;
    positionTooltipBubble(wrap, portalBubble);
  };

  const attachListeners = () => {
    if (boundReposition) return;
    boundReposition = reposition;
    window.addEventListener("scroll", boundReposition, true);
    window.addEventListener("resize", boundReposition);
  };

  const detachListeners = () => {
    if (!boundReposition) return;
    window.removeEventListener("scroll", boundReposition, true);
    window.removeEventListener("resize", boundReposition);
    boundReposition = null;
  };

  const show = () => {
    if (portalBubble) return;
    portalBubble = createPortalTooltipBubble(message);
    attachListeners();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    requestAnimationFrame(() => {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      requestAnimationFrame(() => {
        reposition();
        portalBubble?.classList.add("is-visible");
      });
    });
  };
  const hide = () => {
    detachListeners();
    destroyPortalTooltipBubble(portalBubble);
    portalBubble = null;
  };

  wrap.addEventListener("mouseenter", show);
  wrap.addEventListener("mouseleave", hide);
  return wrap;
}

function hintForHeaderTh(th) {
  const key =
    th.getAttribute("data-col-key-value") ||
    th
      .querySelector("[data-col-key-value]")
      ?.getAttribute("data-col-key-value") ||
    "";
  for (const [field, hint] of Object.entries(COLUMN_HEADER_HINTS)) {
    if (key === field || key.includes(field)) return hint;
  }

  const label =
    th.querySelector(".slds-truncate")?.textContent || th.textContent || "";
  const normalized = String(label).replace(/\s+/g, " ").trim();
  for (const [lbl, hint] of Object.entries(LABEL_TO_HINT)) {
    if (normalized.includes(lbl)) return hint;
  }
  return null;
}

/**
 * Recursively collect all shadow roots reachable from `node`,
 * including open AND closed-ish roots that lightning datatable exposes.
 */
function collectAllRoots(node, seen = new Set()) {
  if (!node || seen.has(node)) return [];
  seen.add(node);
  const roots = [node];
  const kids = node.querySelectorAll ? node.querySelectorAll("*") : [];
  kids.forEach((el) => {
    if (el.shadowRoot) {
      collectAllRoots(el.shadowRoot, seen).forEach((r) => roots.push(r));
    }
  });
  return roots;
}

/**
 * Compact datatable for the Iterations modal.
 */
export default class PackageBuilderIterationsDatatable extends LightningDatatable {
  static customTypes = {
    combobox: {
      template: comboboxColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "picklistValues",
        "alignment"
      ]
    },
    workingCombobox: {
      template: workingComboboxColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "picklistValues",
        "alignment"
      ]
    },
    workingValue: {
      template: workingValueColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "inputType",
        "pastStartSplit",
        "step",
        "alignment"
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
    seqAttention: {
      template: seqAttentionColumnTypeTemplate,
      standardCellLayout: false,
      typeAttributes: [
        "editable",
        "fieldName",
        "keyField",
        "keyFieldValue",
        "alignment",
        "attentionHint"
      ]
    }
  };

  connectedCallback() {
    if (typeof super.connectedCallback === "function") {
      super.connectedCallback();
    }
    if (!this.getAttribute("wrap-table-header")) {
      this.setAttribute("wrap-table-header", "none");
    }
  }

  renderedCallback() {
    if (typeof super.renderedCallback === "function") {
      super.renderedCallback();
    }
    const root = this.shadowRoot;
    if (!root) return;
    const stamp = "pb-iter-dt-v11";
    if (!root.querySelector(`style[data-pb-iter-dt="${stamp}"]`)) {
      root
        .querySelectorAll("style[data-pb-iter-dt]")
        .forEach((n) => n.remove());
      const style = document.createElement("style");
      style.dataset.pbIterDt = stamp;
      style.textContent = `
table thead th {
  white-space: nowrap !important;
}
table thead th .slds-truncate {
  white-space: nowrap !important;
  overflow: visible !important;
  text-overflow: clip !important;
  max-width: none !important;
}
table tbody td {
  vertical-align: middle !important;
  height: auto !important;
}
table tbody tr {
  height: auto !important;
}
table tbody td lightning-primitive-custom-cell-factory,
table tbody td lightning-primitive-custom-cell-factory lightning-primitive-custom-cell {
  display: block !important;
  height: auto !important;
  min-height: 0 !important;
  align-self: center !important;
}
table tbody td .slds-form-element {
  margin: 0 !important;
}
table tbody td .slds-form-element__control,
table tbody td .slds-input,
table tbody td input.slds-input,
table tbody td lightning-primitive-input-simple,
table tbody td lightning-input {
  height: auto !important;
  min-height: 1.75rem !important;
  max-height: 2rem !important;
}
table tbody td input.slds-input {
  padding-top: 0.25rem !important;
  padding-bottom: 0.25rem !important;
  line-height: 1.5 !important;
}
.iter-proposed-cell-pending {
  background-color: #fff7ed !important;
  color: #9a3412 !important;
  font-weight: 600;
}
.iter-proposed-cell-empty {
  color: #706e6b;
}
.iter-seq-proposed-pending {
  font-weight: 700;
  color: #c2410c;
}
tr.iter-row-pending-proposed td {
  background-color: #fff8e6 !important;
}
tr.iter-row-pending-proposed td:first-child {
  box-shadow: inset 3px 0 0 #fe9339;
}
tr.iter-row-pending-proposed {
  cursor: default;
}
td.iter-pending-proposed,
.slds-hint-parent.iter-pending-proposed {
  background-color: #fff7ed !important;
}
.iter-working-cell {
  width: 100%;
}
.iter-icon-cell {
  width: 100%;
  padding-right: 0.375rem;
  column-gap: 0.25rem;
}
.iter-icon-cell__main,
.iter-working-cell__main,
.iter-seq-cell__main {
  min-width: 0;
}
.iter-icon-cell > .slds-shrink-none,
.iter-seq-attention-icon {
  margin-right: 0.125rem;
  padding-right: 0.125rem;
}
${TOOLTIP_STYLES}
`;
      root.appendChild(style);
    }
    this._decorateColumnHeaders(root);
    this._decoratePendingRows(root);
    this._ensureHeaderObserver(root);
    if (!this._headerHintRetry) {
      this._headerHintRetry = true;
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      setTimeout(() => {
        if (this.shadowRoot) {
          this._decorateColumnHeaders(this.shadowRoot);
          this._decoratePendingRows(this.shadowRoot);
        }
      }, 250);
    }
  }

  _ensureHeaderObserver(root) {
    if (this._headerObserver) return;
    this._headerObserver = new MutationObserver(() => {
      if (this._decorateTimer) clearTimeout(this._decorateTimer);
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this._decorateTimer = setTimeout(() => {
        if (this.shadowRoot) {
          this._decorateColumnHeaders(this.shadowRoot);
          this._decoratePendingRows(this.shadowRoot);
        }
      }, 80);
    });
    // Watch the datatable's direct shadow root for child changes
    // (headers are re-inserted here when columns change).
    this._headerObserver.observe(root, { childList: true, subtree: true });
  }

  _decorateColumnHeaders(root) {
    // Walk every reachable shadow root — headers live inside
    // lightning-primitive-header-factory which has its own shadow root.
    const allRoots = collectAllRoots(root);
    allRoots.forEach((searchRoot) => {
      searchRoot
        .querySelectorAll("thead th, [role='columnheader']")
        .forEach((th) => {
          const hint = hintForHeaderTh(th);
          if (!hint) return;
          if (th.querySelector("[data-iter-info-hint]")) return;

          const hintEl = createHeaderInfoHint(hint);

          const labelEl =
            th.querySelector(".slds-truncate") ||
            th.querySelector(".slds-cell-fixed") ||
            th.firstElementChild ||
            null;

          try {
            if (labelEl && labelEl !== th && labelEl.parentNode) {
              labelEl.insertAdjacentElement("afterend", hintEl);
            } else {
              th.appendChild(hintEl);
            }
          } catch {
            th.appendChild(hintEl);
          }
        });
    });
  }

  _decoratePendingRows(root) {
    const rows = this.data || [];
    if (!rows.length) {
      return;
    }
    const hintsByKey = new Map(
      rows.map((row) => [
        String(row.rowKey || row.Id || ""),
        row._pendingAttentionHint || ""
      ])
    );
    collectAllRoots(root).forEach((searchRoot) => {
      searchRoot.querySelectorAll("tbody tr").forEach((tr) => {
        const key = tr.getAttribute("data-row-key-value");
        const hint = key ? hintsByKey.get(String(key)) : "";
        if (hint) {
          tr.classList.add("iter-row-pending-proposed");
        } else {
          tr.classList.remove("iter-row-pending-proposed");
        }
      });
    });
  }
}
