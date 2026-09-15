@isTest(IsParallel=false)
private class IterationAutoRenewBatch_Test {
  @testSetup
  static void setup() {
    bypassHeavyAutomation();
    String areaValue;
    try {
      List<Schema.PicklistEntry> entries = Locations__c.Area__c.getDescribe()
        .getPicklistValues();
      if (!entries.isEmpty()) {
        areaValue = entries[0].getValue();
      }
    } catch (Exception e) {
      areaValue = null;
    }
    Locations__c loc = new Locations__c(
      Name = 'Batch Test Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Batch',
      Address__c = '1 Test St',
      Area__c = areaValue
    );
    insert loc;
    Id pb = Test.getStandardPricebookId();
    Product2 prod = new Product2(
      Name = 'Periodic Batch',
      IsActive = true,
      Location__c = loc.Id
    );
    insert prod;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pb,
      Product2Id = prod.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert pbe;
    Account acc = new Account(Name = 'Batch Acc');
    insert acc;
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today().addMonths(-6),
      EndDate = Date.today().addYears(5)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today().addMonths(-6),
      EndDate = Date.today().addYears(5),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert ord;
    insert new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today().addMonths(-6),
      EndDate = Date.today().addDays(30),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
  }

  private static void bypassHeavyAutomation() {
    TriggerHandler.clearAllBypasses();
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    TriggerHandler.bypass('OrderTriggerHandler');
    TriggerHandler.bypass('OpportunityTriggerHandler');
    TriggerHandler.bypass('RenewalPriceAdjustmentTriggerHandler');
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = false;
    TriggerStopper.stopOppLine = true;
    TriggerStopper.stopOpp = true;
    TriggerStopper.stopQuote = true;
    TriggerStopper.stopQuoteLine = true;
  }

  @isTest
  static void batch_startExecuteFinish_noDueContracts() {
    Test.startTest();
    IterationAutoRenewBatch batch = new IterationAutoRenewBatch();
    Database.QueryLocator ql = batch.start(null);
    batch.execute(null, new List<SObject>());
    batch.finish(null);
    Test.stopTest();
    System.assertNotEquals(null, ql);
  }

  @isTest
  static void execute_processesDueContract() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [SELECT Id FROM Order WHERE ContractId = :contr.Id LIMIT 1];
    ord.Status = 'Activated';
    update ord;
    OrderItem oi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    IterationService.savePlan(
      oi.Id,
      oi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.10,
          Status__c = 'Original'
        )
      }
    );

    Test.startTest();
    IterationAutoRenewBatch batch = new IterationAutoRenewBatch();
    batch.start(null);
    batch.execute(null, new List<SObject>{ new Contract(Id = contr.Id) });
    batch.finish(null);
    Test.stopTest();

    Contract updated = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertNotEquals(null, updated.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void batch_runsViaExecuteBatch() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [SELECT Id FROM Order WHERE ContractId = :contr.Id LIMIT 1];
    ord.Status = 'Activated';
    update ord;
    OrderItem oi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    IterationService.savePlan(
      oi.Id,
      oi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.10,
          Status__c = 'Original'
        )
      }
    );
    Test.startTest();
    Database.executeBatch(new IterationAutoRenewBatch(), 1);
    Test.stopTest();
    Contract updated = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertNotEquals(null, updated.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void execute_stampsFailedWhenProcessThrows() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [SELECT Id FROM Order WHERE ContractId = :contr.Id LIMIT 1];
    ord.Status = 'Activated';
    update ord;
    OrderItem oi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    IterationService.savePlan(
      oi.Id,
      oi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.10,
          Status__c = 'Original'
        )
      }
    );
    IterationAutoRenewService.failAfterClone = true;
    Test.startTest();
    new IterationAutoRenewBatch()
      .execute(null, new List<SObject>{ new Contract(Id = contr.Id) });
    Test.stopTest();
    IterationAutoRenewService.failAfterClone = false;
    Contract updated = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assert(
      updated.Last_Auto_Renew_Result__c != null &&
      updated.Last_Auto_Renew_Result__c.contains('Failed')
    );
  }
}
