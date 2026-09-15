@isTest(IsParallel=false)
public class IterationAutoRenewService_Test {
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
      Name = 'Iter Renew Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Iter Renew',
      Address__c = '1 Test St',
      Area__c = areaValue
    );
    insert loc;
    Id pb = Test.getStandardPricebookId();
    Product2 prod = new Product2(
      Name = 'Periodic Renew',
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
    Account acc = new Account(Name = 'Iter Renew Acc');
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
    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today().addMonths(-6),
      EndDate = Date.today().addDays(30),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert oi;
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

  private static Id activateDuePeriodicLine() {
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
    List<Iteration__c> rows = new List<Iteration__c>{
      new Iteration__c(
        Duration_Months__c = 12,
        Advance_Notice_Days__c = 30,
        Increase_Type__c = 'Increase_by_Percentage',
        Increase_Percent__c = 0.10,
        Status__c = 'Original'
      )
    };
    IterationService.savePlan(oi.Id, oi.EndDate, rows);
    oi = [SELECT Id, Remaining_Iterations__c FROM OrderItem WHERE Id = :oi.Id];
    System.assert(
      oi.Remaining_Iterations__c > 0,
      'Expected remaining iterations'
    );
    return contr.Id;
  }

  @isTest
  static void applyIncrease_blankAndNewTypeApis() {
    System.assertEquals(
      100,
      IterationAutoRenewService.applyIncrease(
        new Iteration__c(Increase_Percent__c = 0.10),
        100
      ),
      'Blank Increase_Type means no increase'
    );
    System.assertEquals(
      120,
      IterationAutoRenewService.applyIncrease(
        new Iteration__c(
          Increase_Type__c = 'Increase_by_Value',
          Increase_Amount__c = 20
        ),
        100
      )
    );
    System.assertEquals(
      130,
      IterationAutoRenewService.applyIncrease(
        new Iteration__c(
          Increase_Type__c = 'Final_Price',
          Final_Price__c = 130
        ),
        100
      )
    );
    System.assertEquals(
      110,
      IterationAutoRenewService.applyIncrease(
        new Iteration__c(
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.10
        ),
        100
      )
    );
    // Legacy labels still normalize for renew pricing.
    System.assertEquals(
      120,
      IterationAutoRenewService.applyIncrease(
        new Iteration__c(
          Increase_Type__c = 'Fixed Amount',
          Increase_Amount__c = 20
        ),
        100
      )
    );
  }

  @isTest
  static void processContract_skipsWhenNoActiveOrder() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Test.startTest();
    IterationAutoRenewService.RunResult result = IterationAutoRenewService.processContract(
      contr.Id
    );
    Test.stopTest();
    System.assertEquals('Skipped', result.outcome);
    System.assertEquals('No active order', result.message);
  }

  @isTest
  static void processContract_skipsWhenNoDueLines() {
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
    List<Iteration__c> rows = new List<Iteration__c>{
      new Iteration__c(
        Duration_Months__c = 12,
        Advance_Notice_Days__c = 10,
        Increase_Type__c = 'Increase_by_Percentage',
        Increase_Percent__c = 0.05,
        Status__c = 'Original'
      )
    };
    IterationService.savePlan(oi.Id, oi.EndDate, rows);
    Test.startTest();
    IterationAutoRenewService.RunResult result = IterationAutoRenewService.processContract(
      contr.Id
    );
    Test.stopTest();
    System.assertEquals('Skipped', result.outcome);
    System.assertEquals('Zero eligible due lines', result.message);
  }

  @isTest
  static void processDueRenewals_failAfterClone_stampsFailed() {
    Id contractId = activateDuePeriodicLine();
    IterationAutoRenewService.failAfterClone = true;
    Test.startTest();
    IterationAutoRenewService.processDueRenewals();
    Test.stopTest();
    IterationAutoRenewService.failAfterClone = false;
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contractId
    ];
    System.assert(
      c.Last_Auto_Renew_Result__c.contains('Failed'),
      c.Last_Auto_Renew_Result__c
    );
  }

  @isTest
  static void resolveBasis_fallsBackToUnitPrice() {
    bypassHeavyAutomation();
    OrderItem oi = [SELECT Id, UnitPrice FROM OrderItem LIMIT 1];
    Test.startTest();
    Decimal basis = IterationAutoRenewService.resolveBasis(oi);
    Test.stopTest();
    System.assertEquals(1000, basis);
  }

  @isTest
  static void isLineEligible_excludesTerminatedAndNonPeriodic() {
    OrderItem periodic = new OrderItem(
      Access_Type__c = 'Periodic',
      Remaining_Iterations__c = 1
    );
    OrderItem terminated = new OrderItem(
      Access_Type__c = 'Periodic',
      Remaining_Iterations__c = 1,
      Termination_Reason__c = 'Left'
    );
    OrderItem daily = new OrderItem(
      Access_Type__c = 'Daily',
      Remaining_Iterations__c = 1
    );
    System.assert(IterationAutoRenewService.isLineEligible(periodic));
    System.assert(!IterationAutoRenewService.isLineEligible(terminated));
    System.assert(!IterationAutoRenewService.isLineEligible(daily));
  }

  @isTest
  static void processContract_success_autoRenewsDueLine() {
    Id contractId = activateDuePeriodicLine();
    OrderItem activeLine = [
      SELECT Id, EndDate, UnitPrice, Quantity
      FROM OrderItem
      WHERE Order.ContractId = :contractId AND Order.Status = 'Activated'
      LIMIT 1
    ];
    Test.startTest();
    Integer soqlBefore = Limits.getQueries();
    IterationAutoRenewService.RunResult result = IterationAutoRenewService.processContract(
      contractId
    );
    Integer soqlUsed = Limits.getQueries() - soqlBefore;
    Test.stopTest();
    System.assertEquals('Success', result.outcome, result.message);
    System.assert(
      soqlUsed < 90,
      'Auto-renew SOQL budget too high for one contract: ' + soqlUsed
    );
    System.assertNotEquals(null, result.newOrderId);
    Iteration__c completed = [
      SELECT Status__c
      FROM Iteration__c
      WHERE Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    System.assertEquals('Completed', completed.Status__c);
    OrderItem newLine = [
      SELECT Id, Remaining_Iterations__c, UnitPrice
      FROM OrderItem
      WHERE
        OrderId = :result.newOrderId
        AND Original_Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    System.assertEquals(
      activeLine.UnitPrice,
      newLine.UnitPrice,
      'Auto-renew must preserve per-desk UnitPrice'
    );
    List<Iteration__c> onNewLine = [
      SELECT Status__c
      FROM Iteration__c
      WHERE Order_Product__c = :newLine.Id
    ];
    System.assertEquals(
      1,
      onNewLine.size(),
      'Completed plan should copy to new line'
    );
    System.assertEquals('Completed', onNewLine[0].Status__c);
    System.assertEquals(
      0,
      newLine.Remaining_Iterations__c,
      'Remaining excludes completed rows'
    );
    List<OrderItem> clonedLines = [
      SELECT Change_Type__c, Original_Order_Product__c
      FROM OrderItem
      WHERE OrderId = :result.newOrderId
    ];
    System.assert(!clonedLines.isEmpty());
    for (OrderItem line : clonedLines) {
      System.assertEquals('No Change', line.Change_Type__c);
    }
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contractId
    ];
    System.assert(c.Last_Auto_Renew_Result__c.contains('Success'));
  }

  @isTest
  static void processContract_extendsContractBeforeOrderEndWhenRenewalExceedsContractEnd() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Date lineEnd = Date.today().addDays(30);
    Date shortContractEnd = Date.today().addDays(45);
    contr.EndDate = shortContractEnd;
    update contr;
    Order ord = [SELECT Id FROM Order WHERE ContractId = :contr.Id LIMIT 1];
    ord.Status = 'Activated';
    ord.EndDate = shortContractEnd;
    update ord;
    OrderItem oi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    oi.EndDate = lineEnd;
    update oi;
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
    Date expectedLineEnd = lineEnd.addDays(1).addMonths(12).addDays(-1);

    Test.startTest();
    IterationAutoRenewService.RunResult result = IterationAutoRenewService.processContract(
      contr.Id
    );
    Test.stopTest();

    System.assertEquals('Success', result.outcome, result.message);
    Contract renewedContract = [
      SELECT EndDate
      FROM Contract
      WHERE Id = :contr.Id
    ];
    Order activatedOrder = [
      SELECT EndDate
      FROM Order
      WHERE Id = :result.newOrderId
    ];
    OrderItem renewedLine = [
      SELECT EndDate
      FROM OrderItem
      WHERE OrderId = :result.newOrderId AND Original_Order_Product__c = :oi.Id
      LIMIT 1
    ];
    System.assert(
      renewedContract.EndDate >= expectedLineEnd,
      'Contract end must extend before order end can exceed prior contract limit'
    );
    System.assert(
      activatedOrder.EndDate >= expectedLineEnd,
      'Activated order end should cover renewed line'
    );
    System.assertEquals(expectedLineEnd, renewedLine.EndDate);
  }

  @isTest
  static void processDueRenewals_runsForDueContracts() {
    Id contractId = activateDuePeriodicLine();
    Test.startTest();
    IterationAutoRenewService.processDueRenewals();
    Test.stopTest();
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contractId
    ];
    System.assertNotEquals(null, c.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void findDueContracts_ignoresDraftOrderIterations() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrd = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrd.Status = 'Activated';
    update activeOrd;
    OrderItem activeOi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrd.Id
      LIMIT 1
    ];
    // Active plan: notice still in the future (not due).
    activeOi.EndDate = Date.today().addDays(60);
    update activeOi;
    IterationService.savePlan(
      activeOi.Id,
      activeOi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 10,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original'
        )
      }
    );

    Id pb = Test.getStandardPricebookId();
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order draftOrd = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      EndDate = Date.today().addDays(10),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      ContractId = contr.Id,
      Previous_Order__c = activeOrd.Id
    );
    insert draftOrd;
    OrderItem draftOi = new OrderItem(
      OrderId = draftOrd.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today(),
      EndDate = Date.today().addDays(10),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Original_Order_Product__c = activeOi.Id,
      Change_Type__c = 'No Change'
    );
    insert draftOi;
    // Draft plan: notice already due — must not drive discovery.
    IterationService.savePlan(
      draftOi.Id,
      draftOi.EndDate,
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
    Set<Id> dueContracts = IterationAutoRenewService.findContractsWithDueActivatedIterations(
      Date.today()
    );
    IterationAutoRenewService.processDueRenewals();
    Test.stopTest();

    System.assert(
      !dueContracts.contains(contr.Id),
      'Draft due Iterations must not mark the contract for renew'
    );
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      null,
      c.Last_Auto_Renew_Result__c,
      'Renew must not run from Draft Iterations alone'
    );
  }

  @isTest
  static void batch_processesDueActivatedContract() {
    Id contractId = activateDuePeriodicLine();
    Test.startTest();
    Database.executeBatch(new IterationAutoRenewBatch(), 20);
    Test.stopTest();
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contractId
    ];
    System.assertNotEquals(null, c.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void batch_runsWithoutPickingDraftIterations() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrd = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrd.Status = 'Activated';
    update activeOrd;
    OrderItem activeOi = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrd.Id
      LIMIT 1
    ];
    activeOi.EndDate = Date.today().addDays(60);
    update activeOi;
    IterationService.savePlan(
      activeOi.Id,
      activeOi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 10,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.05,
          Status__c = 'Original'
        )
      }
    );
    Id pb = Test.getStandardPricebookId();
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order draftOrd = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      EndDate = Date.today().addDays(10),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      ContractId = contr.Id,
      Previous_Order__c = activeOrd.Id
    );
    insert draftOrd;
    OrderItem draftOi = new OrderItem(
      OrderId = draftOrd.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today(),
      EndDate = Date.today().addDays(10),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Original_Order_Product__c = activeOi.Id,
      Change_Type__c = 'No Change'
    );
    insert draftOi;
    IterationService.savePlan(
      draftOi.Id,
      draftOi.EndDate,
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
    Database.executeBatch(new IterationAutoRenewBatch(), 20);
    Test.stopTest();
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(null, c.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void resolveBasisByItems_oneQueryForMany() {
    bypassHeavyAutomation();
    OrderItem oi = [SELECT Id, UnitPrice, EndDate FROM OrderItem LIMIT 1];
    Test.startTest();
    Integer before = Limits.getQueries();
    Map<Id, Decimal> basis = IterationAutoRenewService.resolveBasisByItems(
      new List<OrderItem>{ oi, oi }
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();
    System.assertEquals(true, basis.containsKey(oi.Id));
    System.assert(used <= 1, 'Expected at most 1 SOQL, got ' + used);
  }

  @isTest
  static void schedulable_runNow_enqueuesBatch() {
    Id contractId = activateDuePeriodicLine();
    Test.startTest();
    new IterationAutoRenewSchedulable().execute(null);
    IterationAutoRenewSchedulable.runNow();
    Test.stopTest();
    Contract c = [
      SELECT Last_Auto_Renew_Result__c
      FROM Contract
      WHERE Id = :contractId
    ];
    System.assertNotEquals(null, c.Last_Auto_Renew_Result__c);
  }

  @isTest
  static void lineListMonthTotal_usesQuantityForFullMonthFallback() {
    OrderItem singleDesk = new OrderItem(UnitPrice = 1000, Quantity = 1);
    OrderItem multiDesk = new OrderItem(UnitPrice = 1700, Quantity = 5);
    System.assertEquals(
      1000,
      IterationAutoRenewService.lineListMonthTotal(singleDesk)
    );
    System.assertEquals(
      8500,
      IterationAutoRenewService.lineListMonthTotal(multiDesk)
    );
  }

  @isTest
  static void resolveBasis_extrapolatesPartialLastMonthToFullMonth() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, UnitPrice, Quantity, EndDate
      FROM OrderItem
      LIMIT 1
    ];
    oi.Quantity = 5;
    oi.UnitPrice = 1700;
    oi.EndDate = Date.newInstance(2027, 9, 1);
    update oi;
    Date partialStart = Date.newInstance(2027, 9, 1);
    insert new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 9,
      Stat_Date_Trigger__c = partialStart,
      End_Date_trigger__c = partialStart
    );
    Test.startTest();
    Decimal basis = IterationAutoRenewService.resolveBasis(oi);
    Test.stopTest();
    System.assertEquals(
      8500,
      basis,
      'Partial last month should extrapolate to full-month basis'
    );
  }

  @isTest
  static void processContract_multiDesk_preservesPerDeskUnitPriceAndAppliesIncreaseOnNewPeriod() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [SELECT Id FROM Order WHERE ContractId = :contr.Id LIMIT 1];
    ord.Status = 'Activated';
    update ord;
    OrderItem oi = [
      SELECT Id, EndDate, UnitPrice, Quantity
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    oi.Quantity = 5;
    oi.UnitPrice = 1700;
    oi.EndDate = Date.today().addDays(30);
    update oi;
    IterationService.savePlan(
      oi.Id,
      oi.EndDate,
      new List<Iteration__c>{
        new Iteration__c(
          Duration_Months__c = 12,
          Advance_Notice_Days__c = 30,
          Increase_Type__c = 'Increase_by_Percentage',
          Increase_Percent__c = 0.50,
          Status__c = 'Original'
        )
      }
    );
    Date monthStart = Date.newInstance(
      oi.EndDate.year(),
      oi.EndDate.month(),
      1
    );
    insert new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = monthStart,
      End_Date_trigger__c = monthStart.addMonths(1).addDays(-1)
    );

    Test.startTest();
    IterationAutoRenewService.RunResult result = IterationAutoRenewService.processContract(
      contr.Id
    );
    Test.stopTest();

    System.assertEquals('Success', result.outcome, result.message);
    OrderItem renewedLine = [
      SELECT UnitPrice, Quantity
      FROM OrderItem
      WHERE OrderId = :result.newOrderId AND Original_Order_Product__c = :oi.Id
      LIMIT 1
    ];
    System.assertEquals(
      1700,
      renewedLine.UnitPrice,
      'Auto-renew must not write full-month basis onto per-desk UnitPrice'
    );
    System.assertEquals(5, renewedLine.Quantity);
    List<MonthlyPayment__c> payments = [
      SELECT
        Price__c,
        FinalPrice__c,
        Discount__c,
        Final_Adjusted_Price__c,
        Start_date__c,
        End_date__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :renewedLine.Id
      ORDER BY Start_date__c ASC
    ];
    System.assert(
      !payments.isEmpty(),
      'Expected monthly payments on renewed line'
    );
    Date newPeriodStart = oi.EndDate.addDays(1);
    Boolean sawPreRenewal = false;
    Boolean sawNewPeriodIncrease = false;
    for (MonthlyPayment__c mp : payments) {
      Date paymentEnd = mp.End_date__c;
      if (paymentEnd != null && paymentEnd < newPeriodStart) {
        sawPreRenewal = true;
        System.assert(
          mp.Price__c <= 8500,
          'Pre-renewal list price must not exceed full-month total: ' +
          mp.Price__c
        );
        System.assert(
          mp.Price__c < 20000,
          'Pre-renewal list price must not be inflated by UnitPrice mix-up: ' +
          mp.Price__c
        );
        System.assertEquals(
          0,
          mp.Discount__c == null ? 0 : mp.Discount__c,
          'Pre-renewal months must not get iteration discount'
        );
      } else if (paymentEnd != null && paymentEnd >= newPeriodStart) {
        sawNewPeriodIncrease = true;
        System.assertEquals(
          50,
          mp.Discount__c.setScale(0),
          'New period should get +50% iteration increase'
        );
        System.assertEquals(
          12750,
          mp.Final_Adjusted_Price__c.setScale(0),
          'New period final should be 8500 + 50%'
        );
      }
    }
    System.assert(
      sawPreRenewal,
      'Expected at least one pre-renewal monthly payment'
    );
    System.assert(
      sawNewPeriodIncrease,
      'Expected at least one new-period monthly payment'
    );
  }

  @isTest
  static void applyNewPeriodDiscounts_includesMonthStartingAfterOldEnd() {
    bypassHeavyAutomation();
    OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
    Date oldEnd = Date.newInstance(2026, 10, 1);
    Date newStart = oldEnd.addDays(1);
    MonthlyPayment__c payment = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 10,
      End_Date_trigger__c = Date.newInstance(2026, 10, 31)
    );
    insert payment;
    Set<Id> lineIds = new Set<Id>{ oi.Id };
    Map<Id, Date> oldEndByLine = new Map<Id, Date>{ oi.Id => oldEnd };
    Map<Id, Decimal> discountByLine = new Map<Id, Decimal>{ oi.Id => 50 };
    Map<Id, Decimal> targetByLine = new Map<Id, Decimal>{ oi.Id => 950 };

    Test.startTest();
    IterationAutoRenewService.applyNewPeriodDiscounts(
      lineIds,
      oldEndByLine,
      discountByLine,
      targetByLine
    );
    Test.stopTest();

    payment = [
      SELECT Discount__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    System.assertEquals(
      50,
      payment.Discount__c,
      'October MP should get discount when new period starts ' +
      String.valueOf(newStart)
    );
    System.assertEquals(950, payment.Final_Adjusted_Price__c);
  }

  @isTest
  static void renewDiscountUsesListBasis_notCommercialBasis() {
    Decimal listTotal = 200;
    Decimal commercialBasis = 800;
    Decimal targetFinal = 923;

    Decimal wrongStored = (((targetFinal / commercialBasis) - 1) * 100)
      .setScale(6);
    Decimal correctStored = RecurringPriceIncreaseService.discountForMonthlyPaymentStorage(
      listTotal,
      targetFinal
    );

    Decimal wrongPayable = listTotal * (1 + wrongStored / 100);
    System.assertEquals(
      230.75,
      wrongPayable.setScale(2),
      'Commercial-basis discount misprices list MP'
    );

    Decimal correctPayable = listTotal * (1 + correctStored / 100);
    System.assertEquals(
      923,
      correctPayable.setScale(2),
      'List-basis discount must yield iteration target payable'
    );
  }
}
