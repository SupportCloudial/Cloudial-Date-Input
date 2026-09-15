/**
 * Pure helper functions for packageBuilderTable.
 * Keep these functions `this`-free so they can be tested and reused safely.
 */

/**
 * Apex @AuraEnabled DTOs often deserialize with camelCase property names in LWC.
 * Normalize to the PascalCase keys used throughout Package Builder row logic.
 */
function firstNonBlankString(...candidates) {
  for (const c of candidates) {
    if (c === undefined || c === null) continue;
    const s = String(c).trim();
    if (s) return s;
  }
  return null;
}

export function formatIterationsDisplay(remaining, configuredCount) {
  const n = remaining == null || remaining === "" ? 0 : Number(remaining);
  const m =
    configuredCount == null || configuredCount === ""
      ? null
      : Number(configuredCount);
  if (m == null || Number.isNaN(m)) {
    return String(Number.isNaN(n) ? 0 : n);
  }
  return String(Number.isNaN(n) ? 0 : n) + " out of " + String(m);
}

export function canonicalPackageBuilderProductWireRow(raw) {
  if (!raw || typeof raw !== "object") {
    return raw;
  }
  return {
    ...raw,
    LineItemId: raw.LineItemId ?? raw.lineItemId ?? null,
    Id: raw.Id ?? raw.id ?? null,
    ReplacedOrderProductId: firstNonBlankString(
      raw.ReplacedOrderProductId,
      raw.replacedOrderProductId,
      raw.Replaced_Order_Product__c
    ),
    OriginalOrderProductId: firstNonBlankString(
      raw.OriginalOrderProductId,
      raw.originalOrderProductId,
      raw.Original_Order_Product__c
    ),
    ChangeType: raw.ChangeType ?? raw.changeType ?? null
  };
}

/** Original-order lookup id (camelCase or API name on the row object). */
export function originalOrderProductIdFromRow(row) {
  return firstNonBlankString(
    row?.OriginalOrderProductId,
    row?.originalOrderProductId,
    row?.Original_Order_Product__c
  );
}

/** Replacement lookup id whether the row was normalized or still camelCase-only. */
export function replacedOrderProductIdFromRow(row) {
  return firstNonBlankString(
    row?.ReplacedOrderProductId,
    row?.replacedOrderProductId,
    row?.Replaced_Order_Product__c
  );
}

/** Both Product2 and PricebookEntry must be active to copy a line into a new draft. */
export function isCatalogLineActive(row) {
  if (!row) {
    return false;
  }
  const productActive = row.ProductIsActive ?? row.productIsActive;
  const pbeActive = row.PricebookEntryIsActive ?? row.pricebookEntryIsActive;
  if (productActive === undefined && pbeActive === undefined) {
    return true;
  }
  return productActive === true && pbeActive === true;
}

/**
 * When a replacement parent was omitted from the draft (e.g. inactive catalog),
 * clear the child's replacement link so it displays as a normal line.
 */
export function clearOrphanReplacedOrderProductId(
  row,
  keptLineItemIds,
  normalizeRowIdFn
) {
  if (!row) {
    return row;
  }
  const replacedId = replacedOrderProductIdFromRow(row);
  if (!replacedId) {
    return row;
  }
  const norm =
    typeof normalizeRowIdFn === "function"
      ? normalizeRowIdFn
      : (id) => {
          const s = String(id || "").trim();
          return s ? s.substring(0, 15).toLowerCase() : "";
        };
  if (keptLineItemIds.has(norm(replacedId))) {
    return row;
  }
  const copy = { ...row };
  delete copy.ReplacedOrderProductId;
  delete copy.replacedOrderProductId;
  delete copy.Replaced_Order_Product__c;
  return copy;
}

/**
 * Match a draft row to its Concluded Terms (activated order) line via Original_Order_Product__c,
 * or — before that field is set — the same OrderItem id on the active order (in-memory modify).
 */
