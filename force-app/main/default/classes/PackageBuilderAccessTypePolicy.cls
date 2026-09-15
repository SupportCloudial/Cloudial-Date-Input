/**
 * Central access-type rules for Package Builder (Rent, Usage Based, Periodic, Monthly).
 */
public with sharing class PackageBuilderAccessTypePolicy {
  public static final String ACCESS_TYPE_MONTHLY = 'Monthly';
  public static final String ACCESS_TYPE_PERIODIC = 'Periodic';
  public static final String ACCESS_TYPE_RENT = 'Rent';
  public static final String ACCESS_TYPE_USAGE_BASED = 'Usage Based';

  public static final String PRODUCT_TYPE_STANDARD = 'Standard Products';
  public static final String PRODUCT_TYPE_EXTRA_ALL = 'Extra for all products';
  public static final String PRODUCT_TYPE_EXTRA_METER = 'Extra for meter Products';

  public static Boolean isMonthlyLike(String accessType) {
    return ACCESS_TYPE_MONTHLY.equalsIgnoreCase(normalize(accessType));
  }

  public static Boolean isRent(String accessType) {
    return ACCESS_TYPE_RENT.equalsIgnoreCase(normalize(accessType));
  }

  public static Boolean isUsageBased(String accessType) {
    return ACCESS_TYPE_USAGE_BASED.equalsIgnoreCase(normalize(accessType));
  }

  /** Periodic or Rent — end date required, monthly payment generation like Periodic. */
  public static Boolean isPeriodicLike(String accessType) {
    String at = normalize(accessType);
    return ACCESS_TYPE_PERIODIC.equalsIgnoreCase(at) ||
      ACCESS_TYPE_RENT.equalsIgnoreCase(at);
  }

  public static Boolean requiresEndDate(String accessType) {
    return isPeriodicLike(accessType);
  }

  public static Boolean allowsGrace(String accessType) {
    return !isUsageBased(accessType);
  }

  /**
   * Eligible access types for add/inline edit given product catalog metadata.
   * @param productType Product2.Type__c API value
   * @param productRentEligible Product2.Rent__c == true
   */
  public static List<String> eligibleAccessTypes(
    String productType,
    Boolean productRentEligible
  ) {
    List<String> types = new List<String>();
    if (PRODUCT_TYPE_STANDARD.equals(productType)) {
      types.add(ACCESS_TYPE_MONTHLY);
      types.add(ACCESS_TYPE_PERIODIC);
      if (productRentEligible == true) {
        types.add(ACCESS_TYPE_RENT);
      }
    } else if (PRODUCT_TYPE_EXTRA_ALL.equals(productType)) {
      types.add(ACCESS_TYPE_MONTHLY);
      types.add(ACCESS_TYPE_PERIODIC);
      types.add(ACCESS_TYPE_USAGE_BASED);
    } else if (PRODUCT_TYPE_EXTRA_METER.equals(productType)) {
      types.add(ACCESS_TYPE_MONTHLY);
      types.add(ACCESS_TYPE_PERIODIC);
      types.add(ACCESS_TYPE_USAGE_BASED);
    } else {
      types.add(ACCESS_TYPE_MONTHLY);
      types.add(ACCESS_TYPE_PERIODIC);
    }
    return types;
  }

  public static Boolean isAccessTypeEligibleForProduct(
    String accessType,
    String productType,
    Boolean productRentEligible
  ) {
    if (String.isBlank(accessType)) {
      return false;
    }
    for (
      String allowed : eligibleAccessTypes(productType, productRentEligible)
    ) {
      if (allowed.equalsIgnoreCase(normalize(accessType))) {
        return true;
      }
    }
    return false;
  }

  /**
   * Package Builder access-type flip for past-start split (Periodic &lt;-&gt; Monthly only).
   * Rent and Usage Based are not auto-flipped.
   */
  public static String flipPackageBuilderAccessType(String current) {
    if (ACCESS_TYPE_PERIODIC.equalsIgnoreCase(normalize(current))) {
      return ACCESS_TYPE_MONTHLY;
    }
    if (ACCESS_TYPE_MONTHLY.equalsIgnoreCase(normalize(current))) {
      return ACCESS_TYPE_PERIODIC;
    }
    return current;
  }

  public static Boolean isMonthlyPackageAccess(String accessType) {
    return isMonthlyLike(accessType);
  }

  /** Usage Based lines: qty 1, unit price 0; List Price stays from pricebook. */
  public static void applyUsageBasedLinePricing(OrderItem line) {
    if (line == null) {
      return;
    }
    line.Quantity = 1;
    line.UnitPrice = 0;
  }

  /** Usage Based lines: qty 1, unit price 0; List Price stays from pricebook. */
  public static void applyUsageBasedLinePricing(OpportunityLineItem line) {
    if (line == null) {
      return;
    }
    line.Quantity = 1;
    line.UnitPrice = 0;
  }

  /**
   * Usage Based lines must keep UnitPrice at 0. If UnitPrice is in the save payload,
   * force it to zero (access type after apply = payload Access_Type__c or existing).
   */
  public static void enforceUsageBasedUnitPriceOnSave(
    SObject line,
    String resolvedAccessType
  ) {
    if (line == null || !isUsageBased(resolvedAccessType)) {
      return;
    }
    Map<String, Object> fields = line.getPopulatedFieldsAsMap();
    if (!fields.containsKey('UnitPrice')) {
      return;
    }
    line.put('UnitPrice', 0);
  }

  public static void restoreCatalogUnitPrice(
    OrderItem line,
    Decimal pricebookEntryUnitPrice
  ) {
    if (line == null || pricebookEntryUnitPrice == null) {
      return;
    }
    line.UnitPrice = pricebookEntryUnitPrice;
  }

  public static void restoreCatalogUnitPrice(
    OpportunityLineItem line,
    Decimal pricebookEntryUnitPrice
  ) {
    if (line == null || pricebookEntryUnitPrice == null) {
      return;
    }
    line.UnitPrice = pricebookEntryUnitPrice;
  }

  public static void syncLinePricingForAccessTypeChange(
    OrderItem line,
    String previousAccessType,
    String newAccessType,
    Decimal pricebookEntryUnitPrice
  ) {
    if (line == null || String.isBlank(newAccessType)) {
      return;
    }
    if (isUsageBased(newAccessType)) {
      applyUsageBasedLinePricing(line);
    } else if (
      isUsageBased(previousAccessType) && pricebookEntryUnitPrice != null
    ) {
      restoreCatalogUnitPrice(line, pricebookEntryUnitPrice);
    }
  }

  public static void syncLinePricingForAccessTypeChange(
    OpportunityLineItem line,
    String previousAccessType,
    String newAccessType,
    Decimal pricebookEntryUnitPrice
  ) {
    if (line == null || String.isBlank(newAccessType)) {
      return;
    }
    if (isUsageBased(newAccessType)) {
      applyUsageBasedLinePricing(line);
    } else if (
      isUsageBased(previousAccessType) && pricebookEntryUnitPrice != null
    ) {
      restoreCatalogUnitPrice(line, pricebookEntryUnitPrice);
    }
  }

  private static String normalize(String accessType) {
    return String.isBlank(accessType) ? '' : accessType.trim();
  }
}
