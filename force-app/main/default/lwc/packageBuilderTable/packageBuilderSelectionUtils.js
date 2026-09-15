export function ensureSelectionMap(input) {
  const base = input && typeof input === "object" ? input : {};
  return {
    standard: base.standard instanceof Set ? base.standard : new Set(base.standard || []),
    parking: base.parking instanceof Set ? base.parking : new Set(base.parking || []),
    contractTerms: base.contractTerms instanceof Set ? base.contractTerms : new Set(base.contractTerms || [])
  };
}

export function unionSelectionMap(selectionMap) {
  const m = ensureSelectionMap(selectionMap);
  const out = new Set();
  ["standard", "parking", "contractTerms"].forEach((k) => {
    m[k].forEach((id) => {
      if (id) out.add(id);
    });
  });
  return [...out];
}

/**
 * Merge per-section selections from a single datatable (Rooms, Extra, or Contract Terms).
 *
 * Section header "select all" in one table only affects that section's row ids.
 * Use `selectallroomsandextra` from `packageBuilderProductsPanel` to toggle select/deselect all
 * in Rooms + Extra together (Contract Terms section excluded from bulk select; deselect leaves it unchanged).
 */
export function mergeSectionSelections({ prevSelectionMap, section, selectedIds }) {
  const next = ensureSelectionMap(prevSelectionMap);
  const s = String(section || "standard").trim() || "standard";
  const selectedSet = selectedIds instanceof Set ? selectedIds : new Set(selectedIds || []);

  next[s] = selectedSet;
  return next;
}

/**
 * After merging a section's checkbox state: Contract Terms (`contractTerms`) vs Rooms/Extra (`standard`/`parking`)
 * are mutually exclusive when the active section has at least one selected row.
 */
export function mergeSectionSelectionsExclusiveContractTerms({ prevSelectionMap, section, selectedIds }) {
  const merged = mergeSectionSelections({ prevSelectionMap, section, selectedIds });
  const map = ensureSelectionMap(merged);
  const s = String(section || "standard").trim() || "standard";
  const sectionSet = map[s] || new Set();
  if (sectionSet.size === 0) {
    return map;
  }
  if (s === "contractTerms") {
    map.standard = new Set();
    map.parking = new Set();
  } else if (s === "standard" || s === "parking") {
    map.contractTerms = new Set();
  }
  return map;
}