export function findActiveOrderLineForDraftRow(
  draftRow,
  activeProducts,
  normalizeRowIdFn
) {
  if (
    !draftRow ||
    !Array.isArray(activeProducts) ||
    activeProducts.length === 0
  ) {
    return null;
  }
  const norm =
    typeof normalizeRowIdFn === "function"
      ? normalizeRowIdFn
      : (id) => {
          const s = String(id || "").trim();
          return s ? s : "";
        };
  const origId = norm(originalOrderProductIdFromRow(draftRow));
  if (origId) {
    const byOrig = activeProducts.find(
      (p) => norm(p?.LineItemId || p?.Id) === origId
    );
    if (byOrig) {
      return byOrig;
    }
  }
  const draftId = norm(draftRow?.LineItemId || draftRow?.Id);
  if (draftId) {
    return (
      activeProducts.find((p) => norm(p?.LineItemId || p?.Id) === draftId) ||
      null
    );
  }
  return null;
}

/** End date to restore when un-terminating a draft line: prefer live EndDate, then archived Original_End. */
export function activeOrderLineEndDateYmd(activeLine) {
  if (!activeLine) {
    return null;
  }
  const liveEnd = normalizeToYyyyMmDd(
    activeLine.EndDate ?? activeLine.End_date__c
  );
  if (liveEnd) {
    return liveEnd;
  }
  return normalizeToYyyyMmDd(
    activeLine.OriginalEndDate ??
      activeLine.OriginalEndDateIso ??
      activeLine.originalEndDateIso ??
      activeLine.Original_End_Date__c
  );
}

/**
 * Replace modal Period End floor passed as replacedActiveEndDateYmd.
 * Activated line end by default; terminated draft shortened below active uses draft end.
 */
export function replaceModalPeriodEndFloorYmd({
  isTerminatedDraftRow,
  draftEndYmd,
  activeEndYmd
}) {
  if (
    isTerminatedDraftRow &&
    draftEndYmd &&
    activeEndYmd &&
    draftEndYmd < activeEndYmd
  ) {
    return draftEndYmd;
  }
  return activeEndYmd || null;
}

/** True when row access type is Monthly (open-ended — no product end date). */
export function monthlyAccessTypeFromRow(row) {
  const at = String(
    row?.AccessType ?? row?.Access_Type__c ?? row?.accessType ?? ""
  ).trim();
  return at.toLowerCase() === "monthly";
}

function draftOriginalEndYmd(draftRow) {
  if (!draftRow) {
    return null;
  }
  const liveEnd = normalizeToYyyyMmDd(
    draftRow.EndDate ?? draftRow.End_date__c ?? draftRow.End_Date__c
  );
  if (liveEnd) {
    return liveEnd;
  }
  return normalizeToYyyyMmDd(
    draftRow.OriginalEndDate ??
      draftRow.OriginalEndDateIso ??
      draftRow.originalEndDateIso ??
      draftRow.Original_End_Date__c
  );
}

/**
 * Merge draft/wire rows as they look after the user clears Termination Reason inline.
 * Strips API + label fields so restore helpers do not treat the row as still terminated.
 */
export function draftRowForClearedTerminationRestore(...rows) {
  const merged = Object.assign({}, ...rows.filter(Boolean));
  merged.TerminationReason = "";
  merged.Termination_Reason__c = null;
  merged.TerminationReasonLabel = "";
  return merged;
}

/** Contract OrderItem row still has a termination reason (API, grid, or label). */
export function orderItemTerminationReasonPresent(row) {
  if (!row) {
    return false;
  }
  if (String(row.TerminationReason ?? "").trim()) {
    return true;
  }
  if (String(row.Termination_Reason__c ?? "").trim()) {
    return true;
  }
  if (String(row.TerminationReasonLabel ?? "").trim()) {
    return true;
  }
  return false;
}

/**
 * Draft row is the moving-out (replaced) parent for a replacement child.
 * @param {string} lineId normalized LineItemId / Id
 * @param {Set<string>} replacedById parent ids referenced by Replaced_Order_Product__c
 */
export function isReplacedMovingOutLineId(lineId, replacedById) {
  const id = String(lineId || "").trim();
  if (!id || !replacedById || typeof replacedById.has !== "function") {
    return false;
  }
  return replacedById.has(id);
}

