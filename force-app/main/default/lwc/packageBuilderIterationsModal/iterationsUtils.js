/** Pure helpers for the Iterations modal - no `this`, safe to unit test. */

export const INCREASE_TYPE_OPTIONS = [
  { label: "None", value: "" },
  { label: "Increase by Percentage", value: "Increase_by_Percentage" },
  { label: "Increase by Value", value: "Increase_by_Value" },
  { label: "Final Price", value: "Final_Price" }
];

/** Map form used by c-ers_combobox-column-type (label -> value). Blank = no increase. */
export const INCREASE_TYPE_PICKLIST_MAP = {
  None: "",
  "Increase by Percentage": "Increase_by_Percentage",
  "Increase by Value": "Increase_by_Value",
  "Final Price": "Final_Price"
};

/** Active status picklist values for display. */
export const STATUS_PICKLIST_MAP = {
  Original: "Original",
  Proposed: "Proposed",
  Approved: "Approved",
  Rejected: "Rejected",
  Completed: "Completed",
  Inactive: "Inactive",
  Planned: "Planned"
};

const LEGACY_INCREASE_TYPE_MAP = {
  Percent: "Increase_by_Percentage",
  "Fixed Amount": "Increase_by_Value",
  "Final Price": "Final_Price"
};

const VALID_INCREASE_TYPES = new Set([
  "Increase_by_Percentage",
  "Increase_by_Value",
  "Final_Price"
]);
const VALID_STATUSES = new Set(Object.values(STATUS_PICKLIST_MAP));

const COL = { hideDefaultActions: true, wrapText: false };

/** Human label for Increase_Type__c / Proposed / Original API values. */
export function formatIncreaseTypeLabel(apiValue) {
  if (apiValue == null || apiValue === "") {
    return "";
  }
  const match = INCREASE_TYPE_OPTIONS.find((opt) => opt.value === apiValue);
  if (match) {
    return match.label;
  }
  const legacy = LEGACY_INCREASE_TYPE_MAP[apiValue];
  if (legacy) {
    return formatIncreaseTypeLabel(legacy);
  }
  return String(apiValue).replace(/_/g, " ");
}

export function buildIterationColumns() {
  return [
    {
      ...COL,
      label: "Duration (mo)",
      fieldName: "Duration_Months__c",
      type: "number",
      editable: { fieldName: "_isEditable" },
      initialWidth: 110,
      cellAttributes: { alignment: "left" }
    },
    {
      ...COL,
      label: "Notice (days)",
      fieldName: "Advance_Notice_Days__c",
      type: "number",
      editable: { fieldName: "_isEditable" },
      initialWidth: 118,
      cellAttributes: { alignment: "left" }
    },
    {
      ...COL,
      label: "Price Increase Type",
      fieldName: "Increase_Type__c",
      type: "workingCombobox",
      editable: false,
      initialWidth: 220,
      typeAttributes: {
        editable: { fieldName: "_isWorkingIncreaseEditable" },
        fieldName: "Increase_Type__c",
        keyField: "rowKey",
        keyFieldValue: { fieldName: "rowKey" },
        picklistValues: INCREASE_TYPE_PICKLIST_MAP,
        alignment: "slds-text-align_left"
      }
    },
    {
      ...COL,
      label: "Price Increase Value",
      fieldName: "_increaseValue",
      type: "workingValue",
      editable: false,
      initialWidth: 180,
      typeAttributes: {
        editable: { fieldName: "_isWorkingIncreaseEditable" },
        fieldName: "_increaseValue",
        keyField: "rowKey",
        keyFieldValue: { fieldName: "rowKey" },
        inputType: "number",
        step: "any",
        alignment: "slds-text-align_left"
      }
    },
    {
      ...COL,
      label: "Proposed Type",
      fieldName: "Proposed_Increase_Type__c",
      type: "combobox",
      editable: false,
      initialWidth: 160,
      typeAttributes: {
        editable: { fieldName: "_isProposedEditable" },
        fieldName: "Proposed_Increase_Type__c",
        keyField: "rowKey",
        keyFieldValue: { fieldName: "rowKey" },
        picklistValues: INCREASE_TYPE_PICKLIST_MAP,
        alignment: "slds-text-align_left"
      },
      cellAttributes: { class: { fieldName: "_pendingCellClass" } }
    },
    {
      ...COL,
      label: "Proposed Value",
      fieldName: "_proposedIncreaseValue",
      type: "number",
      editable: false,
      initialWidth: 148,
      typeAttributes: { maximumFractionDigits: 6 },
      cellAttributes: {
        alignment: "left",
        class: { fieldName: "_pendingCellClass" }
      }
    },
    {
      ...COL,
      label: "Status",
      fieldName: "Status__c",
      type: "text",
      editable: false,
      initialWidth: 140,
      cellAttributes: { alignment: "left" }
    },
    {
      ...COL,
      label: "Period start",
      fieldName: "Period_Start_Date__c",
      type: "date-local",
      editable: false,
      initialWidth: 120,
      typeAttributes: { month: "2-digit", day: "2-digit", year: "numeric" }
    },
    {
      ...COL,
      label: "Period end",
      fieldName: "Period_End_Date__c",
      type: "date-local",
      editable: false,
      initialWidth: 120,
      typeAttributes: { month: "2-digit", day: "2-digit", year: "numeric" }
    },
    {
      ...COL,
      label: "Notice date",
      fieldName: "Notice_Date__c",
      type: "date-local",
      editable: false,
      initialWidth: 120,
      typeAttributes: { month: "2-digit", day: "2-digit", year: "numeric" }
    }
  ];
}

function formatDateLabel(value) {
  if (!value) return null;
  try {
    const d =
      typeof value === "string"
        ? new Date(value + "T00:00:00")
        : new Date(value);
    if (Number.isNaN(d.getTime())) return null;
    return d.toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric"
    });
  } catch {
    return null;
  }
}

export function buildProductDisplayName(row) {
  const name = (row?.productName || "").trim();
  const code = (row?.productCode || "").trim();
  if (name && code) return name + " (" + code + ")";
  if (name) return name;
  if (code) return code;
  return "Product";
}

export function buildDateRangeLabel(row) {
  const start = formatDateLabel(row?.startDate);
  const end = formatDateLabel(row?.endDate);
  if (start && end) return start + " to " + end;
  if (end) return "Ends " + end;
  if (start) return "Starts " + start;
  return "";
}

