public with sharing class IterationAutoRenewBatch implements Database.Batchable<SObject> {
  public Database.QueryLocator start(Database.BatchableContext bc) {
    Set<Id> contractIds = IterationAutoRenewService.findContractsWithDueActivatedIterations(
      Date.today()
    );
    return Database.getQueryLocator(
      [SELECT Id FROM Contract WHERE Id IN :contractIds]
    );
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    for (SObject row : scope) {
      Id contractId = row.Id;
      try {
        IterationAutoRenewService.processContract(contractId);
      } catch (Exception e) {
        IterationAutoRenewService.stamp(
          contractId,
          'Failed',
          e.getMessage(),
          null
        );
      }
    }
  }

  public void finish(Database.BatchableContext bc) {
  }
}