/**
 * After termination reason is cleared, restore a curtailed draft EndDate to the activated line
 * (or the draft's stored Original_End_Date__c). Returns null when no change is needed.
 * Does not copy end dates from an active line that is still terminated (undo-termination draft).
 * Monthly products never receive a restored end date (open-ended).
 * @param {{ keepCurtailedEndForReplacement?: boolean }} [options] when true, do not restore (replacement pair end)
 */
export function endDateYmdToRestoreAfterClearedTermination(
  draftRow,
  activeLine,
  options
) {
  if (!draftRow || orderItemTerminationReasonPresent(draftRow)) {
    return null;
  }
  if (options?.keepCurtailedEndForReplacement) {
    return null;
  }
  if (monthlyAccessTypeFromRow(draftRow)) {
    return null;
  }
  const draftEnd = normalizeToYyyyMmDd(
    draftRow.EndDate ?? draftRow.End_date__c
  );
  const activeStillTerminated =
    activeLine && orderItemTerminationReasonPresent(activeLine);
  let target = null;
  if (!activeStillTerminated) {
    target = activeOrderLineEndDateYmd(activeLine);
  }
  if (!target) {
    target = draftOriginalEndYmd(draftRow);
  }
  if (!target) {
    return null;
  }
  if (!draftEnd || draftEnd < target) {
    return target;
  }
  return null;
}

/** True when replacement start is the same day as, or the calendar day after, the replaced end. */
export function replacementStartFollowsRemovedEnd(
  replacedEndYmd,
  replacementStartYmd
) {
  if (!replacedEndYmd || !replacementStartYmd) {
    return false;
  }
  if (replacementStartYmd === replacedEndYmd) {
    return true;
  }
  return replacementStartYmd === addCalendarDaysYmd(replacedEndYmd, 1);
}

/**
 * When Replaced_Order_Product__c was cleared (e.g. after a forward contract-start move), infer the
 * parent Removed row from adjacent dates so sort + icons still treat the rows as a pair.
 */
export function inferReplacedOrderProductIdForRow(row, allRows) {
  const explicit = replacedOrderProductIdFromRow(row);
  if (explicit) {
    return explicit;
  }
  if ((row?.ChangeType || "").trim() !== "New") {
    return null;
  }
  const startYmd = normalizeToYyyyMmDd(
    row?.ServiceDate ?? row?.EntryDate ?? row?.Entry_Date__c
  );
  if (!startYmd) {
    return null;
  }
  for (const parent of allRows || []) {
    if ((parent?.ChangeType || "").trim() !== "Removed") {
      continue;
    }
    const parentEndYmd = normalizeToYyyyMmDd(parent?.EndDate);
    if (!parentEndYmd) {
      continue;
    }
    if (replacementStartFollowsRemovedEnd(parentEndYmd, startYmd)) {
      const parentId = normId(parent?.LineItemId || parent?.Id);
      return parentId || null;
    }
  }
  return null;
}

function effectiveReplacedOrderProductIdFromRow(row, allRows) {
  return (
    replacedOrderProductIdFromRow(row) ||
    inferReplacedOrderProductIdForRow(row, allRows)
  );
}

/**
 * Locate the Removed (moving-out) parent row for a replacement child.
 * Covers explicit lookup, date inference, and original-order-product pairing.
 */
export function findRemovedParentRowForReplacementChild(
  childRow,
  allRows,
  normalizeRowIdFn
) {
  if (!childRow || typeof normalizeRowIdFn !== "function") {
    return null;
  }
  const lookupId = normalizeRowIdFn(
    replacedOrderProductIdFromRow(childRow) ||
      inferReplacedOrderProductIdForRow(childRow, allRows)
  );
  if (lookupId) {
    const explicitParent = (allRows || []).find(
      (p) =>
        normalizeRowIdFn(p?.LineItemId || p?.Id) === lookupId &&
        (p?.ChangeType || "").trim() === "Removed"
    );
    if (explicitParent) {
      return explicitParent;
    }
  }
  const childId = normalizeRowIdFn(childRow?.LineItemId || childRow?.Id);
  const childStartYmd = normalizeToYyyyMmDd(
    childRow?.ServiceDate ?? childRow?.EntryDate ?? childRow?.Entry_Date__c
  );
  for (const parent of allRows || []) {
    if ((parent?.ChangeType || "").trim() !== "Removed") {
      continue;
    }
    const parentId = normalizeRowIdFn(parent?.LineItemId || parent?.Id);
    if (!parentId || parentId === childId) {
      continue;
    }
    const parentEndYmd = normalizeToYyyyMmDd(parent?.EndDate);
    if (
      parentEndYmd &&
      childStartYmd &&
      replacementStartFollowsRemovedEnd(parentEndYmd, childStartYmd)
    ) {
      return parent;
    }
    if ((childRow?.ChangeType || "").trim() === "New") {
      const childOrig = normalizeRowIdFn(
        originalOrderProductIdFromRow(childRow)
      );
      const parentOrig = normalizeRowIdFn(
        originalOrderProductIdFromRow(parent)
      );
      if (
        childOrig === parentId ||
        (childOrig && parentOrig && childOrig === parentOrig)
      ) {
        return parent;
      }
    }
  }
  return null;
}