const PERCENT_FIELD_SCALE = 6;

function roundPercentStorage(value) {
  const factor = 10 ** PERCENT_FIELD_SCALE;
  return Math.round(value * factor) / factor;
}

function roundPercentDisplay(value) {
  const rounded = roundPercentStorage(value);
  return Number(rounded.toFixed(PERCENT_FIELD_SCALE));
}

export function percentForSave(displayVal) {
  if (displayVal === null || displayVal === undefined || displayVal === "") {
    return null;
  }
  const n = Number(displayVal);
  if (Number.isNaN(n)) return null;
  // Persist percent-points (23 means 23%); display helpers still dual-read old fractions.
  return roundPercentStorage(n);
}

export function increaseValueForDisplay(
  row,
  typeField,
  percentField,
  amountField,
  priceField
) {
  const rawType = row?.[typeField];
  const type = coerceIncreaseType(
    rawType === null || rawType === undefined || rawType === "" ? "" : rawType
  );
  if (!type) return null;
  if (type === "Increase_by_Value") return row?.[amountField];
  if (type === "Final_Price") return row?.[priceField];
  const pct = row?.[percentField];
  if (pct === null || pct === undefined) return null;
  const display = Math.abs(pct) <= 1 ? pct * 100 : pct;
  return roundPercentDisplay(display);
}

function coerceIncreaseType(type) {
  if (type === null || type === undefined || type === "") {
    return "";
  }
  if (LEGACY_INCREASE_TYPE_MAP[type]) {
    return LEGACY_INCREASE_TYPE_MAP[type];
  }
  return VALID_INCREASE_TYPES.has(type) ? type : "";
}

function coerceStatus(status) {
  if (status === "Negotiation" || status === "On Hold") {
    return "Inactive";
  }
  if (VALID_STATUSES.has(status)) {
    return status;
  }
  return "Original";
}

export function hasPendingProposed(row) {
  if (!row) return false;
  return (
    row.Proposed_Increase_Percent__c != null ||
    row.Proposed_Increase_Amount__c != null ||
    row.Proposed_Final_Price__c != null ||
    (row.Proposed_Increase_Type__c != null &&
      row.Proposed_Increase_Type__c !== "") ||
    (row._proposedIncreaseValue !== null &&
      row._proposedIncreaseValue !== undefined &&
      row._proposedIncreaseValue !== "")
  );
}

export function formatProposedCommercialDisplay(row) {
  if (!row || !hasPendingProposed(row)) {
    return "";
  }
  const typeApi = coerceIncreaseType(row.Proposed_Increase_Type__c);
  const typeLabel = typeApi ? formatIncreaseTypeLabel(typeApi) : "";
  const displayVal = increaseValueForDisplay(
    row,
    "Proposed_Increase_Type__c",
    "Proposed_Increase_Percent__c",
    "Proposed_Increase_Amount__c",
    "Proposed_Final_Price__c"
  );
  if (displayVal === null || displayVal === undefined || displayVal === "") {
    return typeLabel;
  }
  if (typeApi === "Increase_by_Percentage") {
    return typeLabel + " · " + String(displayVal) + "%";
  }
  return typeLabel + " · " + String(displayVal);
}

export function formatPendingProposedAttentionMessage(row) {
  if (!row || !hasPendingProposed(row)) {
    return "";
  }
  const status = row.Status__c;
  if (status === "Completed" || status === "Inactive") {
    return "";
  }
  const commercial = formatProposedCommercialDisplay(row);
  if (!commercial) {
    return "";
  }
  const seq = row.Sequence__c ?? "";
  return (
    "Iteration " +
    String(seq) +
    " needs attention: pending proposal (" +
    commercial +
    "). Approve to promote into Working, or Reject to discard."
  );
}

function applyIncreaseFieldsFromDisplay(
  out,
  type,
  displayVal,
  {
    typeField = "Increase_Type__c",
    percentField = "Increase_Percent__c",
    amountField = "Increase_Amount__c",
    priceField = "Final_Price__c"
  } = {}
) {
  const coerced = coerceIncreaseType(type);
  out[typeField] = coerced || null;
  out[percentField] = null;
  out[amountField] = null;
  out[priceField] = null;
  if (!coerced) {
    return;
  }
  if (displayVal !== null && displayVal !== undefined && displayVal !== "") {
    const num = Number(displayVal);
    if (!Number.isNaN(num)) {
      if (coerced === "Increase_by_Value") {
        out[amountField] = num;
      } else if (coerced === "Final_Price") {
        out[priceField] = num;
      } else {
        out[percentField] = percentForSave(num);
      }
    }
  }
}

function routeIncreaseValueToTemplate(template, type, displayVal, fields) {
  const coerced = coerceIncreaseType(type);
  if (!coerced) return;
  if (displayVal === null || displayVal === undefined || displayVal === "") {
    return;
  }
  const num = Number(displayVal);
  if (Number.isNaN(num)) return;
  if (coerced === "Increase_by_Value") {
    template[fields.amount] = num;
  } else if (coerced === "Final_Price") {
    template[fields.price] = num;
  } else {
    template[fields.percent] = percentForSave(num);
  }
}

