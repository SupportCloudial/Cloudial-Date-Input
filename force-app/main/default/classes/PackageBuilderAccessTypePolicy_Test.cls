@isTest
private class PackageBuilderAccessTypePolicy_Test {
  @isTest
  static void testPeriodicLikeAndMonthlyLike() {
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isPeriodicLike('Periodic')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isPeriodicLike('Rent')
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.isPeriodicLike('Monthly')
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.isPeriodicLike('Usage Based')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isMonthlyLike('Monthly')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isUsageBased('Usage Based')
    );
  }

  @isTest
  static void testEligibleAccessTypesRooms() {
    List<String> noRent = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      PackageBuilderAccessTypePolicy.PRODUCT_TYPE_STANDARD,
      false
    );
    System.assertEquals(2, noRent.size());
    System.assert(!noRent.contains('Rent'));

    List<String> withRent = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      PackageBuilderAccessTypePolicy.PRODUCT_TYPE_STANDARD,
      true
    );
    System.assertEquals(3, withRent.size());
    System.assert(withRent.contains('Rent'));
  }

  @isTest
  static void testEligibleAccessTypesExtra() {
    List<String> extra = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      PackageBuilderAccessTypePolicy.PRODUCT_TYPE_EXTRA_ALL,
      false
    );
    System.assertEquals(3, extra.size());
    System.assert(extra.contains('Usage Based'));

    List<String> extraMeter = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      PackageBuilderAccessTypePolicy.PRODUCT_TYPE_EXTRA_METER,
      false
    );
    System.assertEquals(3, extraMeter.size());
    System.assert(extraMeter.contains('Usage Based'));
  }

  @isTest
  static void testFlipPackageBuilderAccessType() {
    System.assertEquals(
      'Monthly',
      PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType('Periodic')
    );
    System.assertEquals(
      'Periodic',
      PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType('Monthly')
    );
    System.assertEquals(
      'Rent',
      PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType('Rent')
    );
    System.assertEquals(
      'Usage Based',
      PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType('Usage Based')
    );
  }

  @isTest
  static void testIsAccessTypeEligibleForProduct() {
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
        'Rent',
        PackageBuilderAccessTypePolicy.PRODUCT_TYPE_STANDARD,
        true
      )
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
        'Rent',
        PackageBuilderAccessTypePolicy.PRODUCT_TYPE_STANDARD,
        false
      )
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
        'Usage Based',
        PackageBuilderAccessTypePolicy.PRODUCT_TYPE_EXTRA_METER,
        false
      )
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
        'Usage Based',
        PackageBuilderAccessTypePolicy.PRODUCT_TYPE_EXTRA_ALL,
        false
      )
    );
  }

  @isTest
  static void testUsageBasedLinePricingHelpers() {
    PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing((OrderItem) null);
    PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(
      (OpportunityLineItem) null
    );
    PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(
      (OrderItem) null,
      12
    );
    PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(
      (OpportunityLineItem) null,
      12
    );
    PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(
      new OrderItem(),
      null
    );

    OrderItem oi = new OrderItem(Quantity = 5, UnitPrice = 12);
    PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(oi);
    System.assertEquals(1, oi.Quantity);
    System.assertEquals(0, oi.UnitPrice);

    OpportunityLineItem oli = new OpportunityLineItem(
      Quantity = 3,
      UnitPrice = 99
    );
    PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(oli);
    System.assertEquals(1, oli.Quantity);
    System.assertEquals(0, oli.UnitPrice);

    PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(oi, 12);
    System.assertEquals(12, oi.UnitPrice);
    PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(oli, 45);
    System.assertEquals(45, oli.UnitPrice);

    PackageBuilderAccessTypePolicy.syncLinePricingForAccessTypeChange(
      oi,
      'Monthly',
      'Usage Based',
      12
    );
    System.assertEquals(0, oi.UnitPrice);

    OpportunityLineItem usageOli = new OpportunityLineItem(UnitPrice = 5);
    PackageBuilderAccessTypePolicy.enforceUsageBasedUnitPriceOnSave(
      usageOli,
      'Usage Based'
    );
    System.assertEquals(0, usageOli.UnitPrice);

    OpportunityLineItem periodicOli = new OpportunityLineItem(UnitPrice = 5);
    PackageBuilderAccessTypePolicy.enforceUsageBasedUnitPriceOnSave(
      periodicOli,
      'Periodic'
    );
    System.assertEquals(5, periodicOli.UnitPrice);
    System.assertEquals(1, oi.Quantity);

    PackageBuilderAccessTypePolicy.syncLinePricingForAccessTypeChange(
      oi,
      'Usage Based',
      'Monthly',
      12
    );
    System.assertEquals(12, oi.UnitPrice);

    PackageBuilderAccessTypePolicy.syncLinePricingForAccessTypeChange(
      oli,
      'Monthly',
      'Usage Based',
      45
    );
    System.assertEquals(0, oli.UnitPrice);

    PackageBuilderAccessTypePolicy.syncLinePricingForAccessTypeChange(
      oi,
      'Monthly',
      '',
      12
    );
    System.assertEquals(12, oi.UnitPrice);
  }

  @isTest
  static void testAccessTypeGuardsAndEligibility() {
    System.assertEquals(true, PackageBuilderAccessTypePolicy.isRent('Rent'));
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.isRent('Monthly')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.requiresEndDate('Rent')
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.requiresEndDate('Usage Based')
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.allowsGrace('Usage Based')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.allowsGrace('Monthly')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isMonthlyPackageAccess('Monthly')
    );
    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
        'Rent',
        'Other',
        false
      )
    );
    List<String> other = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      'Other',
      false
    );
    System.assertEquals(2, other.size());
  }
}
