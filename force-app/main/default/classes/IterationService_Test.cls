@isTest(IsParallel=false)
public class IterationService_Test {
  @testSetup
  static void setup() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    TriggerHandler.bypass('OrderTriggerHandler');
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Account acc = new Account(Name = 'Iter Test');
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
  }

  @isTest
  static void savePlan_setsRemainingAndNoticeWarning() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    List<Iteration__c> rows = new List<Iteration__c>{
      new Iteration__c(
        Duration_Months__c = 12,
        Advance_Notice_Days__c = 365,
        Increase_Type__c = 'Increase_by_Percentage',
        Increase_Percent__c = 10,
        Status__c = 'Original'
      )
    };
    Test.startTest();
    IterationService.SaveResult res = IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      rows
    );
    Test.stopTest();
    System.assertEquals(1, res.remaining);
    oli = [
      SELECT Remaining_Iterations__c
      FROM OpportunityLineItem
      WHERE Id = :oli.Id
    ];
    System.assertEquals(1, oli.Remaining_Iterations__c);
  }

  @isTest
  static void approve_thisOnly_keepsOriginal() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Iteration__c it = new Iteration__c(
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30,
      Increase_Type__c = 'Increase_by_Percentage',
      Increase_Percent__c = 5,
      Status__c = 'Original',
      Proposed_Increase_Type__c = 'Increase_by_Percentage',
      Proposed_Increase_Percent__c = 8
    );
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ it }
    );
    it = [SELECT Id FROM Iteration__c LIMIT 1];
    Test.startTest();
    IterationService.approve(it.Id, false);
    Test.stopTest();
    it = [
      SELECT
        Status__c,
        Original_Increase_Percent__c,
        Original_Increase_Type__c,
        Increase_Percent__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Type__c
      FROM Iteration__c
      WHERE Id = :it.Id
    ];
    System.assertEquals('Approved', it.Status__c);
    System.assertEquals('Increase_by_Percentage', it.Original_Increase_Type__c);
    System.assertEquals(5, it.Original_Increase_Percent__c);
    System.assertEquals(8, it.Increase_Percent__c);
    System.assertEquals(null, it.Proposed_Increase_Percent__c);
    System.assertEquals(null, it.Proposed_Increase_Type__c);
  }

  @isTest
  static void discardProposed_clearsPending() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
          Proposed_Increase_Percent__c = 0.08
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
    IterationService.discardProposed(it.Id);
    Test.stopTest();
    it = [
      SELECT Proposed_Increase_Percent__c, Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :it.Id
    ];
    System.assertEquals(null, it.Proposed_Increase_Percent__c);
    System.assertEquals(0.05, it.Increase_Percent__c);
  }

  @isTest
  static void revertWorkingToOriginal_restoresBaseline() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
    Iteration__c it = [
      SELECT
        Id,
        Increase_Type__c,
        Increase_Percent__c,
        Status__c,
        Original_Increase_Type__c,
        Original_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    it.Increase_Percent__c = 0.20;
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ it }
    );
    Test.startTest();
    IterationService.revertWorkingToOriginal(it.Id);
    Test.stopTest();
    it = [
      SELECT Increase_Percent__c, Original_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :it.Id
    ];
    System.assertEquals(0.05, it.Increase_Percent__c);
    System.assertEquals(0.05, it.Original_Increase_Percent__c);
  }

  @isTest
  static void approve_allFutureIgnored_approvesThisOnly() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.06,
          Status__c = 'Original'
        )
      }
    );
    List<Iteration__c> rows = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    Test.startTest();
    IterationService.ApproveResult result = IterationService.approve(
      rows[0].Id,
      true
    );
    Test.stopTest();
    System.assertEquals(1, result.approvedCount);
    System.assertEquals(0, result.skippedNoProposed);
    System.assertEquals('Approved 1 iteration.', result.message);
    List<Iteration__c> afterApprove = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    System.assertEquals('Approved', afterApprove[0].Status__c);
    System.assertEquals(0.08, afterApprove[0].Increase_Percent__c);
    System.assertEquals(null, afterApprove[0].Proposed_Increase_Percent__c);
    System.assertEquals('Original', afterApprove[1].Status__c);
    System.assertEquals(0.06, afterApprove[1].Increase_Percent__c);
  }

  @isTest
  static void applyIncrease_formulas() {
    Iteration__c row = new Iteration__c(
      Increase_Type__c = 'Increase_by_Percentage',
      Increase_Percent__c = 10,
      Status__c = 'Original'
    );
    System.assertEquals(110, IterationAutoRenewService.applyIncrease(row, 100));
    row.Original_Increase_Percent__c = 0.05;
    row.Increase_Percent__c = 0.10;
    System.assertEquals(
      110,
      IterationAutoRenewService.applyIncrease(row, 100),
      'Renew always uses Working, even when Original differs'
    );
    row = new Iteration__c(
      Increase_Type__c = 'Increase_by_Value',
      Increase_Amount__c = 20,
      Status__c = 'Original'
    );
    System.assertEquals(120, IterationAutoRenewService.applyIncrease(row, 100));
    row = new Iteration__c(
      Increase_Type__c = 'Final_Price',
      Final_Price__c = 130,
      Status__c = 'Original'
    );
    System.assertEquals(130, IterationAutoRenewService.applyIncrease(row, 100));
    row = new Iteration__c(
      Increase_Type__c = null,
      Increase_Percent__c = 0.50,
      Status__c = 'Original'
    );
    System.assertEquals(
      100,
      IterationAutoRenewService.applyIncrease(row, 100),
      'Blank Increase_Type means no increase on renew'
    );
  }

  @isTest
  static void copyFromOpportunityProducts_copiesIterations() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter Copy Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
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
      Opportunity_Product__c = oli.Id,
      Access_Type__c = 'Periodic'
    );
    insert oi;
    Test.startTest();
    IterationService.copyFromOpportunityProducts(new List<OrderItem>{ oi });
    Test.stopTest();
    List<Iteration__c> copied = [
      SELECT Id
      FROM Iteration__c
      WHERE Order_Product__c = :oi.Id
    ];
    System.assertEquals(1, copied.size());
  }

  @isTest
  static void copyFromOriginalOrderProducts_copiesIterations() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter Orig Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
    Order activeOrd = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      EndDate = Date.today().addYears(1)
    );
    insert activeOrd;
    OrderItem activeOi = new OrderItem(
      OrderId = activeOrd.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addYears(1)
    );
    insert activeOi;
    IterationService.savePlan(
      activeOi.Id,
      activeOi.EndDate,
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
    Order draftOrd = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      EndDate = Date.today().addYears(1),
      Previous_Order__c = activeOrd.Id
    );
    insert draftOrd;
    OrderItem draftOi = new OrderItem(
      OrderId = draftOrd.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addYears(1),
      Original_Order_Product__c = activeOi.Id,
      Change_Type__c = 'No Change'
    );
    insert draftOi;
    Test.startTest();
    IterationService.copyFromOriginalOrderProducts(
      new List<OrderItem>{ draftOi }
    );
    Test.stopTest();
    List<Iteration__c> copied = [
      SELECT Id, Increase_Percent__c, Status__c
      FROM Iteration__c
      WHERE Order_Product__c = :draftOi.Id
    ];
    System.assertEquals(1, copied.size());
    System.assertEquals(0.10, copied[0].Increase_Percent__c);
    System.assertEquals('Original', copied[0].Status__c);
    OrderItem stamped = [
      SELECT Remaining_Iterations__c
      FROM OrderItem
      WHERE Id = :draftOi.Id
    ];
    System.assertEquals(1, stamped.Remaining_Iterations__c);
  }

  @isTest
  static void nextDueIteration_picksEarliestDue() {
    List<Iteration__c> rows = new List<Iteration__c>{
      new Iteration__c(
        Sequence__c = 2,
        Status__c = 'Original',
        Notice_Date__c = Date.today().addDays(5)
      ),
      new Iteration__c(
        Sequence__c = 1,
        Status__c = 'Original',
        Notice_Date__c = Date.today().addDays(-1)
      )
    };
    Iteration__c due = IterationService.nextDueIteration(rows, Date.today());
    System.assertEquals(1, due.Sequence__c);
  }

  @isTest
  static void helpers_and_earlyReturns() {
    System.assertEquals(true, IterationService.isPeriodic('Periodic'));
    System.assertEquals(false, IterationService.isPeriodic('Fixed'));
    System.assertEquals(
      true,
      IterationService.usesApprovedIncrease(
        new Iteration__c(Status__c = 'Approved')
      )
    );
    System.assertEquals(false, IterationService.usesApprovedIncrease(null));
    System.assertEquals(false, IterationService.hasProposedIncrease(null));
    System.assertEquals(
      true,
      IterationService.hasProposedIncrease(
        new Iteration__c(Proposed_Increase_Percent__c = 0.08)
      )
    );
    System.assertEquals(
      true,
      IterationService.hasProposedIncrease(
        new Iteration__c(Proposed_Increase_Type__c = 'Increase_by_Percentage')
      )
    );
    System.assertEquals(0, IterationService.queryByParent(null).size());
    System.assertEquals(0, IterationService.countRemaining(null));
    IterationService.copyFromOriginalOrderProducts(null);
    IterationService.copyFromOriginalOrderProducts(new List<OrderItem>());
    IterationService.copyFromOpportunityProducts(null);
    IterationService.copyFromReplacedOrderProducts(null);
    IterationService.copyFromReplacedOrderProducts(new List<OrderItem>());
    IterationService.restoreFromReplacedOrderProducts(null);
    IterationService.restoreFromReplacedOrderProducts(new List<OrderItem>());
    IterationService.bulkApplyTemplate(null, null, null);
  }

  @isTest
  static void copyFromOpportunityProducts_skipsWhenOriginalOrderProductSet() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter Skip Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id
    );
    insert ord;
    OrderItem sourceOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic'
    );
    insert sourceOi;
    OrderItem draftOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Opportunity_Product__c = oli.Id,
      Original_Order_Product__c = sourceOi.Id,
      Access_Type__c = 'Periodic'
    );
    insert draftOi;
    Test.startTest();
    IterationService.copyFromOpportunityProducts(
      new List<OrderItem>{ draftOi }
    );
    Test.stopTest();
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Iteration__c WHERE Order_Product__c = :draftOi.Id]
    );
  }

  @isTest
  static void bulkApplyTemplate_updatesNonCompleted() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
    Iteration__c it = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Iteration__c template = new Iteration__c(
      Duration_Months__c = 6,
      Advance_Notice_Days__c = 15,
      Increase_Type__c = 'Increase_by_Percentage',
      Increase_Percent__c = 0.12,
      Status__c = 'Original'
    );
    Test.startTest();
    IterationService.bulkApplyTemplate(
      new List<Id>{ oli.Id },
      new Map<Id, Date>{ oli.Id => oli.End_date__c },
      template,
      new Map<Id, List<Id>>{ oli.Id => new List<Id>{ it.Id } }
    );
    Test.stopTest();
    Iteration__c updated = [
      SELECT Duration_Months__c, Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    System.assertEquals(6, updated.Duration_Months__c);
    System.assertEquals(0.12, updated.Increase_Percent__c);
  }

  @isTest
  static void approve_thisOnly_leavesSiblingProposed() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.06,
          Status__c = 'Original',
          Proposed_Increase_Type__c = 'Increase_by_Percentage',
          Proposed_Increase_Percent__c = 0.09
        )
      }
    );
    List<Iteration__c> rows = [
      SELECT Id, Sequence__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    Test.startTest();
    IterationService.ApproveResult result = IterationService.approve(
      rows[0].Id,
      true
    );
    Test.stopTest();
    System.assertEquals(1, result.approvedCount);
    List<Iteration__c> afterApprove = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    System.assertEquals('Approved', afterApprove[0].Status__c);
    System.assertEquals('Original', afterApprove[1].Status__c);
    System.assertEquals(0.08, afterApprove[0].Increase_Percent__c);
    System.assertEquals(0.06, afterApprove[1].Increase_Percent__c);
    System.assertEquals(null, afterApprove[0].Proposed_Increase_Percent__c);
    System.assertEquals(0.09, afterApprove[1].Proposed_Increase_Percent__c);
  }

  @isTest
  static void bulkApplyTemplate_scopedIterationIds() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.06,
          Status__c = 'Original'
        )
      }
    );
    List<Iteration__c> rows = [
      SELECT Id, Sequence__c, Duration_Months__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    Iteration__c template = new Iteration__c(Duration_Months__c = 3);
    Test.startTest();
    IterationService.BulkApplyResult result = IterationService.bulkApplyTemplate(
      new List<Id>{ oli.Id },
      new Map<Id, Date>{ oli.Id => oli.End_date__c },
      template,
      new Map<Id, List<Id>>{ oli.Id => new List<Id>{ rows[0].Id } }
    );
    Test.stopTest();
    System.assertEquals(1, result.updatedRows);
    rows = [
      SELECT Duration_Months__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    System.assertEquals(3, rows[0].Duration_Months__c);
    System.assertEquals(12, rows[1].Duration_Months__c);
  }

  @isTest
  static void bulkApplyTemplate_skipsCompletedInScope() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Completed'
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.06,
          Status__c = 'Original'
        )
      }
    );
    List<Iteration__c> rows = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    Iteration__c template = new Iteration__c(Duration_Months__c = 6);
    Test.startTest();
    IterationService.BulkApplyResult result = IterationService.bulkApplyTemplate(
      new List<Id>{ oli.Id },
      new Map<Id, Date>{ oli.Id => oli.End_date__c },
      template,
      new Map<Id, List<Id>>{ oli.Id => new List<Id>{ rows[0].Id, rows[1].Id } }
    );
    Test.stopTest();
    System.assertEquals(1, result.updatedRows);
    System.assertEquals(1, result.skippedCompletedRows);
    rows = [
      SELECT Duration_Months__c, Status__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c
    ];
    System.assertEquals(12, rows[0].Duration_Months__c);
    System.assertEquals('Completed', rows[0].Status__c);
    System.assertEquals(6, rows[1].Duration_Months__c);
  }

  @isTest
  static void savePlan_firstProposedSnapshotsOriginalWithoutCopyingWorking() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
      SELECT Id, Increase_Type__c, Increase_Percent__c, Status__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    row.Proposed_Increase_Type__c = 'Increase_by_Percentage';
    Test.startTest();
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ row }
    );
    Test.stopTest();
    row = [
      SELECT
        Original_Increase_Type__c,
        Original_Increase_Percent__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c,
        Increase_Percent__c,
        Status__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    System.assertEquals('Original', row.Status__c);
    System.assertEquals(
      'Increase_by_Percentage',
      row.Original_Increase_Type__c
    );
    System.assertEquals(0.05, row.Original_Increase_Percent__c);
    System.assertEquals(
      'Increase_by_Percentage',
      row.Proposed_Increase_Type__c
    );
    System.assertEquals(null, row.Proposed_Increase_Percent__c);
    System.assertEquals(null, row.Proposed_Increase_Amount__c);
    System.assertEquals(null, row.Proposed_Final_Price__c);
    System.assertEquals(0.05, row.Increase_Percent__c);
  }

  @isTest
  static void savePlan_proposedEditableWithoutNegotiation() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Test.startTest();
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
    Test.stopTest();
    Iteration__c row = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    System.assertEquals('Original', row.Status__c);
    System.assertEquals(0.05, row.Increase_Percent__c);
    System.assertEquals(0.08, row.Proposed_Increase_Percent__c);
  }

  @isTest
  static void savePlan_statusApprovedWithoutActionDoesNotPromote() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
        Increase_Type__c,
        Increase_Percent__c,
        Status__c,
        Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    row.Status__c = 'Approved';
    Test.startTest();
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ row }
    );
    Test.stopTest();
    row = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    System.assertEquals('Approved', row.Status__c);
    System.assertEquals(0.05, row.Increase_Percent__c);
    System.assertEquals(0.08, row.Proposed_Increase_Percent__c);
  }

  @isTest
  static void savePlan_newProposedOnApprovedKeepsApproved() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    IterationService.approve(row.Id, false);
    row = [
      SELECT
        Id,
        Increase_Type__c,
        Increase_Percent__c,
        Status__c,
        Original_Increase_Percent__c,
        Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    row.Proposed_Increase_Type__c = 'Increase_by_Percentage';
    row.Proposed_Increase_Percent__c = 0.12;
    Test.startTest();
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ row }
    );
    Test.stopTest();
    row = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    System.assertEquals('Approved', row.Status__c);
    System.assertEquals(0.08, row.Increase_Percent__c);
    System.assertEquals(0.12, row.Proposed_Increase_Percent__c);
  }

  @isTest
  static void approve_skipsWhenNoProposedIncrease() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Test.startTest();
    IterationService.ApproveResult result = IterationService.approve(
      row.Id,
      false
    );
    Test.stopTest();
    System.assertEquals(0, result.approvedCount);
    System.assertEquals(1, result.skippedNoProposed);
    System.assertEquals(
      'Original',
      [SELECT Status__c FROM Iteration__c WHERE Id = :row.Id].Status__c
    );
  }

  @isTest
  static void savePlan_keepsProposedEdits() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
        Increase_Type__c,
        Increase_Percent__c,
        Status__c,
        Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    row.Proposed_Increase_Percent__c = 0.11;
    Test.startTest();
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{ row }
    );
    Test.stopTest();
    row = [
      SELECT Status__c, Increase_Percent__c, Proposed_Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    System.assertEquals('Original', row.Status__c);
    System.assertEquals(0.05, row.Increase_Percent__c);
    System.assertEquals(0.11, row.Proposed_Increase_Percent__c);
  }

  @isTest
  static void copyFromReplacedOrderProducts_movesPlanAndInactivatesSource() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter Repl Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      EndDate = Date.today().addYears(2)
    );
    insert ord;
    OrderItem parentOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addYears(1)
    );
    insert parentOi;
    IterationService.savePlan(
      parentOi.Id,
      parentOi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original'
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.08,
          Status__c = 'Completed'
        )
      }
    );
    OrderItem childOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today().addMonths(1),
      EndDate = Date.today().addYears(2),
      Replaced_Order_Product__c = parentOi.Id
    );
    insert childOi;

    Test.startTest();
    IterationService.copyFromReplacedOrderProducts(
      new List<OrderItem>{ childOi }
    );
    Test.stopTest();

    List<Iteration__c> onChild = [
      SELECT Status__c, Increase_Percent__c
      FROM Iteration__c
      WHERE Order_Product__c = :childOi.Id
      ORDER BY Sequence__c
    ];
    System.assertEquals(
      2,
      onChild.size(),
      'All rows including Completed should copy'
    );
    System.assertEquals('Original', onChild[0].Status__c);
    System.assertEquals('Completed', onChild[1].Status__c);

    List<Iteration__c> onParent = [
      SELECT Status__c, Prior_Status__c
      FROM Iteration__c
      WHERE Order_Product__c = :parentOi.Id
    ];
    System.assertEquals(2, onParent.size());
    for (Iteration__c row : onParent) {
      System.assertEquals('Inactive', row.Status__c);
      System.assertNotEquals(null, row.Prior_Status__c);
    }
    System.assertEquals(
      0,
      IterationService.queryByParent(new Set<Id>{ parentOi.Id }).size(),
      'Active query excludes Inactive'
    );
    OrderItem parentStamped = [
      SELECT Remaining_Iterations__c
      FROM OrderItem
      WHERE Id = :parentOi.Id
    ];
    System.assertEquals(0, parentStamped.Remaining_Iterations__c);
  }

  @isTest
  static void copyFromReplacedOrderProducts_skipsAccessTypeChange() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter AT Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      EndDate = Date.today().addYears(1)
    );
    insert ord;
    OrderItem parentOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addYears(1)
    );
    insert parentOi;
    IterationService.savePlan(
      parentOi.Id,
      parentOi.EndDate,
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
    OrderItem childOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today().addMonths(1),
      EndDate = Date.today().addYears(1),
      Replaced_Order_Product__c = parentOi.Id,
      Changed_Access_Type__c = true
    );
    insert childOi;

    Test.startTest();
    IterationService.copyFromReplacedOrderProducts(
      new List<OrderItem>{ childOi }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Iteration__c WHERE Order_Product__c = :childOi.Id]
    );
    System.assertEquals(
      'Original',
      [
        SELECT Status__c
        FROM Iteration__c
        WHERE Order_Product__c = :parentOi.Id
        LIMIT 1
      ]
      .Status__c
    );
  }

  @isTest
  static void restoreFromReplacedOrderProducts_restoresParentWhenNoSiblings() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Id pb = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = new Locations__c(
      Name = 'Iter Restore Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test',
      Address__c = '1 St'
    );
    insert loc;
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      EndDate = Date.today().addYears(2)
    );
    insert ord;
    OrderItem parentOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addYears(1)
    );
    insert parentOi;
    IterationService.savePlan(
      parentOi.Id,
      parentOi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original',
          Proposed_Increase_Type__c = 'Increase_by_Percentage',
          Proposed_Increase_Percent__c = 0.05
        )
      }
    );
    Iteration__c parentIter = [
      SELECT Id
      FROM Iteration__c
      WHERE Order_Product__c = :parentOi.Id
      LIMIT 1
    ];
    IterationService.approve(parentIter.Id, false);
    OrderItem childOi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today().addMonths(1),
      EndDate = Date.today().addYears(2),
      Replaced_Order_Product__c = parentOi.Id
    );
    insert childOi;
    IterationService.copyFromReplacedOrderProducts(
      new List<OrderItem>{ childOi }
    );

    Test.startTest();
    IterationService.restoreFromReplacedOrderProducts(
      new List<OrderItem>{ childOi }
    );
    Test.stopTest();

    List<Iteration__c> onParent = [
      SELECT Status__c, Prior_Status__c
      FROM Iteration__c
      WHERE Order_Product__c = :parentOi.Id
    ];
    System.assertEquals(1, onParent.size());
    System.assertEquals('Approved', onParent[0].Status__c);
    System.assertEquals(null, onParent[0].Prior_Status__c);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Iteration__c WHERE Order_Product__c = :childOi.Id]
    );
  }

  @isTest
  static void savePlan_rejectsWorkingTypeWithoutValue() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Boolean threw = false;
    try {
      IterationService.savePlan(
        oli.Id,
        oli.End_date__c,
        new List<Iteration__c>{
          new Iteration__c(
            Duration_Months__c = 12,
            Advance_Notice_Days__c = 30,
            Increase_Type__c = 'Increase_by_Percentage',
            Status__c = 'Original'
          )
        }
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(
      true,
      threw,
      'Expected type-without-value to be rejected'
    );
  }

  @isTest
  static void deleteIterations_resequencesAndRecalculatesFollowingRows() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 5,
          Status__c = 'Approved'
        ),
        new Iteration__c(
          Duration_Months__c = 6,
          Advance_Notice_Days__c = 15,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 8,
          Status__c = 'Approved'
        )
      }
    );
    List<Iteration__c> before = [
      SELECT Id, Sequence__c, Period_Start_Date__c, Period_End_Date__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC
    ];
    System.assertEquals(2, before.size());

    IterationService.DeleteIterationRequest req = new IterationService.DeleteIterationRequest();
    req.lineId = oli.Id;
    req.lineEndDate = oli.End_date__c;
    req.iterationId = before[0].Id;

    Test.startTest();
    IterationService.DeleteResult del = IterationService.deleteIterations(
      new List<IterationService.DeleteIterationRequest>{ req }
    );
    Test.stopTest();

    System.assertNotEquals(null, del);
    List<Iteration__c> after = [
      SELECT
        Id,
        Sequence__c,
        Period_Start_Date__c,
        Period_End_Date__c,
        Increase_Percent__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC
    ];
    System.assertEquals(1, after.size());
    System.assertEquals(1, after[0].Sequence__c);
    System.assertEquals(8, after[0].Increase_Percent__c);
    System.assertEquals(
      oli.End_date__c.addDays(1),
      after[0].Period_Start_Date__c
    );
  }

  @isTest
  static void deleteIterations_multipleRowsInOneSave() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Status__c = 'Approved'
        ),
        new Iteration__c(
          Duration_Months__c = 6,
          Advance_Notice_Days__c = 15,
          Status__c = 'Approved'
        ),
        new Iteration__c(
          Duration_Months__c = 3,
          Advance_Notice_Days__c = 10,
          Status__c = 'Approved'
        )
      }
    );
    List<Iteration__c> before = [
      SELECT Id, Sequence__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC
    ];
    System.assertEquals(3, before.size());

    List<IterationService.DeleteIterationRequest> reqs = new List<IterationService.DeleteIterationRequest>();
    for (Integer i = 0; i < 2; i++) {
      IterationService.DeleteIterationRequest req = new IterationService.DeleteIterationRequest();
      req.lineId = oli.Id;
      req.lineEndDate = oli.End_date__c;
      req.iterationId = before[i].Id;
      reqs.add(req);
    }

    Test.startTest();
    IterationService.deleteIterations(reqs);
    Test.stopTest();

    List<Iteration__c> after = [
      SELECT Sequence__c, Duration_Months__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC
    ];
    System.assertEquals(1, after.size());
    System.assertEquals(1, after[0].Sequence__c);
    System.assertEquals(3, after[0].Duration_Months__c);
  }

  @isTest
  static void savePlan_resaveWithCompletedKeepsDistinctSequences() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 100,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.5,
          Status__c = 'Completed'
        ),
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 300,
          Status__c = 'Original'
        )
      }
    );
    List<Iteration__c> rows = [
      SELECT Id, Sequence__c, Status__c, Advance_Notice_Days__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC, CreatedDate ASC
    ];
    System.assertEquals(2, rows.size());
    System.assertEquals(1, rows[0].Sequence__c);
    System.assertEquals('Completed', rows[0].Status__c);
    System.assertEquals(2, rows[1].Sequence__c);

    Test.startTest();
    IterationService.savePlan(oli.Id, oli.End_date__c, rows);
    Test.stopTest();

    rows = [
      SELECT Id, Sequence__c, Status__c, Advance_Notice_Days__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC, CreatedDate ASC
    ];
    System.assertEquals(2, rows.size(), 'Both iterations should remain');
    System.assertEquals(1, rows[0].Sequence__c, 'Completed keeps sequence 1');
    System.assertEquals('Completed', rows[0].Status__c);
    System.assertEquals(
      2,
      rows[1].Sequence__c,
      'Open row must not reuse Completed sequence'
    );
    System.assertEquals(300, rows[1].Advance_Notice_Days__c);

    IterationService.ActionResult proposed = IterationService.saveProposedIterations(
      new List<Id>{ rows[1].Id },
      new Iteration__c(
        Proposed_Increase_Type__c = 'Increase_by_Value',
        Proposed_Increase_Amount__c = 123
      )
    );
    System.assertEquals(1, proposed.processedCount);
    System.assertEquals(0, proposed.skippedCount);
    Iteration__c openRow = [
      SELECT Proposed_Increase_Type__c, Proposed_Increase_Amount__c, Status__c
      FROM Iteration__c
      WHERE Id = :rows[1].Id
    ];
    System.assertEquals('Increase_by_Value', openRow.Proposed_Increase_Type__c);
    System.assertEquals(123, openRow.Proposed_Increase_Amount__c);
    System.assertEquals('Proposed', openRow.Status__c);
  }

  @isTest
  static void deleteIterations_blocksCompleted() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Status__c = 'Completed'
        )
      }
    );
    Iteration__c completed = [
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    IterationService.DeleteIterationRequest req = new IterationService.DeleteIterationRequest();
    req.lineId = oli.Id;
    req.lineEndDate = oli.End_date__c;
    req.iterationId = completed.Id;

    Boolean threw = false;
    Test.startTest();
    try {
      IterationService.deleteIterations(
        new List<IterationService.DeleteIterationRequest>{ req }
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    Test.stopTest();
    System.assertEquals(true, threw);
  }

  @isTest
  static void deleteIterations_allowsDeleteWhenOtherRowHasIncompleteCommercial() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Iteration__c incomplete = new Iteration__c(
      Opportunity_Product__c = oli.Id,
      Sequence__c = 1,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30,
      Increase_Type__c = 'Increase_by_Value',
      Status__c = 'Original'
    );
    insert incomplete;

    Iteration__c toDelete = new Iteration__c(
      Opportunity_Product__c = oli.Id,
      Sequence__c = 2,
      Duration_Months__c = 6,
      Advance_Notice_Days__c = 15,
      Increase_Type__c = 'Increase_by_Percentage',
      Increase_Percent__c = 5,
      Status__c = 'Approved'
    );
    insert toDelete;

    IterationService.DeleteIterationRequest req = new IterationService.DeleteIterationRequest();
    req.lineId = oli.Id;
    req.lineEndDate = oli.End_date__c;
    req.iterationId = toDelete.Id;

    Test.startTest();
    IterationService.deleteIterations(
      new List<IterationService.DeleteIterationRequest>{ req }
    );
    Test.stopTest();

    List<Iteration__c> after = [
      SELECT Id, Sequence__c, Increase_Type__c
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      ORDER BY Sequence__c ASC
    ];
    System.assertEquals(1, after.size());
    System.assertEquals(incomplete.Id, after[0].Id);
    System.assertEquals(1, after[0].Sequence__c);
  }

  @isTest
  static void bulkApplyTemplate_requiresIterationScope() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    IterationService.savePlan(
      oli.Id,
      oli.End_date__c,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 6,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original'
        )
      }
    );
    Boolean threw = false;
    Test.startTest();
    try {
      IterationService.bulkApplyTemplate(
        new List<Id>{ oli.Id },
        new Map<Id, Date>{ oli.Id => oli.End_date__c },
        new Iteration__c(Duration_Months__c = 12),
        new Map<Id, List<Id>>()
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    Test.stopTest();
    System.assertEquals(true, threw);
  }

  @isTest
  static void rejectProposed_setsRejectedStatus() {
    OpportunityLineItem oli = [
      SELECT Id, End_date__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
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
      SELECT Id
      FROM Iteration__c
      WHERE Opportunity_Product__c = :oli.Id
      LIMIT 1
    ];
    Test.startTest();
    IterationService.saveProposed(
      row.Id,
      new Iteration__c(
        Proposed_Increase_Type__c = 'Increase_by_Percentage',
        Proposed_Increase_Percent__c = 0.08
      )
    );
    IterationService.rejectProposed(row.Id);
    Test.stopTest();
    row = [
      SELECT Status__c, Proposed_Increase_Percent__c, Increase_Percent__c
      FROM Iteration__c
      WHERE Id = :row.Id
    ];
    System.assertEquals('Rejected', row.Status__c);
    System.assertEquals(null, row.Proposed_Increase_Percent__c);
    System.assertEquals(0.05, row.Increase_Percent__c);
  }
}
