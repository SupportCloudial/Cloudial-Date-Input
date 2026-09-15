@isTest(IsParallel=false)
public class IterationHistoryService_Test {
  @isTest
  static void recordChangedAndQueryEvents() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Account acc = new Account(Name = 'Hist Test');
    insert acc;
    Product2 prod = new Product2(Name = 'Periodic', IsActive = true);
    insert prod;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pb,
      Product2Id = prod.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert pbe;
    Opportunity opp = new Opportunity(
      Name = 'Opp',
      AccountId = acc.Id,
      StageName = 'New',
      CloseDate = Date.today().addMonths(1),
      Pricebook2Id = pb
    );
    insert opp;
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Periodic',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(12)
    );
    insert oli;

    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original'
        )
      }
    );
    Iteration__c row = [
      SELECT
        Id,
        Sequence__c,
        Status__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Iteration__c prior = row.clone(true, true, true, true);
    row.Proposed_Increase_Type__c = 'Increase_by_Percentage';
    row.Proposed_Increase_Percent__c = 0.1;
    update row;

    Test.startTest();
    IterationHistoryService.recordChanged(prior, row, 'Test changed');
    List<IterationHistoryService.HistoryEventRow> events = IterationHistoryService.getEventsForIteration(
      row.Id
    );
    Test.stopTest();

    System.assert(!events.isEmpty(), 'Expected history events');
    System.assertEquals(
      IterationHistoryService.EVENT_CHANGED,
      events[0].eventType
    );
  }

  @isTest
  static void recordAllEventTypes() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Account acc = new Account(Name = 'Hist All');
    insert acc;
    Product2 prod = new Product2(Name = 'Periodic', IsActive = true);
    insert prod;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pb,
      Product2Id = prod.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert pbe;
    Opportunity opp = new Opportunity(
      Name = 'Opp',
      AccountId = acc.Id,
      StageName = 'New',
      CloseDate = Date.today().addMonths(1),
      Pricebook2Id = pb
    );
    insert opp;
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Periodic',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(12)
    );
    insert oli;

    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original',
          Proposed_Increase_Type__c = 'Increase_by_Percentage',
          Proposed_Increase_Percent__c = 0.08
        )
      }
    );
    Iteration__c row = [
      SELECT
        Id,
        Sequence__c,
        Status__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c,
        Original_Increase_Type__c,
        Original_Increase_Percent__c,
        Original_Increase_Amount__c,
        Original_Final_Price__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];

    Test.startTest();
    IterationHistoryService.recordApproved(row);
    IterationHistoryService.recordRejected(row, row);
    IterationHistoryService.recordReverted(row, row);
    IterationHistoryService.recordStatusChanged(row, row, 'Status');
    IterationHistoryService.recordBulkApplied(row, 'Bulk');
    List<IterationHistoryService.HistoryEventRow> events = IterationHistoryService.getEventsForIteration(
      row.Id
    );
    Test.stopTest();

    System.assert(events.size() >= 5, 'Expected multiple event types');
  }

  @isTest
  static void workingDisplayOmitsValueSuffixWhenAmountMissing() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Account acc = new Account(Name = 'Hist Dash');
    insert acc;
    Product2 prod = new Product2(Name = 'Periodic', IsActive = true);
    insert prod;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pb,
      Product2Id = prod.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert pbe;
    Opportunity opp = new Opportunity(
      Name = 'Opp',
      AccountId = acc.Id,
      StageName = 'New',
      CloseDate = Date.today().addMonths(1),
      Pricebook2Id = pb
    );
    insert opp;
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Periodic',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(12)
    );
    insert oli;

    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Value',
          Increase_Amount__c = 25,
          Status__c = 'Original'
        )
      }
    );
    Iteration__c row = [
      SELECT
        Id,
        Sequence__c,
        Status__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Iteration__c prior = row.clone(true, true, true, true);
    Iteration__c after = row.clone(true, true, true, true);
    after.Increase_Amount__c = null;

    Test.startTest();
    IterationHistoryService.recordChanged(prior, after, 'Type without amount');
    List<IterationHistoryService.HistoryEventRow> events = IterationHistoryService.getEventsForIteration(
      row.Id
    );
    Test.stopTest();

    System.assert(!events.isEmpty(), 'Expected history events');
    IterationHistoryService.HistoryEventRow changed;
    for (IterationHistoryService.HistoryEventRow evt : events) {
      if (
        evt.eventType == IterationHistoryService.EVENT_CHANGED &&
        evt.summary == 'Type without amount'
      ) {
        changed = evt;
        break;
      }
    }
    System.assertNotEquals(null, changed, 'Expected a Changed event');
    System.assertEquals(
      'Increase by Value',
      changed.workingDisplay,
      'Missing amount should not render a dash suffix'
    );
  }
}