/**
 * True when the replaced parent row is present in the visible grid (not soft-deleted / filtered out).
 */
export function isReplacedParentVisibleInGrid(
  replacedLookupId,
  allRows,
  normalizeRowIdFn
) {
  if (!replacedLookupId) {
    return false;
  }
  const norm =
    typeof normalizeRowIdFn === "function"
      ? normalizeRowIdFn
      : (id) => {
          const s = String(id || "").trim();
          return s ? s : "";
        };
  const lookupNorm = norm(replacedLookupId);
  if (!lookupNorm) {
    return false;
  }
  return (allRows || []).some(
    (r) => norm(r?.LineItemId || r?.Id) === lookupNorm
  );
}

/**
 * Single source of truth for replacement row classification and moving-in icon visibility.
 * @returns {{ hasReplacementLink: boolean, isMovingInRow: boolean, showMovingInIcon: boolean, blocksReplace: boolean, isMovingOutRow: boolean, isReplacedLine: boolean, replacedLookupId: string }}
 */
export function resolveReplacementRowStatus({
  row,
  allRows,
  replacedById,
  replacementChildIds,
  normalizeRowIdFn,
  changeType: changeTypeIn
}) {
  const norm =
    typeof normalizeRowIdFn === "function"
      ? normalizeRowIdFn
      : (id) => {
          const s = String(id || "").trim();
          return s ? s : "";
        };
  let changeType = (
    changeTypeIn ||
    row?.ChangeType ||
    row?.ChangeTypeTitle ||
    ""
  ).trim();
  const currentLineId = norm(row?.LineItemId || row?.Id);
  const replacedLookupId =
    norm(replacedOrderProductIdFromRow(row)) ||
    norm(inferReplacedOrderProductIdForRow(row, allRows));
  const isSupersededRemovedLine = changeType === "Removed";
  const isReplacedLine = Boolean(
    currentLineId &&
    (replacedById?.has?.(currentLineId) || isSupersededRemovedLine)
  );
  const hasReplacementLink = Boolean(replacedLookupId);
  const isMovingInRow =
    !isReplacedLine &&
    (hasReplacementLink ||
      Boolean(currentLineId && replacementChildIds?.has?.(currentLineId)));
  const showMovingInIcon =
    isMovingInRow &&
    (!replacedLookupId ||
      isReplacedParentVisibleInGrid(replacedLookupId, allRows, norm));
  return {
    hasReplacementLink,
    isMovingInRow,
    showMovingInIcon,
    blocksReplace: showMovingInIcon,
    isMovingOutRow: isReplacedLine,
    isReplacedLine,
    replacedLookupId: replacedLookupId || ""
  };
}

export function buildPicklistMapAllowBlank(options) {
  const out = {};
  (options || []).forEach((opt) => {
    if (!opt) return;
    const label =
      typeof opt.label === "string"
        ? opt.label
        : opt.label != null
          ? String(opt.label)
          : "";
    if (!label) return;
    const value = opt.value == null ? "" : String(opt.value);
    out[label] = value;
  });
  return out;
}

function toTime(row) {
  const raw = row?.LineLastModifiedDateTime || row?.LastModifiedDate || null;
  if (!raw) return 0;
  const t = new Date(raw).getTime();
  return Number.isFinite(t) ? t : 0;
}

