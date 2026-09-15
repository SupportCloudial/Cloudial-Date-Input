@IsTest(IsParallel=false)
private class RecurringPriceIncreaseController_Test {
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
      Name = 'RPI Ctrl Loc',
      City__c = 'Petah Tikva',
      Site_Name__c = 'RPI',
      Address__c = '1 St',
      Area__c = areaValue
    );
    insert loc;

    Id pb = Test.getStandardPricebookId();
    Product2 prod = new Product2(
      Name = 'RPI Monthly Room',
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

    Account acc = new Account(Name = 'RPI Ctrl Account');
    insert acc;

    Date today = Date.today();
    Opportunity opp = new Opportunity(
      Name = 'RPI Opp',
      AccountId = acc.Id,
      StageName = 'New',
      CloseDate = today.addMonths(1),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      Start_Date__c = today
    );
    insert opp;

    OpportunityLineItem oliMonthly = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Monthly',
      Entry_Date__c = today,
      End_date__c = today.addMonths(12)
    );
    OpportunityLineItem oliRent = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Rent',
      Entry_Date__c = today,
      End_date__c = today.addMonths(12)
    );
    insert new List<OpportunityLineItem>{ oliMonthly, oliRent };

    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = today,
      EndDate = today.addMonths(24)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = today,
      Order_Start_Date__c = today,
      EndDate = today.addMonths(24),
      Pricebook2Id = pb,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert ord;

    OrderItem oiMonthly = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Monthly',
      ServiceDate = today,
      EndDate = today.addMonths(12)
    );
    OrderItem oiPeriodic = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = today,
      EndDate = today.addMonths(12)
    );
    insert new List<OrderItem>{ oiMonthly, oiPeriodic };
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
  }

  private static RecurringPriceIncreaseService.RuleDraft percentDraft(
    Integer frequencyMonths,
    Date startDate,
    Decimal percentFraction
  ) {
    RecurringPriceIncreaseService.RuleDraft draft = new RecurringPriceIncreaseService.RuleDraft();
    draft.frequencyMonths = frequencyMonths;
    draft.startDate = startDate;
    draft.increaseType = RecurringPriceIncreaseService.TYPE_PERCENT;
    draft.increasePercent = percentFraction;
    return draft;
  }

  @IsTest
  static void loadContext_emptySelectionThrows() {
    Boolean threw = false;
    try {
      RecurringPriceIncreaseController.loadContext(new List<Id>(), false);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @IsTest
  static void loadContext_archivedBlocked() {
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Test.startTest();
    RecurringPriceIncreaseController.LoadResult res = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ oi.Id },
      true
    );
    Test.stopTest();
    System.assertEquals(true, res.archivedBlocked);
    System.assertEquals(0, res.eligibleLineIds.size());
  }

  @IsTest
  static void loadContext_skipsIneligibleAndSetsMinStart() {
    OpportunityLineItem monthly = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    OpportunityLineItem rent = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Rent'
      LIMIT 1
    ];
    Test.startTest();
    RecurringPriceIncreaseController.LoadResult res = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ monthly.Id, rent.Id },
      false
    );
    Test.stopTest();
    System.assertEquals(1, res.eligibleCount);
    System.assertEquals(1, res.eligibleLineIds.size());
    System.assert(
      res.excludedMessage != null && res.excludedMessage.contains('Monthly')
    );
    System.assertEquals(Date.today(), res.minStartDate);
  }

  @IsTest
  static void saveRules_andPreview_roundTrip() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      3,
      Date.today(),
      0.03
    );

    Test.startTest();
    RecurringPriceIncreaseService.OverlapPreviewResult preview = RecurringPriceIncreaseController.previewOverlap(
      new List<Id>{ oi.Id },
      JSON.serialize(draft)
    );
    RecurringPriceIncreaseService.SaveResult saved = RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oi.Id },
      JSON.serialize(draft),
      false,
      false
    );
    Test.stopTest();

    System.assertEquals(false, preview.hasOverlap);
    System.assertEquals(1, saved.updatedLines);

    RecurringPriceIncreaseController.LoadResult loaded = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ oi.Id },
      false
    );
    System.assertEquals(true, loaded.anyRuleEnabled);
    System.assertEquals(3, loaded.frequencyMonths);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_PERCENT,
      loaded.increaseType
    );
  }

  @IsTest
  static void saveRules_invalidDraftThrows() {
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      0,
      Date.today(),
      0.03
    );
    Boolean threw = false;
    try {
      RecurringPriceIncreaseController.saveRules(
        new List<Id>{ oi.Id },
        JSON.serialize(draft),
        false,
        false
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @IsTest
  static void disableAndRemove_viaController() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oi.Id },
      JSON.serialize(percentDraft(3, Date.today(), 0.01)),
      false,
      false
    );

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult disabled = RecurringPriceIncreaseController.disableRules(
      new List<Id>{ oi.Id },
      false
    );
    RecurringPriceIncreaseService.SaveResult removed = RecurringPriceIncreaseController.removeRules(
      new List<Id>{ oi.Id },
      false
    );
    Test.stopTest();

    System.assertEquals(1, disabled.updatedLines);
    System.assertEquals(1, removed.updatedLines);
    OrderItem after = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Frequency_Months__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(false, after.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(null, after.Recurring_Increase_Frequency_Months__c);
  }

  @IsTest
  static void saveRules_andDisableRemove_opportunityLineItem() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      6,
      Date.today(),
      0.05
    );

    Test.startTest();
    RecurringPriceIncreaseService.OverlapPreviewResult preview = RecurringPriceIncreaseController.previewOverlap(
      new List<Id>{ oli.Id },
      JSON.serialize(draft)
    );
    RecurringPriceIncreaseService.SaveResult saved = RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oli.Id },
      JSON.serialize(draft),
      false,
      false
    );
    RecurringPriceIncreaseController.LoadResult loaded = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ oli.Id },
      false
    );
    RecurringPriceIncreaseService.SaveResult disabled = RecurringPriceIncreaseController.disableRules(
      new List<Id>{ oli.Id },
      false
    );
    RecurringPriceIncreaseService.SaveResult removed = RecurringPriceIncreaseController.removeRules(
      new List<Id>{ oli.Id },
      false
    );
    Test.stopTest();

    System.assertEquals(false, preview.hasOverlap);
    System.assertEquals(1, saved.updatedLines);
    System.assertEquals(true, loaded.anyRuleEnabled);
    System.assertEquals(6, loaded.frequencyMonths);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_PERCENT,
      loaded.increaseType
    );
    System.assertEquals(1, disabled.updatedLines);
    System.assertEquals(1, removed.updatedLines);

    OpportunityLineItem after = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Frequency_Months__c,
        Recurring_Increase_Percent__c,
        Recurring_Increase_Start_Date__c
      FROM OpportunityLineItem
      WHERE Id = :oli.Id
    ];
    System.assertEquals(false, after.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(null, after.Recurring_Increase_Frequency_Months__c);
    System.assertEquals(null, after.Recurring_Increase_Percent__c);
    System.assertEquals(null, after.Recurring_Increase_Start_Date__c);
  }

  @IsTest
  static void loadContext_orderItems_skipsIneligibleAndInconsistentRules() {
    bypassHeavyAutomation();
    Order ord = [SELECT Id, Pricebook2Id FROM Order LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Pricebook2Id = :ord.Pricebook2Id
      LIMIT 1
    ];
    Date today = Date.today();
    OrderItem oiRent = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Rent',
      ServiceDate = today,
      EndDate = today.addMonths(12)
    );
    insert oiRent;

    OrderItem oiMonthly = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    OrderItem oiPeriodic = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oiMonthly.Id },
      JSON.serialize(percentDraft(3, today, 0.02)),
      false,
      false
    );
    RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oiPeriodic.Id },
      JSON.serialize(percentDraft(6, today, 0.04)),
      false,
      false
    );

    Test.startTest();
    RecurringPriceIncreaseController.LoadResult res = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ null, oiMonthly.Id, oiPeriodic.Id, oiRent.Id },
      false
    );
    Test.stopTest();

    System.assertEquals(2, res.eligibleCount);
    System.assertEquals(true, res.anyRuleEnabled);
    System.assertEquals(null, res.frequencyMonths);
    System.assert(
      res.excludedMessage != null && res.excludedMessage.contains('Skipped')
    );
  }

  @IsTest
  static void saveRules_valueType_opportunityLineItem() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = new RecurringPriceIncreaseService.RuleDraft();
    draft.frequencyMonths = 4;
    draft.startDate = Date.today();
    draft.increaseType = RecurringPriceIncreaseService.TYPE_VALUE;
    draft.increaseAmount = 50;

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult saved = RecurringPriceIncreaseController.saveRules(
      new List<Id>{ oli.Id },
      JSON.serialize(draft),
      false,
      true
    );
    RecurringPriceIncreaseController.LoadResult loaded = RecurringPriceIncreaseController.loadContext(
      new List<Id>{ oli.Id },
      false
    );
    Test.stopTest();

    System.assertEquals(1, saved.updatedLines);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_VALUE,
      loaded.increaseType
    );
    System.assertEquals(50, loaded.increaseAmount);
    System.assertEquals(4, loaded.frequencyMonths);
  }

  @IsTest
  static void loadContext_nullListThrows() {
    Boolean threw = false;
    try {
      RecurringPriceIncreaseController.loadContext(null, false);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw);
  }

  @IsTest
  static void saveRuleFields_doesNotEnable() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      3,
      Date.today(),
      10
    );

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult saved = RecurringPriceIncreaseController.saveRuleFields(
      new List<Id>{ oi.Id },
      JSON.serialize(draft),
      false
    );
    Test.stopTest();

    System.assertEquals(1, saved.updatedLines);
    System.assertEquals(0, saved.updatedPayments);
    oi = [
      SELECT Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(false, oi.Recurring_Price_Increase_Enabled__c);
  }

  @IsTest
  static void enableRules_enablesWithoutProjecting() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      3,
      Date.today(),
      10
    );

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult enabled = RecurringPriceIncreaseController.enableRules(
      new List<Id>{ oi.Id },
      JSON.serialize(draft),
      false
    );
    Test.stopTest();

    System.assertEquals(1, enabled.updatedLines);
    System.assertEquals(0, enabled.updatedPayments);
    oi = [
      SELECT Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, oi.Recurring_Price_Increase_Enabled__c);
  }

  @isTest
  static void parseDraft_recoversFrequencyAndRejectsBlank() {
    RecurringPriceIncreaseService.RuleDraft seed = new RecurringPriceIncreaseService.RuleDraft();
    seed.frequencyMonths = 4;
    seed.startDate = Date.today();
    seed.increaseType = 'Increase_by_Percentage';
    seed.increasePercent = 0.1;
    String jsonOk = JSON.serialize(seed);
    RecurringPriceIncreaseService.RuleDraft parsed = RecurringPriceIncreaseController.parseDraft(
      jsonOk
    );
    System.assertEquals(4, parsed.frequencyMonths);
    System.assertEquals(Date.today(), parsed.startDate);

    Boolean blankThrew = false;
    try {
      RecurringPriceIncreaseController.parseDraft('');
    } catch (AuraHandledException e) {
      blankThrew = true;
    }
    System.assertEquals(true, blankThrew);

    Boolean badThrew = false;
    try {
      RecurringPriceIncreaseController.parseDraft('{not-json');
    } catch (AuraHandledException e) {
      badThrew = true;
    }
    System.assertEquals(true, badThrew);
  }
}
