@isTest(IsParallel=false)
private class IterationController_Test {
  @testSetup
  static void setup() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    TriggerHandler.bypass('OrderTriggerHandler');
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Account acc = new Account(Name = 'Iter Ctrl Test');
    insert acc;
    Product2 prod = new Product2(Name = 'Periodic Room', IsActive = true);
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
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Periodic',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(12)
    );
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 500,
      Access_Type__c = 'Monthly',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(12)
    );
  }

  @isTest
  static void loadIterations_opportunity_skipsNonPeriodic() {
    List<OpportunityLineItem> olis = [
      SELECT Id
      FROM OpportunityLineItem
    ];
    Test.startTest();
    IterationController.LoadResult res = IterationController.loadIterations(
      new List<Id>{ olis[0].Id, olis[1].Id },
      'Opportunity',
      false
    );
    Test.stopTest();
    System.assertEquals(1, res.rows.size());
    System.assert(res.excludedMessage != null);
  }

  @isTest
  static void loadIterations_emptySelectionThrows() {
    Boolean threw = false;
    try {
      IterationController.loadIterations(new List<Id>(), 'Opportunity', false);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @isTest
  static void loadIterations_archivedBlocked() {
    OpportunityLineItem oli = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    Test.startTest();
    IterationController.LoadResult res = IterationController.loadIterations(
      new List<Id>{ oli.Id },
      'Order',
      true
    );
    Test.stopTest();
    System.assertEquals(true, res.archivedBlocked);
    System.assertEquals(0, res.rows.size());
  }

  @isTest
  static void saveApproveRevertAndHistory() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Original',
          Proposed_Increase_Type__c = 'Increase_by_Percentage',
          Proposed_Increase_Percent__c = 8
        )
      }
    );
    Iteration__c it = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];

    Test.startTest();
    IterationService.ApproveResult approved = IterationController.approveIteration(
      new List<Id>{ it.Id }
    );
    IterationController.revertWorkingToOriginal(it.Id);
    List<IterationController.HistoryRow> history = IterationController.getFieldHistory(
      it.Id
    );
    Test.stopTest();

    System.assertEquals(1, approved.approvedCount);
    System.assertNotEquals(null, history);
  }

  @isTest
  static void discardProposed_clearsDraft() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Original',
          Proposed_Increase_Percent__c = 8
        )
      }
    );
    Iteration__c it = [
      SELECT Id, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Test.startTest();
    IterationController.discardProposed(new List<Id>{ it.Id });
    Test.stopTest();
    it = [
      SELECT Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :it.Id
    ];
    System.assertEquals(null, it.Proposed_Increase_Percent__c);
  }

  @isTest
  static void getFieldHistory_requiresSelection() {
    Boolean threw = false;
    try {
      IterationController.getFieldHistory(null);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @isTest
  static void bulkApply_updatesMatchingRows() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 6,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Original'
        )
      }
    );
    Iteration__c it = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Iteration__c template = new Iteration__c(
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 45
    );
    Map<Id, List<Id>> idsByLine = new Map<Id, List<Id>>{
      oli.Id => new List<Id>{ it.Id }
    };

    Test.startTest();
    IterationService.BulkApplyResult bulkResult = IterationController.bulkApply(
      new List<Id>{ oli.Id },
      new Map<Id, Date>{ oli.Id => oli.End_date__c },
      template,
      idsByLine
    );
    Test.stopTest();

    System.assert(bulkResult.updatedRows >= 1);
    it = [SELECT Duration_Months__c FROM Iteration__c WHERE Id = :it.Id];
    System.assertEquals(12, it.Duration_Months__c);
  }

  @isTest
  static void loadIterations_order_loadsPeriodicLine() {
    Id pb = Test.getStandardPricebookId();
    Account acc = [SELECT Id FROM Account LIMIT 1];
    String areaValue = null;
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
      Name = 'Ctrl Order Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Site',
      Address__c = '1 St',
      Area__c = areaValue
    );
    insert loc;
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id
    );
    insert ord;
    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(12),
      Access_Type__c = 'Periodic'
    );
    insert oi;
    Test.startTest();
    IterationController.LoadResult res = IterationController.loadIterations(
      new List<Id>{ oi.Id },
      'Order',
      false
    );
    Test.stopTest();
    System.assertEquals(1, res.rows.size());
    System.assertEquals(oi.Id, res.rows[0].lineId);
  }

  @isTest
  static void formatPercentHistoryValue_displaysUserFriendlyPercent() {
    System.assertEquals(
      '82%',
      IterationController.formatPercentHistoryValue(0.82)
    );
    System.assertEquals(
      '42%',
      IterationController.formatPercentHistoryValue(0.42)
    );
    System.assertEquals('5%', IterationController.formatPercentHistoryValue(5));
    System.assertEquals(
      '5%',
      IterationController.formatPercentHistoryValue('0.05')
    );
    System.assertEquals(
      null,
      IterationController.formatPercentHistoryValue(null)
    );
  }

  @isTest
  static void getFieldHistory_formatsRowsAfterUpdate() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Original'
        )
      }
    );
    Iteration__c it = [
      SELECT Id, Increase_Type__c, Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    it.Increase_Type__c = 'Increase_by_Value';
    it.Increase_Amount__c = 25;
    it.Increase_Percent__c = null;
    update it;
    Test.startTest();
    List<IterationController.HistoryRow> history = IterationController.getFieldHistory(
      it.Id
    );
    Test.stopTest();
    System.assertNotEquals(null, history);
  }

  @isTest
  static void saveIterations_delegatesToService() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    Test.startTest();
    IterationService.SaveResult saved = IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 6,
          Advance_Notice_Days__c = 15,
          Status__c = 'Original'
        )
      }
    );
    Test.stopTest();
    System.assertNotEquals(null, saved.iterations);
  }

  @isTest
  static void historyEvents_rejectAndSaveProposed() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    IterationController.saveIterations(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Original'
        )
      }
    );
    Iteration__c it = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];

    Test.startTest();
    IterationController.saveProposed(
      new List<Id>{ it.Id },
      new Iteration__c(
        Proposed_Increase_Type__c = 'Increase_by_Percentage',
        Proposed_Increase_Percent__c = 0.12
      )
    );
    List<IterationHistoryService.HistoryEventRow> events = IterationController.getHistoryEvents(
      it.Id
    );
    IterationController.rejectProposed(new List<Id>{ it.Id });
    Test.stopTest();

    System.assert(!events.isEmpty(), 'Expected history events');
    it = [
      SELECT Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :it.Id
    ];
    System.assertEquals(null, it.Proposed_Increase_Percent__c);
  }
}
