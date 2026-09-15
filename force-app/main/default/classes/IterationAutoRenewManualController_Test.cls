@isTest(IsParallel=false)
private class IterationAutoRenewManualController_Test {
  @isTest
  static void runOrgWide_withoutPermission_throws() {
    IterationAutoRenewManualController.testHasPermission = false;
    Boolean threw = false;
    try {
      Test.startTest();
      IterationAutoRenewManualController.runOrgWide();
      Test.stopTest();
    } catch (AuraHandledException e) {
      threw = true;
      String msg = String.isBlank(e.getMessage()) ? '' : e.getMessage();
      System.assert(
        msg.toLowerCase().contains('permission') ||
        msg.toLowerCase().contains('script-thrown'),
        'Expected permission error, got: ' + msg
      );
    } finally {
      IterationAutoRenewManualController.testHasPermission = null;
    }
    System.assertEquals(true, threw, 'Expected AuraHandledException');
  }

  @isTest
  static void runOrgWide_withPermission_returnsJobId() {
    IterationAutoRenewManualController.testHasPermission = true;
    Test.startTest();
    Id jobId = IterationAutoRenewManualController.runOrgWide();
    Test.stopTest();
    IterationAutoRenewManualController.testHasPermission = null;
    System.assertNotEquals(null, jobId, 'Expected batch job Id');
  }

  @isTest
  static void hasRunPermission_usesOverride() {
    IterationAutoRenewManualController.testHasPermission = true;
    System.assertEquals(
      true,
      IterationAutoRenewManualController.hasRunPermission()
    );
    IterationAutoRenewManualController.testHasPermission = false;
    System.assertEquals(
      false,
      IterationAutoRenewManualController.hasRunPermission()
    );
    IterationAutoRenewManualController.testHasPermission = null;
  }
}
