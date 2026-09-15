@isTest(IsParallel=false)
private class IterationAutoRenewSchedulable_Test {
  @isTest
  static void execute_enqueuesBatch() {
    Test.startTest();
    new IterationAutoRenewSchedulable().execute(null);
    IterationAutoRenewSchedulable.runNow();
    Test.stopTest();
    System.assertEquals(1, IterationAutoRenewSchedulable.DEFAULT_BATCH_SIZE);
  }
}