export function normalizeIterationRow(row) {
  const type = coerceIncreaseType(row?.Increase_Type__c);
  const status = coerceStatus(row?.Status__c || "Original");
  const completed = status === "Completed" || status === "Inactive";
  const hasExplicitIncrease =
    row != null && Object.prototype.hasOwnProperty.call(row, "_increaseValue");
  const hasExplicitProposed =
    row != null &&
    Object.prototype.hasOwnProperty.call(row, "_proposedIncreaseValue");

  let displayVal = hasExplicitIncrease
    ? row._increaseValue
    : increaseValueForDisplay(
        { ...row, Increase_Type__c: type || null },
        "Increase_Type__c",
        "Increase_Percent__c",
        "Increase_Amount__c",
        "Final_Price__c"
      );

  const existingProposedType = row?.Proposed_Increase_Type__c;
  const existingProposedCoerced = coerceIncreaseType(existingProposedType);
  let proposedDisplayVal = hasExplicitProposed
    ? row._proposedIncreaseValue
    : increaseValueForDisplay(
        {
          ...row,
          Proposed_Increase_Type__c: existingProposedCoerced || type || null
        },
        "Proposed_Increase_Type__c",
        "Proposed_Increase_Percent__c",
        "Proposed_Increase_Amount__c",
        "Proposed_Final_Price__c"
      );

  const hasProposedValue =
    proposedDisplayVal !== null &&
    proposedDisplayVal !== undefined &&
    proposedDisplayVal !== "";
  const proposedType = existingProposedCoerced
    ? existingProposedCoerced
    : hasProposedValue
      ? type
      : "";

  const out = {
    ...row,
    Increase_Type__c: type || null,
    Proposed_Increase_Type__c: proposedType || null,
    Status__c: status
  };

  if (
    hasExplicitIncrease ||
    (displayVal !== null && displayVal !== undefined && displayVal !== "") ||
    type === ""
  ) {
    applyIncreaseFieldsFromDisplay(out, type, displayVal);
  }

  if (hasProposedValue || existingProposedCoerced) {
    applyIncreaseFieldsFromDisplay(
      out,
      proposedType || type,
      proposedDisplayVal,
      {
        typeField: "Proposed_Increase_Type__c",
        percentField: "Proposed_Increase_Percent__c",
        amountField: "Proposed_Increase_Amount__c",
        priceField: "Proposed_Final_Price__c"
      }
    );
  } else {
    out.Proposed_Increase_Type__c = null;
    out.Proposed_Increase_Percent__c = null;
    out.Proposed_Increase_Amount__c = null;
    out.Proposed_Final_Price__c = null;
  }

  out._increaseValue = increaseValueForDisplay(
    out,
    "Increase_Type__c",
    "Increase_Percent__c",
    "Increase_Amount__c",
    "Final_Price__c"
  );
  out._proposedIncreaseValue = increaseValueForDisplay(
    out,
    "Proposed_Increase_Type__c",
    "Proposed_Increase_Percent__c",
    "Proposed_Increase_Amount__c",
    "Proposed_Final_Price__c"
  );
  out._originalIncreaseValue = increaseValueForDisplay(
    out,
    "Original_Increase_Type__c",
    "Original_Increase_Percent__c",
    "Original_Increase_Amount__c",
    "Original_Final_Price__c"
  );

  const pending = hasPendingProposed(out);
  out._pendingCellClass = pending ? "iter-pending-proposed" : "";
  out._pendingAttentionHint = formatPendingProposedAttentionMessage(out);

  out._isEditable = !completed;
  out._isProposedEditable = false;
  // Working PI editable only on unsaved (new-*) rows; locked after first save.
  out._isWorkingIncreaseEditable = !out.Id && !completed;
  return out;
}

function decorateIterationRow(it, index) {
  const rowKey = it?.Id || it?.rowKey || "new-" + String(index + 1);
  return normalizeIterationRow({ ...it, rowKey });
}

/** Selected iteration for Approve; must be saved (have Id) and not Completed. */
export function selectedApprovingIteration(row) {
  const keys = row?.selectedRowKeys || [];
  if (keys.length !== 1) return null;
  const key = keys[0];
  return (
    (row?.iterations || []).find((it) => it.rowKey === key || it.Id === key) ||
    null
  );
}

function withApproveUiState(row) {
  const selectedRowKeys = row.selectedRowKeys || [];
  const selected = selectedApprovingIteration(row);
  const canApprove =
    !!selected?.Id &&
    selected.Status__c !== "Completed" &&
    selected.Status__c !== "Inactive" &&
    hasPendingProposed(selected);
  const canDiscard =
    !!selected?.Id &&
    selected.Status__c !== "Completed" &&
    selected.Status__c !== "Inactive" &&
    hasPendingProposed(selected);
  const canRevert =
    !!selected?.Id &&
    selected.Status__c !== "Completed" &&
    selected.Status__c !== "Inactive" &&
    !!(
      selected.Original_Increase_Type__c ||
      selected.Original_Increase_Percent__c != null ||
      selected.Original_Increase_Amount__c != null ||
      selected.Original_Final_Price__c != null
    );
  const canHistory = !!selected?.Id;
  return {
    ...row,
    selectedRowKeys,
    approveDisabled: !canApprove,
    discardDisabled: !canDiscard,
    revertDisabled: !canRevert,
    historyDisabled: !canHistory,
    approveSelectionLabel: selected
      ? "Seq " + String(selected.Sequence__c ?? "")
      : ""
  };
}

export function formatIterationsChipValue(remaining, configuredCount) {
  const n = remaining == null ? 0 : Number(remaining);
  const m =
    configuredCount == null || configuredCount === ""
      ? null
      : Number(configuredCount);
  if (m == null || Number.isNaN(m)) {
    return String(Number.isNaN(n) ? 0 : n);
  }
  return String(Number.isNaN(n) ? 0 : n) + " out of " + String(m);
}

export function mapLoadedIterationRows(rows) {
  return (rows || []).map((row) => {
    const iterations = (row.iterations || []).map(decorateIterationRow);
    const configuredCount =
      row.configuredCount == null
        ? iterations.length
        : Number(row.configuredCount);
    const remaining = row.remaining == null ? 0 : row.remaining;
    return withApproveUiState({
      ...row,
      displayName: buildProductDisplayName(row),
      dateRangeLabel: buildDateRangeLabel(row),
      remaining,
      configuredCount,
      remainingDisplay: formatIterationsChipValue(remaining, configuredCount),
      bulkSelected: false,
      iterations,
      draftValues: [],
      selectedRowKeys: []
    });
  });
}

export function buildBulkProductOptions(screenRows) {
  return (screenRows || []).map((row) => ({
    lineId: row.lineId,
    label: row.displayName || buildProductDisplayName(row),
    checked: row.bulkSelected === true
  }));
}

export function toggleBulkProductSelection(screenRows, lineId, checked) {
  return (screenRows || []).map((row) => {
    return row.lineId === lineId ? { ...row, bulkSelected: checked } : row;
  });
}