function normId(value) {
  const s = String(value || "").trim();
  if (!s) return "";
  // Use 15-char form so 15/18-char ids still match each other.
  return s.substring(0, 15);
}

/**
 * Sort rows by latest modification while preserving replacement adjacency.
 * For each replacement chain rooted at a row whose parent is absent from the list:
 *  - root (original / head line) first
 *  - each replacement nested directly under the line it replaces, in chronological order
 *    (oldest replacement next, then the next, … — so replacing a replacement keeps the newest at the bottom)
 *  - chains are followed transitively (A ← B ← C renders as A, B, C)
 * Group order between unrelated chains is still by the newest modified timestamp in that group.
 */
export function sortByLatestWithReplacementGroups(list) {
  const rows = Array.isArray(list) ? [...list] : [];
  if (!rows.length) return rows;

  const byId = new Map();
  rows.forEach((row) => {
    const id = normId(row?.LineItemId || row?.Id);
    if (id) byId.set(id, row);
  });

  const followersByLeader = new Map();
  rows.forEach((row) => {
    const replacedId = normId(
      effectiveReplacedOrderProductIdFromRow(row, rows)
    );
    if (!replacedId || !byId.has(replacedId)) return;
    if (!followersByLeader.has(replacedId))
      followersByLeader.set(replacedId, []);
    followersByLeader.get(replacedId).push(row);
  });

  /**
   * Under `parentRow`, append direct replacements oldest-first, then recurse so nested
   * replace-of-replace rows stay immediately below their parent in the list.
   */
  function appendReplacementSubtree(parentRow, ordered, consumedIds) {
    const parentId = normId(parentRow?.LineItemId || parentRow?.Id);
    if (!parentId) return;
    const kids = [...(followersByLeader.get(parentId) || [])];
    kids.sort((a, b) => toTime(a) - toTime(b));
    for (const kid of kids) {
      const kidId = normId(kid?.LineItemId || kid?.Id);
      if (!kidId || consumedIds.has(kidId)) continue;
      consumedIds.add(kidId);
      ordered.push(kid);
      appendReplacementSubtree(kid, ordered, consumedIds);
    }
  }

  const groupEntries = [];
  const consumedIds = new Set();

  rows.forEach((row) => {
    const id = normId(row?.LineItemId || row?.Id);
    if (!id || consumedIds.has(id)) return;

    const leaderId = normId(effectiveReplacedOrderProductIdFromRow(row, rows));
    const hasKnownLeader = !!leaderId && byId.has(leaderId);
    if (hasKnownLeader) return;

    const orderedRows = [row];
    consumedIds.add(id);
    appendReplacementSubtree(row, orderedRows, consumedIds);

    const latestGroupTime = orderedRows.reduce(
      (max, r) => Math.max(max, toTime(r)),
      0
    );
    groupEntries.push({ latestGroupTime, orderedRows });
  });

  // Handle orphan replacements whose replaced row is not in the current dataset.
  rows.forEach((row) => {
    const id = normId(row?.LineItemId || row?.Id);
    if (!id || consumedIds.has(id)) return;
    consumedIds.add(id);
    groupEntries.push({ latestGroupTime: toTime(row), orderedRows: [row] });
  });

  groupEntries.sort((a, b) => b.latestGroupTime - a.latestGroupTime);
  return groupEntries.flatMap((g) => g.orderedRows);
}

