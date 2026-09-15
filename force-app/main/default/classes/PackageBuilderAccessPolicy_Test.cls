@isTest
private class PackageBuilderAccessPolicy_Test {
  @isTest
  static void testCanEditEntryDateBranches() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    System.assertEquals(false, PackageBuilderAccessPolicy.canEditEntryDate(null));
    System.assertEquals(
      false,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today().addDays(-1))
    );
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today())
    );
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today().addDays(7))
    );
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = true;
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today().addDays(-100))
    );
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = null;
  }

  @isTest
  static void testCanShortenTerminatedEndDateBranches() {
    Date currentEnd = Date.today().addDays(30);
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = false;
    System.assertEquals(true, PackageBuilderAccessPolicy.canShortenTerminatedEndDate(null, currentEnd));
    System.assertEquals(true, PackageBuilderAccessPolicy.canShortenTerminatedEndDate(currentEnd, null));
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canShortenTerminatedEndDate(currentEnd, currentEnd.addDays(7))
    );
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canShortenTerminatedEndDate(currentEnd, currentEnd)
    );
    System.assertEquals(
      false,
      PackageBuilderAccessPolicy.canShortenTerminatedEndDate(currentEnd, currentEnd.addDays(-1))
    );
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = true;
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canShortenTerminatedEndDate(currentEnd, currentEnd.addDays(-10))
    );
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = null;
  }
}