export function buildBulkTemplateFromForm(form) {
  const template = {};
  if (
    form.duration !== null &&
    form.duration !== undefined &&
    form.duration !== ""
  ) {
    template.Duration_Months__c = Number(form.duration);
  }
  if (form.notice !== null && form.notice !== undefined && form.notice !== "") {
    template.Advance_Notice_Days__c = Number(form.notice);
  }
  if (form.increaseType) {
    template.Increase_Type__c = coerceIncreaseType(form.increaseType);
  }
  if (
    form.increaseValue !== null &&
    form.increaseValue !== undefined &&
    form.increaseValue !== ""
  ) {
    routeIncreaseValueToTemplate(
      template,
      form.increaseType,
      form.increaseValue,
      {
        percent: "Increase_Percent__c",
        amount: "Increase_Amount__c",
        price: "Final_Price__c"
      }
    );
  }
  if (form.proposedType) {
    template.Proposed_Increase_Type__c = coerceIncreaseType(form.proposedType);
  }
  if (
    form.proposedValue !== null &&
    form.proposedValue !== undefined &&
    form.proposedValue !== ""
  ) {
    routeIncreaseValueToTemplate(
      template,
      form.proposedType || form.increaseType,
      form.proposedValue,
      {
        percent: "Proposed_Increase_Percent__c",
        amount: "Proposed_Increase_Amount__c",
        price: "Proposed_Final_Price__c"
      }
    );
  }
  return template;
}

export function buildBulkApplyRequest(screenRows) {
  const rows = screenRows || [];
  const lineIds = rows.map((row) => row.lineId);
  const endDates = {};
  const iterationIdsByLine = {};
  let skippedCompleted = 0;
  let unsavedSelected = 0;
  let hasAnySelection = false;

  for (const row of rows) {
    endDates[row.lineId] = row.endDate;
  }

  for (const tile of groupScreenRowsIntoTiles(rows)) {
    const anchor = tile.anchorProduct;
    const selectedKeys = anchor?.selectedRowKeys || [];
    if (!selectedKeys.length) {
      continue;
    }
    hasAnySelection = true;

    for (const product of tile.products) {
      const targetIds = [];
      for (const key of selectedKeys) {
        const anchorIt = iterationByKey(anchor.iterations, key);
        if (!anchorIt) continue;
        const it = iterationForProductSequence(product, anchorIt.Sequence__c);
        if (!it) continue;
        if (it.Status__c === "Completed" || it.Status__c === "Inactive") {
          skippedCompleted++;
          continue;
        }
        if (!it.Id) {
          unsavedSelected++;
          continue;
        }
        targetIds.push(it.Id);
      }
      if (targetIds.length) {
        iterationIdsByLine[product.lineId] = targetIds;
      }
    }
  }

  return {
    lineIds,
    endDates,
    iterationIdsByLine,
    skippedCompleted,
    unsavedSelected,
    scopedProductCount: rows.length,
    missingSelection: !hasAnySelection
  };
}

export function defaultNewIterationRow(existingCount) {
  const seq = (existingCount || 0) + 1;
  return normalizeIterationRow({
    rowKey: "new-" + String(Date.now()) + "-" + String(seq),
    Sequence__c: seq,
    Duration_Months__c: 12,
    Advance_Notice_Days__c: 30,
    Increase_Type__c: null,
    Increase_Percent__c: null,
    Increase_Amount__c: null,
    Final_Price__c: null,
    Status__c: "Original",
    _increaseValue: null
  });
}

export function addIterationRow(screenRows, lineId) {
  return (screenRows || []).map((row) => {
    if (row.lineId !== lineId) return row;
    const iterations = row.iterations || [];
    const next = [...iterations, defaultNewIterationRow(iterations.length)];
    const remaining = (row.remaining == null ? 0 : Number(row.remaining)) + 1;
    const configuredCount = next.length;
    return withApproveUiState({
      ...row,
      iterations: next,
      remaining,
      configuredCount,
      remainingDisplay: formatIterationsChipValue(remaining, configuredCount)
    });
  });
}

export function mergeIterationDraftValues(screenRows, lineId, drafts) {
  if (!lineId || !drafts?.length) return screenRows;
  return (screenRows || []).map((row) => {
    if (row.lineId !== lineId) return row;
    const updated = (row.iterations || []).map((it) => {
      const draft =
        drafts.find((d) => d.rowKey && d.rowKey === it.rowKey) ||
        drafts.find((d) => d.Id && d.Id === it.Id);
      if (!draft) return it;
      const merged = { ...it, ...draft, rowKey: it.rowKey };
      if (
        Object.prototype.hasOwnProperty.call(draft, "Increase_Type__c") &&
        draft.Increase_Type__c !== it.Increase_Type__c
      ) {
        merged._increaseValue = null;
        merged.Increase_Percent__c = null;
        merged.Increase_Amount__c = null;
        merged.Final_Price__c = null;
      }
      if (
        Object.prototype.hasOwnProperty.call(
          draft,
          "Proposed_Increase_Type__c"
        ) &&
        draft.Proposed_Increase_Type__c !== it.Proposed_Increase_Type__c
      ) {
        merged._proposedIncreaseValue = null;
        merged.Proposed_Increase_Percent__c = null;
        merged.Proposed_Increase_Amount__c = null;
        merged.Proposed_Final_Price__c = null;
      }
      const priorStatus = it.Status__c;
      if (draft.Status__c && draft.Status__c !== priorStatus) {
        merged.Status__c = priorStatus;
      }
      return normalizeIterationRow(merged);
    });
    return withApproveUiState({
      ...row,
      iterations: updated,
      draftValues: []
    });
  });
}

export function setSelectedIterationKeys(screenRows, lineId, selectedKeys) {
  return (screenRows || []).map((row) => {
    if (row.lineId !== lineId) return row;
    return withApproveUiState({
      ...row,
      selectedRowKeys: selectedKeys || []
    });
  });
}

function hasCommercialValue(displayVal) {
  return displayVal !== null && displayVal !== undefined && displayVal !== "";
}

function effectiveCommercialDisplayVal(row, prefix) {
  if (prefix === "Proposed") {
    if (
      row != null &&
      Object.prototype.hasOwnProperty.call(row, "_proposedIncreaseValue")
    ) {
      return row._proposedIncreaseValue;
    }
    return increaseValueForDisplay(
      row,
      "Proposed_Increase_Type__c",
      "Proposed_Increase_Percent__c",
      "Proposed_Increase_Amount__c",
      "Proposed_Final_Price__c"
    );
  }
  if (
    row != null &&
    Object.prototype.hasOwnProperty.call(row, "_increaseValue")
  ) {
    return row._increaseValue;
  }
  return increaseValueForDisplay(
    row,
    "Increase_Type__c",
    "Increase_Percent__c",
    "Increase_Amount__c",
    "Final_Price__c"
  );
}