/** Normalize "YYYY-MM-DD" or date-ish strings into a Date object (UTC via Date parsing rules). Returns null when invalid. */
export function parseDate(value) {
  if (!value) return null;
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

/** Inclusive month difference between two UTC month/year values. */
export function monthDiffInclusive(startDate, endDate) {
  if (!startDate || !endDate) return 0;
  const startY = startDate.getUTCFullYear();
  const startM = startDate.getUTCMonth(); // 0-11
  const endY = endDate.getUTCFullYear();
  const endM = endDate.getUTCMonth();
  const diff = (endY - startY) * 12 + (endM - startM) + 1;
  return diff > 0 ? diff : 0;
}

/**
 * Latest bounded End Date among selected products for terminate Exit Date max.
 * Returns null when the array is empty or any entry is blank (Monthly / open-ended).
 */
export function maxSelectedProductEndDateYmd(endDates) {
  const safe = Array.isArray(endDates) ? endDates : [];
  if (safe.length === 0) {
    return null;
  }
  let maxYmd = null;
  for (const raw of safe) {
    const ymd = normalizeToYyyyMmDd(raw);
    if (!ymd) {
      return null;
    }
    if (!maxYmd || ymd > maxYmd) {
      maxYmd = ymd;
    }
  }
  return maxYmd;
}

/** True when exit date is strictly after the latest bounded selected product end date. */
export function isExitDateAfterProductMax(exitDate, endDates) {
  const maxYmd = maxSelectedProductEndDateYmd(endDates);
  const exitYmd = normalizeToYyyyMmDd(exitDate);
  if (!maxYmd || !exitYmd) {
    return false;
  }
  return exitYmd > maxYmd;
}

/**
 * Bulk terminate applies only when the product end is blank (open-ended) or on/after the exit date.
 * Products already ending before the chosen exit date are skipped (not extended).
 */
export function shouldApplyTerminateToProduct(productEndYmd, exitYmd) {
  const exit = normalizeToYyyyMmDd(exitYmd);
  if (!exit) {
    return false;
  }
  const productEnd = normalizeToYyyyMmDd(productEndYmd);
  if (!productEnd) {
    return true;
  }
  return productEnd >= exit;
}

export function normalizeToYyyyMmDd(value) {
  if (value == null || value === "") return null;
  if (typeof value === "string") {
    const s = value.trim();
    if (!s) return null;
    const isoOnly = s.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (isoOnly) {
      return `${isoOnly[1]}-${isoOnly[2]}-${isoOnly[3]}`;
    }
    if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
      return s.slice(0, 10);
    }
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

/** Add integer calendar days to a YYYY-MM-DD string (UTC calendar math). Returns null if invalid. */
export function addCalendarDaysYmd(ymd, delta) {
  if (ymd == null || ymd === "" || !Number.isFinite(delta)) return null;
  const base = normalizeToYyyyMmDd(ymd);
  if (!base || !/^\d{4}-\d{2}-\d{2}$/.test(base)) return null;
  const [yStr, mStr, dStr] = base.split("-");
  const y = Number(yStr);
  const m = Number(mStr);
  const d = Number(dStr);
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d))
    return null;
  const dt = new Date(Date.UTC(y, m - 1, d + delta));
  if (Number.isNaN(dt.getTime())) return null;
  const yy = dt.getUTCFullYear();
  const mm = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(dt.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

function itemIdFromRecord(record) {
  return record?.LineItemId || record?.Id || null;
}

function getRowEndDateRaw(row, isOpportunity) {
  return isOpportunity
    ? row?.End_date__c || row?.End_Date__c || row?.EndDate || row?.EndDate__c
    : row?.EndDate || row?.End_date__c || row?.End_Date__c || row?.EndDate__c;
}

export function hasEndDateFieldInPayload(item, isOpportunity) {
  if (!item) return false;
  if (isOpportunity) {
    return Object.prototype.hasOwnProperty.call(item, "End_date__c");
  }
  return Object.prototype.hasOwnProperty.call(item, "EndDate");
}

function getPayloadEndDateRaw(item, isOpportunity) {
  return isOpportunity ? item?.End_date__c : item?.EndDate;
}

/**
 * Parent end-date rollup semantics:
 * - if any line has blank EndDate => parent end is blank (open-ended wins)
 * - otherwise parent end is max line EndDate.
 */
export function computeParentEndFromRowsAndChanges(
  rows,
  lineItemsToUpdate,
  isOpportunity
) {
  const safeRows = Array.isArray(rows) ? rows : [];
  const safeUpdates = Array.isArray(lineItemsToUpdate) ? lineItemsToUpdate : [];
  const payloadById = new Map();
  for (const item of safeUpdates) {
    const id = itemIdFromRecord(item);
    if (!id || !hasEndDateFieldInPayload(item, isOpportunity)) {
      continue;
    }
    payloadById.set(
      id,
      normalizeToYyyyMmDd(getPayloadEndDateRaw(item, isOpportunity))
    );
  }

  let hasOpenEnded = false;
  let maxEndYmd = null;
  const seenIds = new Set();

  for (const row of safeRows) {
    const id = itemIdFromRecord(row);
    if (!id) continue;
    seenIds.add(id);
    const rowEndYmd = payloadById.has(id)
      ? payloadById.get(id)
      : normalizeToYyyyMmDd(getRowEndDateRaw(row, isOpportunity));
    if (!rowEndYmd) {
      hasOpenEnded = true;
      continue;
    }
    if (!maxEndYmd || rowEndYmd > maxEndYmd) {
      maxEndYmd = rowEndYmd;
    }
  }

  for (const [id, endYmd] of payloadById.entries()) {
    if (seenIds.has(id)) continue;
    if (!endYmd) {
      hasOpenEnded = true;
      continue;
    }
    if (!maxEndYmd || endYmd > maxEndYmd) {
      maxEndYmd = endYmd;
    }
  }

  return {
    hasOpenEnded,
    targetEndYmd: hasOpenEnded ? null : maxEndYmd
  };
}

/**
 * Max bounded line EndDate for draft parent extension (Contract / Order EndDate).
 * Unlike {@link computeParentEndFromRowsAndChanges}, blank line ends are skipped — open-ended
 * Monthly lines do not block extending the parent when a Periodic line moves forward.
 */
export function computeBoundedMaxEndFromRowsAndChanges(
  rows,
  lineItemsToUpdate,
  isOpportunity
) {
  const safeRows = Array.isArray(rows) ? rows : [];
  const safeUpdates = Array.isArray(lineItemsToUpdate) ? lineItemsToUpdate : [];
  const payloadById = new Map();
  for (const item of safeUpdates) {
    const id = itemIdFromRecord(item);
    if (!id || !hasEndDateFieldInPayload(item, isOpportunity)) {
      continue;
    }
    payloadById.set(
      id,
      normalizeToYyyyMmDd(getPayloadEndDateRaw(item, isOpportunity))
    );
  }

  let maxEndYmd = null;
  const seenIds = new Set();
  const consider = (endYmd) => {
    if (!endYmd) return;
    if (!maxEndYmd || endYmd > maxEndYmd) {
      maxEndYmd = endYmd;
    }
  };

  for (const row of safeRows) {
    const id = itemIdFromRecord(row);
    if (!id) continue;
    seenIds.add(id);
    const rowEndYmd = payloadById.has(id)
      ? payloadById.get(id)
      : normalizeToYyyyMmDd(getRowEndDateRaw(row, isOpportunity));
    consider(rowEndYmd);
  }

  for (const [id, endYmd] of payloadById.entries()) {
    if (seenIds.has(id)) continue;
    consider(endYmd);
  }

  return { targetEndYmd: maxEndYmd };
}

export function hasExtensionBeyondContractEnd(
  lineItemsToUpdate,
  contractEndDate,
  isOpportunity
) {
  const contractEndYmd = normalizeToYyyyMmDd(contractEndDate);
  if (!contractEndYmd) return false;
  const safeUpdates = Array.isArray(lineItemsToUpdate) ? lineItemsToUpdate : [];
  for (const item of safeUpdates) {
    if (!hasEndDateFieldInPayload(item, isOpportunity)) continue;
    const endYmd = normalizeToYyyyMmDd(
      getPayloadEndDateRaw(item, isOpportunity)
    );
    if (endYmd && endYmd > contractEndYmd) {
      return true;
    }
  }
  return false;
}

export function hasExtensionBeyondOrderEnd(
  lineItemsToUpdate,
  orderEndDate,
  isOpportunity
) {
  const orderEndYmd = normalizeToYyyyMmDd(orderEndDate);
  if (!orderEndYmd) return false;
  const safeUpdates = Array.isArray(lineItemsToUpdate) ? lineItemsToUpdate : [];
  for (const item of safeUpdates) {
    if (!hasEndDateFieldInPayload(item, isOpportunity)) continue;
    const endYmd = normalizeToYyyyMmDd(
      getPayloadEndDateRaw(item, isOpportunity)
    );
    if (endYmd && endYmd > orderEndYmd) {
      return true;
    }
  }
  return false;
}

/** Snapshot before moving-out clears `ShowEndedCross` for the status cell (used for future-end-before-max). */
export function snapshotShowEndedCrossForStatusIcons(row) {
  return !!row?.ShowEndedCross;
}

/** When true, ended / end-before-order-start cross is hidden (moving-out arrow is sufficient). */
export function shouldSuppressStatusEndedCrossForMovingOut(row) {
  return row?.ReplacementIcon === "moving-out";
}

function nonEmptyString(s) {
  return typeof s === "string" && s.trim() !== "";
}

/** Count glyphs actually rendered in the status icon column (drives dynamic column width). */
export function countVisibleStatusIcons(row) {
  if (!row) return 0;
  let n = 0;
  const statusVal = row.StatusIconValue;
  if (statusVal !== undefined && statusVal !== null && statusVal !== "") {
    n += 1;
  }
  if (row.ShowEndedCross) n += 1;
  if (nonEmptyString(row.StatusMonthlyMoneyIconUrl)) n += 1;
  if (nonEmptyString(row.StatusNewProductIconUrl)) n += 1;
  if (nonEmptyString(row.StatusFutureEndBeforeMaxUrl)) n += 1;
  if (nonEmptyString(row.StatusEntryAfterStartUrl)) n += 1;
  if (nonEmptyString(row.entryDateClockIcon)) n += 1;
  return n;
}

export function maxVisibleStatusIcons(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return 0;
  let max = 0;
  for (const row of rows) {
    const c = countVisibleStatusIcons(row);
    if (c > max) max = c;
  }
  return max;
}

/**
 * Datatable column width from visible icon count (per section).
 * Stride matches 1.75rem slots + 6px inter-slot gap + SLDS cell padding; extra buffer avoids clipping on 3+ icons.
 */
export function statusIconColumnWidthPx(iconCount) {
  if (!iconCount || iconCount <= 0) return 72;
  const cellPad = 20;
  const iconStride = 34;
  const gap = 6;
  const safety = 6;
  const width =
    cellPad +
    iconCount * iconStride +
    Math.max(0, iconCount - 1) * gap +
    safety;
  return Math.max(76, Math.ceil(width));
}

/** Hide Future End Before Max icon when the moving-out replacement arrow is shown. */
export function shouldSuppressFutureEndBeforeMaxForReplacement(
  replacementIcon
) {
  return replacementIcon === "moving-out";
}

/**
 * Whether the draft new-product plus SVG should render in the status column.
 * Hidden when the row shows a replacement arrow (moving-in = new line; moving-out = removed line).
 */
export function shouldShowStatusNewProductPlusIcon({
  isContractActiveContext,
  isEffectiveNew,
  replacementIcon
}) {
  const hasReplacementIcon =
    replacementIcon === "moving-in" || replacementIcon === "moving-out";
  return !isContractActiveContext && !!isEffectiveNew && !hasReplacementIcon;
}

/** User-facing copy when Signed is blocked for past Contract Start Date (non-admin). */
export const SIGNED_PAST_START_ADMIN_MESSAGE =
  "Contract start date is before today. Contact an administrator.";

/**
 * Package Builder Signed gate: block non-admins when order start is strictly before today.
 * @param {string|Date|null|undefined} orderStartYmd Order.Order_Start_Date__c (no other date fallbacks)
 * @param {string|Date|null|undefined} todayYmd Calendar today (YYYY-MM-DD)
 * @param {boolean} hasSignedPastStartAdminOverride Custom permission PackageBuilder_Signed_PastStart_AdminOverride
 * @returns {string|null} Block message, or null when this rule does not restrict
 */
export function pastStartSignedBlockMessage(
  orderStartYmd,
  todayYmd,
  hasSignedPastStartAdminOverride
) {
  if (hasSignedPastStartAdminOverride) {
    return null;
  }
  const start = normalizeToYyyyMmDd(orderStartYmd);
  const today = normalizeToYyyyMmDd(todayYmd);
  if (!start || !today) {
    return null;
  }
  if (start < today) {
    return SIGNED_PAST_START_ADMIN_MESSAGE;
  }
  return null;
}
