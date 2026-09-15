public with sharing class IterationAutoRenewManualController {
  public static final String RUN_PERMISSION = 'Run_Iteration_Auto_Renew';

  @TestVisible
  private static Boolean testHasPermission;

  public static Boolean hasRunPermission() {
    if (testHasPermission != null) {
      return testHasPermission;
    }
    return FeatureManagement.checkPermission(RUN_PERMISSION);
  }

  /**
   * Starts the same org-wide Iteration Auto-Renew batch as the daily schedule.
   * @return Async Apex job Id for the batch
   */
  @AuraEnabled
  public static Id runOrgWide() {
    if (!hasRunPermission()) {
      throw new AuraHandledException(
        'You do not have permission to run the Iteration Auto-Renew job.'
      );
    }
    return IterationAutoRenewSchedulable.runNow();
  }
}