function commercialValueErrors(row, seqLabel, prefix) {
  const errors = [];
  const status = coerceStatus(row?.Status__c || "Original");
  if (status === "Completed" || status === "Inactive") {
    return errors;
  }
  const typeField = prefix + "_Increase_Type__c";
  const type = coerceIncreaseType(row?.[typeField]);
  const displayVal = effectiveCommercialDisplayVal(row, prefix);
  const valueLabel =
    prefix === "Proposed" ? "Proposed Value" : "Price Increase Value";
  if (type && !hasCommercialValue(displayVal)) {
    errors.push(
      "Iteration " +
        seqLabel +
        ": " +
        valueLabel +
        " is required when a type is selected."
    );
  }
  return errors;
}

export function validateIterationCommercialRows(iterations) {
  const errors = [];
  for (const it of iterations || []) {
    const row = normalizeIterationRow(it);
    const seqLabel = String(row.Sequence__c ?? "?");
    errors.push(...commercialValueErrors(row, seqLabel, "Increase"));
    errors.push(...commercialValueErrors(row, seqLabel, "Proposed"));
  }
  return errors;
}

export function validateScreenRowsCommercial(screenRows) {
  const errors = [];
  for (const product of screenRows || []) {
    errors.push(...validateIterationCommercialRows(product.iterations));
  }
  return errors;
}

export function validateBulkCommercialForm(form) {
  const errors = [];
  if (form.increaseType && !hasCommercialValue(form.increaseValue)) {
    errors.push(
      "Price Increase Value is required when Price Increase Type is selected."
    );
  }
  if (form.proposedType && !hasCommercialValue(form.proposedValue)) {
    errors.push("Proposed Value is required when Proposed Type is selected.");
  }
  return errors;
}

export function iterationsForSave(iterations) {
  return (iterations || []).map((it) => {
    const normalized = normalizeIterationRow(it);
    const payload = { ...normalized };
    delete payload.rowKey;
    delete payload._increaseValue;
    delete payload._proposedIncreaseValue;
    delete payload._originalIncreaseValue;
    delete payload._isEditable;
    delete payload._isProposedEditable;
    delete payload._isWorkingIncreaseEditable;
    delete payload._pendingCellClass;
    delete payload._pendingAttentionHint;
    return payload;
  });
}

const PLAN_SNAPSHOT_FIELDS = [
  "Sequence__c",
  "Duration_Months__c",
  "Advance_Notice_Days__c",
  "Increase_Type__c",
  "Increase_Percent__c",
  "Increase_Amount__c",
  "Final_Price__c",
  "Status__c",
  "_increaseValue",
  "Proposed_Increase_Type__c",
  "Proposed_Increase_Percent__c",
  "Proposed_Increase_Amount__c",
  "Proposed_Final_Price__c",
  "_proposedIncreaseValue"
];

const COPY_PLAN_SNAPSHOT_FIELDS = PLAN_SNAPSHOT_FIELDS.filter(
  (field) => field !== "Status__c"
);

const EMPTY_PLAN_FINGERPRINT = "empty";

/** Fingerprint for grouping: working + proposed + schedule per sequence. */
export function buildPlanFingerprint(iterations) {
  const list = [...(iterations || [])].sort(
    (a, b) => (a.Sequence__c ?? 0) - (b.Sequence__c ?? 0)
  );
  if (!list.length) {
    return EMPTY_PLAN_FINGERPRINT;
  }
  return list
    .map((it) => {
      const row = normalizeIterationRow(it);
      return [
        row.Sequence__c ?? "",
        row.Duration_Months__c ?? "",
        row.Advance_Notice_Days__c ?? "",
        row.Increase_Type__c ?? "",
        row._increaseValue ?? "",
        row.Proposed_Increase_Type__c ?? "",
        row._proposedIncreaseValue ?? "",
        row.Status__c ?? ""
      ].join("|");
    })
    .join(";");
}

/** Group screen rows into plan tiles; largest product count first. */
export function groupScreenRowsIntoTiles(screenRows) {
  const groups = new Map();
  for (const row of screenRows || []) {
    const fingerprint = buildPlanFingerprint(row.iterations);
    if (!groups.has(fingerprint)) {
      groups.set(fingerprint, []);
    }
    groups.get(fingerprint).push(row);
  }
  const tiles = [...groups.entries()].map(([tileKey, products]) => ({
    tileKey,
    products,
    productCount: products.length,
    anchorProduct: products[0],
    anchorLineId: products[0].lineId
  }));
  tiles.sort((a, b) => b.productCount - a.productCount);
  return tiles;
}

/** Single-product tiles auto-select their chip so row actions work without an extra click. */
export function defaultTileChipSelections(screenRows) {
  const selections = {};
  for (const tile of groupScreenRowsIntoTiles(screenRows)) {
    if (tile.productCount === 1 && tile.products[0]?.lineId) {
      selections[tile.tileKey] = tile.products[0].lineId;
    }
  }
  return selections;
}

export function productHasPendingProposed(iterations) {
  return (iterations || []).some((it) => hasPendingProposed(it));
}

export function iterationByKey(iterations, key) {
  return (iterations || []).find((it) => it.rowKey === key || it.Id === key);
}

export function iterationsByKeys(iterations, keys) {
  return (keys || [])
    .map((key) => iterationByKey(iterations, key))
    .filter(Boolean);
}

const LOCKED_COPY_STATUSES = new Set(["Completed", "Inactive"]);

function isLockedCopyStatus(status) {
  return LOCKED_COPY_STATUSES.has(coerceStatus(status));
}

function workingScheduleSnapshot(iteration) {
  const row = normalizeIterationRow(iteration);
  const snap = {};
  for (const field of PLAN_SNAPSHOT_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(row, field)) {
      snap[field] = row[field];
    }
  }
  return snap;
}

function copyScheduleSnapshot(iteration) {
  if (isLockedCopyStatus(iteration?.Status__c)) {
    return null;
  }
  const row = normalizeIterationRow(iteration);
  const snap = {};
  for (const field of COPY_PLAN_SNAPSHOT_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(row, field)) {
      snap[field] = row[field];
    }
  }
  return snap;
}

