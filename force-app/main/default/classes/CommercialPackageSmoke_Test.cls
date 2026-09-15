/**
 * Lightweight smoke tests for Cloudial commercial-package spine (no Location/desk setup).
 */
@IsTest
private class CommercialPackageSmoke_Test {
  @IsTest
  static void accessTypePolicy_periodicAndMonthly() {
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isPeriodicLike('Periodic')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isMonthlyLike('Monthly')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.isUsageBased('Usage Based')
    );
    List<String> types = PackageBuilderAccessTypePolicy.eligibleAccessTypes(
      PackageBuilderAccessTypePolicy.PRODUCT_TYPE_STANDARD,
      true
    );
    System.assert(types.contains('Monthly'));
    System.assert(types.contains('Periodic'));
    System.assert(types.contains('Rent'));
  }

  @IsTest
  static void accessPolicy_entryDateWithoutOverride() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    System.assertEquals(
      false,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today().addDays(-1))
    );
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today())
    );
  }

  @IsTest
  static void otherSiteProduct_nullSafe() {
    System.assertEquals(
      false,
      PackageBuilderService.isOtherSiteProduct(null, null)
    );
  }

  @IsTest
  static void modifyContractDto_locationNameNull() {
    ModifyContractActionController.ActiveContractOption opt = new ModifyContractActionController.ActiveContractOption();
    opt.locationName = null;
    System.assertEquals(null, opt.locationName);
  }
}
