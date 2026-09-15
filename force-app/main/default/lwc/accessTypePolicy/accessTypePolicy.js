/** Mirror of PackageBuilderAccessTypePolicy.cls for LWC. */

export const ACCESS_TYPE_MONTHLY = "Monthly";
export const ACCESS_TYPE_PERIODIC = "Periodic";
export const ACCESS_TYPE_RENT = "Rent";
export const ACCESS_TYPE_USAGE_BASED = "Usage Based";

export const PRODUCT_TYPE_STANDARD = "Standard Products";
export const PRODUCT_TYPE_EXTRA_ALL = "Extra for all products";
export const PRODUCT_TYPE_EXTRA_METER = "Extra for meter Products";

function normalize(accessType) {
  return String(accessType ?? "").trim();
}

export function isMonthlyLike(accessType) {
  return normalize(accessType).toLowerCase() === "monthly";
}

export function isRent(accessType) {
  return normalize(accessType).toLowerCase() === "rent";
}

export function isUsageBased(accessType) {
  return normalize(accessType).toLowerCase() === "usage based";
}

export function isPeriodicLike(accessType) {
  const at = normalize(accessType).toLowerCase();
  return at === "periodic" || at === "rent";
}

export function requiresEndDate(accessType) {
  return isPeriodicLike(accessType) || isUsageBased(accessType);
}

export function endDateRequiredMessage(accessType) {
  const at = normalize(accessType).toLowerCase();
  if (at === "usage based") {
    return "End date is required.";
  }
  if (at === "rent") {
    return "Rent products require an End Date. Add an end date, or change Access Type to Monthly for an open-ended product.";
  }
  return "Periodic products require an End Date. Add an end date, or change Access Type to Monthly for an open-ended product.";
}

/** Past-start access-type split: new line needs end date when target is not Monthly (matches Apex). */
export function pastStartNewLineRequiresEndDate(accessType) {
  return !isMonthlyLike(accessType);
}

export function eligibleAccessTypes(productType, productRentEligible) {
  if (productType === PRODUCT_TYPE_STANDARD) {
    const types = [ACCESS_TYPE_MONTHLY, ACCESS_TYPE_PERIODIC];
    if (productRentEligible === true) {
      types.push(ACCESS_TYPE_RENT);
    }
    return types;
  }
  if (productType === PRODUCT_TYPE_EXTRA_ALL) {
    return [ACCESS_TYPE_MONTHLY, ACCESS_TYPE_PERIODIC, ACCESS_TYPE_USAGE_BASED];
  }
  if (productType === PRODUCT_TYPE_EXTRA_METER) {
    return [ACCESS_TYPE_MONTHLY, ACCESS_TYPE_PERIODIC, ACCESS_TYPE_USAGE_BASED];
  }
  return [ACCESS_TYPE_MONTHLY, ACCESS_TYPE_PERIODIC];
}

export function isAccessTypeEligibleForProduct(
  accessType,
  productType,
  productRentEligible
) {
  const at = normalize(accessType);
  if (!at) {
    return false;
  }
  return eligibleAccessTypes(productType, productRentEligible).some(
    (allowed) => allowed.toLowerCase() === at.toLowerCase()
  );
}

export function accessTypeOptionsFromValues(values) {
  return (values || []).map((value) => ({ label: value, value }));
}

/** Eligible types for a row, optionally omitting the current access type (e.g. past-start picker). */
export function eligibleAccessTypesForRow(
  row,
  { excludeCurrent = false } = {}
) {
  const types = intersectionAccessTypesForRows([row]);
  if (!excludeCurrent) {
    return types;
  }
  const current = normalize(
    row?.AccessType || row?.Access_Type__c
  ).toLowerCase();
  if (!current) {
    return types;
  }
  return types.filter((t) => t.toLowerCase() !== current);
}

export function allSelectedProductsSupportAccessType(
  selectedProducts,
  accessType
) {
  const at = normalize(accessType);
  if (!at || !Array.isArray(selectedProducts) || !selectedProducts.length) {
    return false;
  }
  return selectedProducts.every((p) =>
    isAccessTypeEligibleForProduct(
      at,
      productTypeFromRow(p),
      rentEligibleFromRow(p)
    )
  );
}

export function productTypeFromRow(row) {
  return (
    row?.ProductsType ??
    row?.ProductTypeName ??
    row?.ProductType ??
    row?.productsType ??
    ""
  );
}

export function rentEligibleFromRow(row) {
  return row?.RentEligible === true || row?.rentEligible === true;
}

export function isRentEligibleStandardRow(row) {
  return (
    productTypeFromRow(row) === PRODUCT_TYPE_STANDARD &&
    rentEligibleFromRow(row)
  );
}

/** Past-start access-type split: picker for Extra and rent-eligible standard; flip-only for other Rooms. */
export function pastStartAccessTypePickerConfig(row) {
  const currentAccessType = normalize(row?.AccessType || row?.Access_Type__c);
  const selectableTypes = eligibleAccessTypesForRow(row, {
    excludeCurrent: true
  });
  const productType = productTypeFromRow(row);
  const usePicker =
    productType === PRODUCT_TYPE_EXTRA_METER ||
    productType === PRODUCT_TYPE_EXTRA_ALL ||
    isRentEligibleStandardRow(row);
  const showPicker = usePicker && selectableTypes.length > 0;
  return {
    showPicker,
    accessTypePickerOptions: showPicker
      ? accessTypeOptionsFromValues(selectableTypes)
      : [],
    defaultPickerAccessType: selectableTypes[0] || "",
    currentAccessType,
    flippedAccessType: flipPackageBuilderAccessType(currentAccessType)
  };
}

/** Periodic <-> Monthly only; Rent and Usage Based pass through (matches Apex policy). */
export function flipPackageBuilderAccessType(current) {
  const v = normalize(current);
  if (v.toLowerCase() === "periodic") {
    return ACCESS_TYPE_MONTHLY;
  }
  if (v.toLowerCase() === "monthly") {
    return ACCESS_TYPE_PERIODIC;
  }
  return v || current;
}

export function intersectionAccessTypesForRows(rows) {
  const list = Array.isArray(rows) ? rows.filter(Boolean) : [];
  if (!list.length) {
    return [];
  }
  let intersection = null;
  for (const row of list) {
    const types = eligibleAccessTypes(
      productTypeFromRow(row),
      rentEligibleFromRow(row)
    );
    if (intersection === null) {
      intersection = new Set(types);
    } else {
      const prior = intersection;
      intersection = new Set(types.filter((t) => prior.has(t)));
    }
  }
  return intersection ? [...intersection] : [];
}

/**
 * Label -> value map for the access-type combobox cell (ERS datatable convention).
 */
export function accessTypePicklistMapForRow(row, noneLabel) {
  const productType = productTypeFromRow(row);
  const rentEligible = rentEligibleFromRow(row);
  const allowed = eligibleAccessTypes(productType, rentEligible);
  const current = normalize(row?.AccessType || row?.Access_Type__c);
  const out = {};
  if (noneLabel != null && noneLabel !== false) {
    out[noneLabel] = "";
  }
  allowed.forEach((value) => {
    out[value] = value;
  });
  if (
    current &&
    !allowed.some((v) => v.toLowerCase() === current.toLowerCase())
  ) {
    out[current] = current;
  }
  return out;
}