function applyWorkingScheduleSnapshot(target, snapshot) {
  const merged = {
    ...target,
    ...snapshot,
    rowKey: target.rowKey,
    Id: target.Id,
    Status__c: target.Status__c
  };
  return normalizeIterationRow(merged);
}

/** Copy anchor working/proposed/schedule fields onto sibling products in the same tile (by sequence). */
export function propagateAnchorWorkingSchedule(
  screenRows,
  anchorLineId,
  tileLineIds,
  anchorIterations
) {
  const anchorSeqList = [...(anchorIterations || [])].sort(
    (a, b) => (a.Sequence__c ?? 0) - (b.Sequence__c ?? 0)
  );

  return (screenRows || []).map((row) => {
    if (!tileLineIds.includes(row.lineId) || row.lineId === anchorLineId) {
      return row;
    }

    const existing = row.iterations || [];
    const bySeq = new Map(existing.map((it) => [String(it.Sequence__c), it]));
    const updated = [];

    for (const anchorIt of anchorSeqList) {
      const seqKey = String(anchorIt.Sequence__c);
      const target = bySeq.get(seqKey);
      const snapshot = workingScheduleSnapshot(anchorIt);
      if (target) {
        updated.push(applyWorkingScheduleSnapshot(target, snapshot));
        bySeq.delete(seqKey);
      } else {
        updated.push(
          normalizeIterationRow({
            ...snapshot,
            rowKey:
              "new-" + String(Date.now()) + "-" + row.lineId + "-" + seqKey,
            Sequence__c: anchorIt.Sequence__c
          })
        );
      }
    }

    for (const leftover of bySeq.values()) {
      updated.push(normalizeIterationRow(leftover));
    }

    updated.sort((a, b) => (a.Sequence__c ?? 0) - (b.Sequence__c ?? 0));
    const remaining =
      row.remaining == null ? updated.length : Number(row.remaining);
    const configuredCount = updated.length;
    return withApproveUiState({
      ...row,
      iterations: updated,
      remaining,
      configuredCount,
      remainingDisplay: formatIterationsChipValue(remaining, configuredCount)
    });
  });
}

export function mergeTileDraftValues(
  screenRows,
  tileLineIds,
  anchorLineId,
  drafts
) {
  let updated = mergeIterationDraftValues(screenRows, anchorLineId, drafts);
  const anchorRow = updated.find((row) => row.lineId === anchorLineId);
  if (!anchorRow) {
    return updated;
  }
  return propagateAnchorWorkingSchedule(
    updated,
    anchorLineId,
    tileLineIds,
    anchorRow.iterations
  );
}

export function applyAllPendingDrafts(screenRows, draftEntries) {
  let rows = screenRows || [];
  for (const entry of draftEntries || []) {
    if (!entry?.drafts?.length) {
      continue;
    }
    rows = mergeTileDraftValues(
      rows,
      entry.tileLineIds || [],
      entry.anchorLineId,
      entry.drafts
    );
  }
  return rows;
}

export function hasPendingDatatableDrafts(draftEntries) {
  return (draftEntries || []).some((entry) => (entry?.drafts || []).length > 0);
}

export function addIterationRowForTile(screenRows, tileLineIds, anchorLineId) {
  let updated = addIterationRow(screenRows, anchorLineId);
  const anchorRow = updated.find((row) => row.lineId === anchorLineId);
  if (!anchorRow) {
    return updated;
  }
  const newAnchorRow = anchorRow.iterations[anchorRow.iterations.length - 1];
  const snapshot = workingScheduleSnapshot(newAnchorRow);

  return updated.map((row) => {
    if (!tileLineIds.includes(row.lineId) || row.lineId === anchorLineId) {
      return row;
    }
    const iterations = [
      ...(row.iterations || []),
      normalizeIterationRow({
        ...snapshot,
        rowKey:
          "new-" +
          String(Date.now()) +
          "-" +
          row.lineId +
          "-" +
          String(snapshot.Sequence__c),
        Id: undefined
      })
    ];
    const remaining =
      row.remaining == null ? iterations.length : Number(row.remaining) + 1;
    const configuredCount = iterations.length;
    return withApproveUiState({
      ...row,
      iterations,
      remaining,
      configuredCount,
      remainingDisplay: formatIterationsChipValue(remaining, configuredCount)
    });
  });
}

function resequenceIterationsAfterRemoval(iterations) {
  return (iterations || [])
    .filter((it) => it != null)
    .map((it, idx) => normalizeIterationRow({ ...it, Sequence__c: idx + 1 }));
}

function countNonCompletedRemaining(iterations) {
  return (iterations || []).filter((it) => it.Status__c !== "Completed").length;
}

/** Remove plan rows by sequence for every product in a shared tile. */
export function removeIterationRowsForTile(screenRows, tileLineIds, sequences) {
  const seqKeys = new Set((sequences || []).map((seq) => String(seq)));
  if (!seqKeys.size) {
    return screenRows;
  }
  return (screenRows || []).map((row) => {
    if (!tileLineIds.includes(row.lineId)) {
      return row;
    }
    const filtered = (row.iterations || []).filter(
      (it) => !seqKeys.has(String(it.Sequence__c))
    );
    const iterations = resequenceIterationsAfterRemoval(filtered);
    const configuredCount = iterations.length;
    const remaining = countNonCompletedRemaining(iterations);
    return withApproveUiState({
      ...row,
      iterations,
      configuredCount,
      remaining,
      remainingDisplay: formatIterationsChipValue(remaining, configuredCount),
      selectedRowKeys: []
    });
  });
}

export function removeIterationRowForTile(screenRows, tileLineIds, sequence) {
  return removeIterationRowsForTile(screenRows, tileLineIds, [sequence]);
}

function copyPlanRowFingerprint(iteration) {
  const row = normalizeIterationRow(iteration);
  return [
    row.Sequence__c ?? "",
    row.Duration_Months__c ?? "",
    row.Advance_Notice_Days__c ?? "",
    row.Increase_Type__c ?? "",
    row._increaseValue ?? "",
    row.Proposed_Increase_Type__c ?? "",
    row._proposedIncreaseValue ?? "",
    row.Status__c ?? ""
  ].join("|");
}

/** Block copy when the source plan includes Completed or Inactive rows. */
export function copyFromBlockedReason(sourceIterations) {
  if ((sourceIterations || []).some((it) => isLockedCopyStatus(it.Status__c))) {
    return "Completed iterations cannot be copied.";
  }
  return null;
}

/** Summarize what Copy from would change before persisting. */
export function summarizeCopyFromPlan(targetIterations, sourceIterations) {
  const copyableSource = (sourceIterations || []).filter(
    (it) => !isLockedCopyStatus(it.Status__c)
  );
  const before = (targetIterations || []).map((it) =>
    normalizeIterationRow(it)
  );
  const merged = applyWorkingPlanBySequence(targetIterations, copyableSource);
  const beforeBySeq = new Map(before.map((it) => [String(it.Sequence__c), it]));

  let skippedLocked = 0;
  let updated = 0;
  let added = 0;

  for (const sourceIt of copyableSource) {
    const existing = beforeBySeq.get(String(sourceIt.Sequence__c));
    if (existing && isLockedCopyStatus(existing.Status__c)) {
      skippedLocked++;
    }
  }

  for (const afterRow of merged) {
    const seqKey = String(afterRow.Sequence__c);
    const prior = beforeBySeq.get(seqKey);
    if (!prior) {
      added++;
      continue;
    }
    if (isLockedCopyStatus(prior.Status__c)) {
      continue;
    }
    if (copyPlanRowFingerprint(prior) !== copyPlanRowFingerprint(afterRow)) {
      updated++;
    }
  }

  return {
    merged,
    skippedLocked,
    updated,
    added,
    changed: updated + added > 0
  };
}

export function buildCopyFromConfirmMessage(productCount, skippedLocked) {
  let message =
    "Copy the plan from the selected source onto all " +
    String(productCount) +
    " product(s) in this tile? Working and schedule values will be updated; proposed values are kept.";
  if (skippedLocked > 0) {
    message +=
      " Completed or Inactive rows on the target cannot be changed and will be skipped.";
  }
  return message;
}

export function buildCopyFromResultMessage({ updated, added, skippedLocked }) {
  const changed = (updated || 0) + (added || 0);
  if (changed === 0) {
    return "Completed iterations cannot be copied.";
  }
  let message = "Copied plan to " + String(changed) + " iteration row";
  message += changed === 1 ? "" : "s";
  message += ".";
  if (skippedLocked > 0) {
    message += " Completed rows on the target were left unchanged.";
  }
  return message;
}

/** Full plan replace: source working/schedule onto target by sequence; add open rows; drop non-completed extras; keep Completed. */
export function applyWorkingPlanBySequence(targetIterations, sourceIterations) {
  const sourceList = [...(sourceIterations || [])].sort(
    (a, b) => (a.Sequence__c ?? 0) - (b.Sequence__c ?? 0)
  );
  if (!sourceList.length) {
    return (targetIterations || []).map((it) => normalizeIterationRow(it));
  }

  const targetBySeq = new Map(
    (targetIterations || []).map((it) => [String(it.Sequence__c), it])
  );
  const updated = [];

  for (const sourceIt of sourceList) {
    const seqKey = String(sourceIt.Sequence__c);
    const existing = targetBySeq.get(seqKey);
    const snapshot = copyScheduleSnapshot(sourceIt);
    if (!snapshot) {
      continue;
    }

    if (isLockedCopyStatus(existing?.Status__c)) {
      updated.push(normalizeIterationRow(existing));
    } else if (existing) {
      updated.push(applyWorkingScheduleSnapshot(existing, snapshot));
    } else {
      updated.push(
        normalizeIterationRow({
          ...snapshot,
          Status__c: "Original",
          rowKey:
            "new-" +
            String(Date.now()) +
            "-" +
            seqKey +
            "-" +
            String(Math.random()).slice(2, 8),
          Id: undefined
        })
      );
    }
    targetBySeq.delete(seqKey);
  }

  for (const leftover of targetBySeq.values()) {
    if (isLockedCopyStatus(leftover.Status__c)) {
      updated.push(normalizeIterationRow(leftover));
    }
  }

  updated.sort((a, b) => (a.Sequence__c ?? 0) - (b.Sequence__c ?? 0));
  return updated;
}

export function resolveProposeTargetIterations(
  anchorIterations,
  selectedRowKeys
) {
  if (!selectedRowKeys?.length) {
    return [];
  }
  return iterationsByKeys(anchorIterations || [], selectedRowKeys).filter(
    (it) => it.Status__c !== "Completed" && it.Status__c !== "Inactive"
  );
}

/** Selected iterations eligible for Approve/Reject (saved, open, pending proposed). */
export function resolveApproveTargetIterations(
  anchorIterations,
  selectedRowKeys
) {
  if (!selectedRowKeys?.length) {
    return [];
  }
  return iterationsByKeys(anchorIterations || [], selectedRowKeys).filter(
    (it) =>
      it.Id &&
      it.Status__c !== "Completed" &&
      it.Status__c !== "Inactive" &&
      hasPendingProposed(it)
  );
}

export function resolveProposeTargetIteration(
  anchorIterations,
  selectedRowKeys
) {
  const targets = resolveProposeTargetIterations(
    anchorIterations,
    selectedRowKeys
  );
  return targets.length ? targets[0] : null;
}

export function iterationForProductSequence(productRow, sequence) {
  return (productRow?.iterations || []).find(
    (it) => String(it.Sequence__c) === String(sequence)
  );
}

export function buildProposedPayload(type, displayVal) {
  const out = {};
  applyIncreaseFieldsFromDisplay(out, type, displayVal, {
    typeField: "Proposed_Increase_Type__c",
    percentField: "Proposed_Increase_Percent__c",
    amountField: "Proposed_Increase_Amount__c",
    priceField: "Proposed_Final_Price__c"
  });
  return out;
}

export function resolveSelectedIterationForChip(
  anchorIterations,
  chipIterations,
  selectedRowKeys
) {
  if (!selectedRowKeys?.length) {
    return null;
  }
  if (selectedRowKeys.length === 1) {
    const anchorIt = iterationByKey(anchorIterations, selectedRowKeys[0]);
    if (anchorIt) {
      return iterationForProductSequence(
        { iterations: chipIterations },
        anchorIt.Sequence__c
      );
    }
    return iterationByKey(chipIterations, selectedRowKeys[0]);
  }
  return null;
}

/** Resolve iteration Ids on every product in a tile for selected anchor rows. */
export function resolveFanOutIterationIds(
  tileProducts,
  anchorIterations,
  selectedRowKeys,
  { requirePending = false, requireOpen = true } = {}
) {
  if (!selectedRowKeys?.length) {
    return [];
  }
  let anchors = iterationsByKeys(anchorIterations || [], selectedRowKeys);
  if (requireOpen) {
    anchors = anchors.filter(
      (it) => it.Status__c !== "Completed" && it.Status__c !== "Inactive"
    );
  }
  if (requirePending) {
    anchors = anchors.filter((it) => hasPendingProposed(it));
  }
  const ids = [];
  for (const anchorIt of anchors) {
    for (const product of tileProducts || []) {
      // Prefer the selected row's Id when it belongs to this product so
      // duplicate Sequence__c values cannot redirect to another iteration.
      let it =
        anchorIt?.Id &&
        (product.iterations || []).find((row) => row.Id === anchorIt.Id);
      if (!it) {
        it = iterationForProductSequence(product, anchorIt.Sequence__c);
      }
      if (it?.Id) {
        ids.push(it.Id);
      }
    }
  }
  return [...new Set(ids)];
}

/** Resolve saved iteration Ids on a chip product for multi-select history. */
export function resolveHistoryIterationIds(
  chipProductRow,
  anchorIterations,
  selectedRowKeys
) {
  if (!selectedRowKeys?.length || !chipProductRow) {
    return [];
  }
  const anchors = iterationsByKeys(anchorIterations || [], selectedRowKeys);
  return anchors
    .map((anchorIt) =>
      iterationForProductSequence(chipProductRow, anchorIt.Sequence__c)
    )
    .filter((it) => it?.Id)
    .map((it) => it.Id);
}

export function chipActionUiState(
  productCount,
  selectedChipRow,
  anchorIterations,
  selectedRowKeys,
  busy,
  fallbackProductRow = null
) {
  const chipSelected = !!selectedChipRow;
  const chipProductRow = selectedChipRow || fallbackProductRow;
  const selectedCount = selectedRowKeys?.length || 0;
  const approveTargets = resolveApproveTargetIterations(
    anchorIterations,
    selectedRowKeys
  );
  const hasAnyPendingAmongSelected = approveTargets.length > 0;
  // Use fallback product iterations when no chip so History/Restore stay
  // enableable; picking a product then runs against that product's rows.
  const selected = resolveSelectedIterationForChip(
    anchorIterations,
    chipProductRow?.iterations || [],
    selectedRowKeys
  );
  const canRevert =
    !!selected?.Id &&
    selected.Status__c !== "Completed" &&
    selected.Status__c !== "Inactive" &&
    !!(
      selected.Original_Increase_Type__c ||
      selected.Original_Increase_Percent__c != null ||
      selected.Original_Increase_Amount__c != null ||
      selected.Original_Final_Price__c != null
    );
  const historyIds = resolveHistoryIterationIds(
    chipProductRow,
    anchorIterations,
    selectedRowKeys
  );
  const canHistory = historyIds.length > 0;

  return {
    chipSelected,
    selectedIteration: selected,
    proposeDisabled: !selectedCount || busy,
    approveDisabled: !selectedCount || !hasAnyPendingAmongSelected || busy,
    rejectDisabled: !selectedCount || !hasAnyPendingAmongSelected || busy,
    revertDisabled: !canRevert || busy || !selected,
    historyDisabled: busy || !canHistory,
    approveSelectionLabel:
      approveTargets.length === 1
        ? "Seq " + String(approveTargets[0].Sequence__c ?? "")
        : approveTargets.length > 1
          ? String(approveTargets.length) + " iterations"
          : ""
  };
}

const HISTORY_EVENT_LABELS = {
  Changed: "Changed",
  Approved: "Approved",
  Rejected: "Rejected",
  Status_Changed: "Status changed",
  Reverted: "Reverted",
  Bulk_Applied: "Bulk applied"
};

export function formatHistoryEventType(eventType) {
  if (!eventType) return "";
  return (
    HISTORY_EVENT_LABELS[eventType] || String(eventType).replace(/_/g, " ")
  );
}

export function formatStatusChangeDisplay(priorStatus, newStatus) {
  if (priorStatus && newStatus) {
    return priorStatus + " \u2192 " + newStatus;
  }
  return newStatus || priorStatus || "";
}

export function mapHistoryEventRows(rows, formatDateFn) {
  return (rows || []).map((r, idx) => ({
    key:
      String(r.iterationId || "") +
      "-" +
      String(r.eventAt || "") +
      "-" +
      String(idx),
    iterationId: r.iterationId || "",
    sequence: r.sequence,
    sectionLabel:
      r.sequence != null && r.sequence !== ""
        ? "Iteration " + String(r.sequence)
        : "Iteration",
    eventType: formatHistoryEventType(r.eventType),
    workingDisplay: r.workingDisplay || "",
    proposedDisplay: r.proposedDisplay || "",
    priorWorkingDisplay: r.priorWorkingDisplay || "",
    priorProposedDisplay: r.priorProposedDisplay || "",
    statusChange: formatStatusChangeDisplay(r.priorStatus, r.newStatus),
    actorName: r.actorName || "",
    eventAt: formatDateFn ? formatDateFn(r.eventAt) : r.eventAt || "",
    summary: r.summary || "",
    hasPriorWorking: !!r.priorWorkingDisplay,
    hasPriorProposed: !!r.priorProposedDisplay,
    hasStatusChange: !!(r.priorStatus || r.newStatus)
  }));
}

export function groupHistoryEventsByIteration(rows, formatDateFn) {
  const mapped = mapHistoryEventRows(rows, formatDateFn);
  const groups = new Map();
  for (const row of mapped) {
    const groupKey = row.iterationId || "seq-" + String(row.sequence ?? "");
    if (!groups.has(groupKey)) {
      groups.set(groupKey, {
        sectionKey: groupKey,
        sectionLabel: row.sectionLabel,
        rows: []
      });
    }
    groups.get(groupKey).rows.push(row);
  }
  return [...groups.values()];
}
