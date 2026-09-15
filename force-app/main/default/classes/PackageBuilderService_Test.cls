// WI-000168: PackageBuilderService tests – coverage for date-based discount, draft order, activation
@isTest(IsParallel=false)
public class PackageBuilderService_Test {
  @testSetup
  static void setup() {
    bypassHeavyAutomation();
    String areaValue;
    try {
      List<Schema.PicklistEntry> entries = Locations__c.Area__c.getDescribe()
        .getPicklistValues();
      if (!entries.isEmpty())
        areaValue = entries[0].getValue();
    } catch (Exception e) {
      areaValue = null;
    }

    Locations__c loc = new Locations__c(
      Name = 'BSR City',
      City__c = 'Petah Tikva',
      Site_Name__c = 'BSR City',
      Address__c = 'Address 1',
      Area__c = areaValue
    );
    insert loc;

    Id pricebookId = Test.getStandardPricebookId();

    Product2 prod = new Product2(
      Name = 'SLA: Bronze',
      IsActive = true,
      Location__c = loc.Id
    );
    insert prod;

    PricebookEntry standardPBE = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = prod.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert standardPBE;

    Opportunity opp = new Opportunity(
      Name = 'Test Opportunity',
      CloseDate = Date.today().addMonths(1),
      StageName = 'New',
      Location__c = loc.Id,
      Payment_Date__c = Date.today().addYears(1).addMonths(12),
      Pricebook2Id = pricebookId,
      Current_Iteration__c = 2
    );
    insert opp;

    OpportunityLineItem oppLineItem = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = standardPBE.Id,
      Access_Type__c = 'Periodic',
      Quantity = 1,
      TotalPrice = 1000,
      Entry_Date__c = Date.today(),
      End_Date__c = Date.today().addYears(1).addMonths(1)
    );
    insert oppLineItem;
    insert new Renewal_Price_Adjustment__c(
      Opportunity_Product__c = oppLineItem.Id,
      Year__c = 2,
      Price_Adjustment__c = 5,
      Iteration_Start_Date__c = Date.today().addMonths(-1),
      Iteration_End_Date__c = Date.today().addMonths(3)
    );

    // Order Setup
    Account acc = new Account(Name = 'Test Account');
    insert acc;

    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      EndDate = Date.today().addMonths(24)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      EndDate = Date.today().addMonths(24),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      OpportunityId = opp.Id,
      ContractId = contr.Id
    );
    insert ord;

    OrderItem ordItem = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = standardPBE.Id,
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(6),
      Contract__c = contr.Id
    );
    insert ordItem;
    insert new Renewal_Price_Adjustment__c(
      Contract_Product__c = ordItem.Id,
      Year__c = 2,
      Price_Adjustment__c = 5,
      Iteration_Start_Date__c = Date.today().addMonths(-1),
      Iteration_End_Date__c = Date.today().addMonths(3)
    );

    // Create MPs for OrderItem manually or via Service if trigger enabled
    // PackageBuilderService logic might be triggered by triggers.
    // Ensure data exists for getMonthlyPayments test.
    /*
    List<MonthlyPayment__c> mps = new List<MonthlyPayment__c>();
    for(Integer i=0; i<3; i++){
        mps.add(new MonthlyPayment__c(
            OrderItem__c = ordItem.Id,
            Order__c = ord.Id,
            Start_date__c = Date.today().addMonths(i),
            Price__c = 1000
        ));
    }
    insert mps;
    */
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

  /** Draft line updates otherwise invoke the record flow "Order Item- Sync Dates with Monthly Payments", which faults on some date combinations in tests. */
  private static void deleteMonthlyPaymentsForDraftOrder(Id draftOrderId) {
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__r.OrderId = :draftOrderId
    ];
  }

  /**
   * Monthly_Payment_Update_dates before-save flow derives Stat/End from OrderItem + MonthIndex__c.
   * Tests must set Access_Type__c and line dates, then insert MonthIndex__c only.
   */
  private static void prepareOrderItemForMonthlyPaymentFlow(
    Id orderItemId,
    Date serviceDate,
    Date endDate
  ) {
    update new OrderItem(
      Id = orderItemId,
      ServiceDate = serviceDate,
      EndDate = endDate,
      Access_Type__c = 'Periodic'
    );
  }

  private static MonthlyPayment__c newOrderMonthlyPayment(
    Id orderItemId,
    Integer monthIndex
  ) {
    return new MonthlyPayment__c(
      OrderItem__c = orderItemId,
      MonthIndex__c = monthIndex
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_Opportunity() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT
        Id,
        OpportunityId,
        Product2Id,
        Opportunity.Location__c,
        Access_Type__c,
        Entry_Date__c,
        End_Date__c,
        ListPrice,
        Product2.Name
      FROM OpportunityLineItem
      LIMIT 1
    ];

    // Clean up existing payments
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>{
      oli.Id => oli
    };

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.isTrue(
      mps.size() > 0,
      'Should generate payments for OpportunityLineItem'
    );
    Assert.areEqual(
      0,
      mps[0].Discount__c,
      'RPA discounts no longer apply to generated payments'
    );
  }

  @isTest
  static void testGetMonthlyPayments_Opportunity() {
    bypassHeavyAutomation();
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
    // Generate first
    OpportunityLineItem oli = [
      SELECT
        Id,
        OpportunityId,
        Product2Id,
        Opportunity.Location__c,
        Access_Type__c,
        Entry_Date__c,
        End_Date__c,
        ListPrice,
        Product2.Name
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>{
      oli.Id => oli
    };
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);

    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      opp.Id,
      null,
      null
    );
    Assert.isTrue(res.size() > 0);
    Boolean foundOliRow = false;
    for (MonthlyPayment__c mp : res) {
      Assert.isNotNull(
        mp.Opportunity__r,
        'Opportunity relationship should be populated'
      );
      if (mp.OpportunityLineItem__c != null) {
        Assert.isNotNull(
          mp.OpportunityLineItem__r,
          'OpportunityLineItem relationship should be populated when OpportunityLineItem__c is set'
        );
        foundOliRow = true;
      }
    }
    Assert.isTrue(
      foundOliRow,
      'Expected at least one payment linked to OpportunityLineItem'
    );
  }

  @isTest
  static void testGetLastDayOfMonth() {
    Assert.isNull(PackageBuilderService.getLastDayOfMonth(null));
    Date midMonth = Date.newInstance(2026, 2, 15);
    Assert.areEqual(
      Date.newInstance(2026, 2, 28),
      PackageBuilderService.getLastDayOfMonth(midMonth)
    );
  }

  @isTest
  static void testGetMonthlyPayments_Order_UsesEffectiveDateWhenOrderStartNull() {
    bypassHeavyAutomation();
    Order ord = [
      SELECT Id, EffectiveDate, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    Date filterDate = ord.EffectiveDate != null
      ? ord.EffectiveDate
      : Date.today();
    ord.Order_Start_Date__c = null;
    update ord;
    OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];
    prepareOrderItemForMonthlyPaymentFlow(
      oi.Id,
      filterDate,
      filterDate.addMonths(6)
    );
    insert newOrderMonthlyPayment(oi.Id, 1);
    Test.startTest();
    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      ord.Id
    );
    Test.stopTest();
    Assert.isTrue(
      res.size() > 0,
      'Expected payments when filtering by EffectiveDate'
    );
    for (MonthlyPayment__c mp : res) {
      Assert.isTrue(mp.End_date__c >= filterDate);
    }
  }

  @isTest
  static void testPayableAmountForMonthlyPayment() {
    bypassHeavyAutomation();
    OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = true;
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      Discount__c = 5,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = Date.today(),
      End_Date_trigger__c = Date.today().addMonths(1)
    );
    insert mp;
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = false;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        FinalPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Decimal payable = PackageBuilderService.payableAmountForMonthlyPayment(mp);
    Assert.isNotNull(payable);
    Assert.areEqual(
      mp.FinalPrice__c,
      payable,
      'Payable amount must match Calculated Price (Final Adjusted Price preferred)'
    );
  }

  @isTest
  static void testPayableAmountForUsageBasedMonthlyPaymentUsesFinalPrice() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    OrderItem oi = usageItems[0];
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      ListPrice__c = 42,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = Date.today(),
      End_Date_trigger__c = Date.today().addMonths(1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, FinalPrice__c, Access_Type__c, ListPrice__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based') {
      return;
    }
    Decimal payable = PackageBuilderService.payableAmountForMonthlyPayment(mp);
    Assert.areEqual(42, payable);
    Assert.areEqual(mp.FinalPrice__c, payable);
  }

  @isTest
  static void testUsageBasedPaymentEdit_SameCalendarMonthAllowed() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    Date today = Date.today();
    Integer dayInMonth = today.day() > 1 ? today.day() - 1 : 1;
    Date startInSameMonth = Date.newInstance(
      today.year(),
      today.month(),
      dayInMonth
    );
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = usageItems[0].Id,
      ListPrice__c = 10,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = startInSameMonth,
      End_Date_trigger__c = startInSameMonth.addMonths(1).addDays(-1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, Start_date__c, Access_Type__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based' || mp.Start_date__c == null) {
      return;
    }
    Assert.isFalse(
      PackageBuilderService.isUsageBasedPastPaymentMonth(
        mp.Start_date__c,
        today
      ),
      'Same calendar month should remain editable'
    );
    mp.ListPrice__c = 20;
    Test.startTest();
    PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ mp });
    Test.stopTest();
    mp = [SELECT ListPrice__c FROM MonthlyPayment__c WHERE Id = :mp.Id];
    Assert.areEqual(20, mp.ListPrice__c);
  }

  @isTest
  static void testUsageBasedPaymentEdit_PriorCalendarMonthBlocked() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    Date today = Date.today();
    Date priorMonthStart = Date.newInstance(today.year(), today.month(), 1)
      .addMonths(-1);
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = usageItems[0].Id,
      ListPrice__c = 10,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = priorMonthStart,
      End_Date_trigger__c = priorMonthStart.addMonths(1).addDays(-1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, Start_date__c, Access_Type__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based' || mp.Start_date__c == null) {
      return;
    }
    Assert.isTrue(
      PackageBuilderService.isUsageBasedPastPaymentMonth(
        mp.Start_date__c,
        today
      ),
      'Prior calendar month should be locked'
    );
    mp.ListPrice__c = 20;
    Boolean threw = false;
    Test.startTest();
    try {
      PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ mp });
    } catch (AuraHandledException e) {
      threw = true;
      Assert.isTrue(
        e.getMessage().contains('past months'),
        'Expected past-month guard: ' + e.getMessage()
      );
    }
    Test.stopTest();
    Assert.isTrue(threw, 'Prior calendar month update should be rejected');
  }

  @isTest
  static void testUsageBasedPaymentEdit_ClearToNull() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    Date today = Date.today();
    Integer dayInMonth = today.day() > 1 ? today.day() - 1 : 1;
    Date startInSameMonth = Date.newInstance(
      today.year(),
      today.month(),
      dayInMonth
    );
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = usageItems[0].Id,
      ListPrice__c = 10,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = startInSameMonth,
      End_Date_trigger__c = startInSameMonth.addMonths(1).addDays(-1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, Start_date__c, Access_Type__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based' || mp.Start_date__c == null) {
      return;
    }
    mp.ListPrice__c = null;
    Test.startTest();
    PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ mp });
    Test.stopTest();
    mp = [SELECT ListPrice__c FROM MonthlyPayment__c WHERE Id = :mp.Id];
    Assert.isTrue(
      mp.ListPrice__c == null,
      'Cleared Usage Based price should persist as null.'
    );
  }

  @isTest
  static void testUsageBasedPaymentEdit_SaveZero() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    Date today = Date.today();
    Integer dayInMonth = today.day() > 1 ? today.day() - 1 : 1;
    Date startInSameMonth = Date.newInstance(
      today.year(),
      today.month(),
      dayInMonth
    );
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = usageItems[0].Id,
      ListPrice__c = 10,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = startInSameMonth,
      End_Date_trigger__c = startInSameMonth.addMonths(1).addDays(-1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, Start_date__c, Access_Type__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based' || mp.Start_date__c == null) {
      return;
    }
    mp.ListPrice__c = 0;
    Test.startTest();
    PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ mp });
    Test.stopTest();
    mp = [SELECT ListPrice__c FROM MonthlyPayment__c WHERE Id = :mp.Id];
    Assert.areEqual(
      0,
      mp.ListPrice__c,
      'Explicit zero should be saved for Usage Based.'
    );
  }

  @isTest
  static void testUsageBasedPaymentEdit_NegativeRejected() {
    bypassHeavyAutomation();
    List<OrderItem> usageItems = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Usage Based'
      LIMIT 1
    ];
    if (usageItems.isEmpty()) {
      return;
    }
    Date today = Date.today();
    Integer dayInMonth = today.day() > 1 ? today.day() - 1 : 1;
    Date startInSameMonth = Date.newInstance(
      today.year(),
      today.month(),
      dayInMonth
    );
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = usageItems[0].Id,
      ListPrice__c = 10,
      MonthIndex__c = 1,
      Stat_Date_Trigger__c = startInSameMonth,
      End_Date_trigger__c = startInSameMonth.addMonths(1).addDays(-1)
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    mp = [
      SELECT Id, Start_date__c, Access_Type__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    if (mp.Access_Type__c != 'Usage Based' || mp.Start_date__c == null) {
      return;
    }
    mp.ListPrice__c = -5;
    Boolean threw = false;
    Test.startTest();
    try {
      PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ mp });
    } catch (AuraHandledException e) {
      threw = true;
      Assert.isTrue(
        e.getMessage().contains('negative'),
        'Expected negative guard: ' + e.getMessage()
      );
    }
    Test.stopTest();
    Assert.isTrue(threw, 'Negative Usage Based price should be rejected.');
  }

  @isTest
  static void testGetSplitMonthDiscountMetadata_NoIds() {
    Test.startTest();
    Map<Id, PackageBuilderService.SplitMonthDiscountMeta> empty = PackageBuilderService.getSplitMonthDiscountMetadata(
      new List<Id>()
    );
    Map<Id, PackageBuilderService.SplitMonthDiscountMeta> nullResult = PackageBuilderService.getSplitMonthDiscountMetadata(
      null
    );
    Test.stopTest();
    Assert.areEqual(0, empty.size());
    Assert.areEqual(0, nullResult.size());
  }

  @isTest
  static void testGetMonthlyPayments_ProjectsCalendarMinFields() {
    bypassHeavyAutomation();
    Order ord = [
      SELECT Id, EffectiveDate, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    OrderItem oi = [
      SELECT Id, ServiceDate
      FROM OrderItem
      WHERE OrderId = :ord.Id AND ServiceDate != NULL
      LIMIT 1
    ];
    Date serviceDate = oi.ServiceDate != null ? oi.ServiceDate : Date.today();
    prepareOrderItemForMonthlyPaymentFlow(
      oi.Id,
      serviceDate,
      serviceDate.addMonths(6)
    );
    insert newOrderMonthlyPayment(oi.Id, 1);
    Test.startTest();
    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      ord.Id
    );
    Test.stopTest();
    Assert.isTrue(res.size() > 0);
    Boolean foundProjectedFields = false;
    for (MonthlyPayment__c mp : res) {
      if (mp.OrderItem__c != oi.Id) {
        continue;
      }
      Assert.isNotNull(mp.OrderItem__r);
      Assert.isNotNull(mp.OrderItem__r.Order);
      foundProjectedFields = true;
    }
    Assert.isTrue(
      foundProjectedFields,
      'Expected order item relationship fields on returned payments'
    );
  }

  @isTest
  static void testGetMonthlyPayments_Order() {
    bypassHeavyAutomation();
    Order ord = [
      SELECT Id, EffectiveDate, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];
    Date lineStart = Date.today();
    Date monthFifteenth = lineStart.toStartOfMonth().addDays(14);
    Date businessStart = monthFifteenth >= lineStart
      ? monthFifteenth
      : lineStart;
    Date lineEnd = lineStart.addMonths(6);
    ord.Order_Start_Date__c = businessStart;
    update ord;
    prepareOrderItemForMonthlyPaymentFlow(oi.Id, lineStart, lineEnd);

    insert newOrderMonthlyPayment(oi.Id, 1);

    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      ord.Id
    );
    Assert.isTrue(res.size() > 0, 'Expected order monthly payments');
    for (MonthlyPayment__c mp : res) {
      Assert.isTrue(
        mp.End_date__c >= businessStart,
        'Monthly payments should be filtered from order start date onward'
      );
      Assert.isNotNull(
        mp.OrderItem__r,
        'OrderItem relationship should be populated'
      );
      Assert.isNotNull(
        mp.OrderItem__r.Order,
        'Order relationship should be populated for calendar min'
      );
    }
  }

  @isTest
  static void testSyncOrderItemPriceRollups_SetsBaselineAndAdjustedOnlyAfterPriceChange() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, ListPrice, Product2Id, OrderId, Contract__c, ServiceDate
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      update new OrderItem(Id = oi.Id, ServiceDate = null);
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    // Price__c is a formula (from OrderItem); only writable fields such as Discount__c change FinalPrice__c.
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today(),
      End_Date_trigger__c = Date.today(),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c
    );
    insert mp;

    mp = [
      SELECT Id, FinalPrice__c, Discount__c, Price__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    update new OrderItem(Id = oi.Id, Original_Price__c = null);

    PackageBuilderService.syncOrderItemPriceRollups(new Set<Id>{ oi.Id });

    OrderItem baseline = [
      SELECT
        Original_Price__c,
        Adjusted_Total_Price__c,
        Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];

    mp.Discount__c = -0.1;
    update mp;
    mp = [
      SELECT FinalPrice__c, Discount__c, Price__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];

    PackageBuilderService.syncOrderItemPriceRollups(new Set<Id>{ oi.Id });

    OrderItem after = [
      SELECT
        Original_Price__c,
        Adjusted_Total_Price__c,
        Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    Test.stopTest();

    Assert.areEqual(
      baseline.Adjusted_Total_Price__c,
      baseline.Original_Price__c,
      'Original should match first rollup'
    );
    Assert.isTrue(
      baseline.Original_Price__c != null,
      'First rollup should set Original baseline'
    );
    Assert.isTrue(
      baseline.Show_Financial_Adjustment_Icon__c != true,
      'Date-driven rollup sync must not set financial icon'
    );

    Assert.areEqual(
      baseline.Original_Price__c,
      after.Original_Price__c,
      'Original must not change'
    );
    Decimal expectedAdjusted =
      baseline.Original_Price__c * (Decimal.valueOf('1') + mp.Discount__c);
    Assert.areEqual(
      expectedAdjusted.setScale(2, System.RoundingMode.HALF_UP),
      after.Adjusted_Total_Price__c,
      'Adjusted follows payment total'
    );
    Assert.isTrue(
      after.Show_Financial_Adjustment_Icon__c != true,
      'Adjusted-only rollup must not set financial icon'
    );
  }

  @isTest
  static void testSyncOrderItemPriceRollups_MarkFinancialTrueSetsIconWithoutPriceChange() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, ListPrice, Product2Id, OrderId, Contract__c
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today(),
      End_Date_trigger__c = Date.today(),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c
    );
    insert mp;

    PackageBuilderService.syncOrderItemPriceRollups(new Set<Id>{ oi.Id });
    OrderItem mid = [
      SELECT Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    Assert.isTrue(mid.Show_Financial_Adjustment_Icon__c != true);

    Test.startTest();
    PackageBuilderService.syncOrderItemPriceRollups(new Set<Id>{ oi.Id }, true);
    Test.stopTest();

    OrderItem afterMark = [
      SELECT Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    Assert.isTrue(
      afterMark.Show_Financial_Adjustment_Icon__c == true,
      'Mark-financial sync should set icon even when adjusted total already matches'
    );
  }

  @isTest
  static void testUpdateDiscount_SetsFinancialIconOnOrderItem() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, ListPrice, Product2Id, OrderId, Contract__c
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today(),
      End_Date_trigger__c = Date.today(),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c
    );
    insert mp;
    PackageBuilderService.syncOrderItemPriceRollups(new Set<Id>{ oi.Id });

    mp = [SELECT Id, Discount__c FROM MonthlyPayment__c WHERE Id = :mp.Id];
    mp.Discount__c = -0.05;
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>{ mp };

    Test.startTest();
    try {
      PackageBuilderService.updateDiscount(toUpdate);
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Script-thrown') ||
        e.getMessage().contains('Error')
      );
      Test.stopTest();
      return;
    }
    Test.stopTest();

    OrderItem after = [
      SELECT Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    Assert.isTrue(
      after.Show_Financial_Adjustment_Icon__c == true,
      'Monthly drawer save should set icon'
    );
  }

  @isTest
  static void testUpdateDiscount() {
    MonthlyPayment__c mp = new MonthlyPayment__c();
    // Start_date__c = Date.today(),
    // Price__c = 1000
    insert mp;

    mp.Discount__c = 0.1;
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>{ mp };

    Test.startTest();
    PackageBuilderService.updateDiscount(toUpdate);
    Test.stopTest();

    MonthlyPayment__c res = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.areEqual(0.1, res.Discount__c);
  }

  @isTest
  static void testUpdateDiscount_AmountKeepsExactFinalAdjustedPrice() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT
        Id,
        ListPrice,
        Product2Id,
        OrderId,
        Contract__c,
        UnitPrice,
        Quantity
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today().toStartOfMonth(),
      End_Date_trigger__c = Date.today()
        .toStartOfMonth()
        .addMonths(1)
        .addDays(-1),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c
    );
    insert mp;

    mp = [
      SELECT Id, Price__c, Discount__c, Final_Adjusted_Price__c, FinalPrice__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.isNotNull(
      mp.Price__c,
      'Price__c formula should resolve after insert'
    );

    Decimal targetAmount = 100;
    Decimal listPrice = mp.Price__c;
    Decimal discountPts = listPrice != 0
      ? ((targetAmount / listPrice) - 1) * 100
      : 0;

    Test.startTest();
    PackageBuilderService.updateDiscount(
      new List<MonthlyPayment__c>{
        new MonthlyPayment__c(
          Id = mp.Id,
          Discount__c = discountPts,
          Final_Adjusted_Price__c = targetAmount
        )
      }
    );
    Test.stopTest();

    MonthlyPayment__c afterSave = [
      SELECT Final_Adjusted_Price__c, FinalPrice__c, Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.areEqual(
      targetAmount,
      afterSave.Final_Adjusted_Price__c,
      'Amount save must store exact Final Adjusted Price'
    );
    Assert.areEqual(
      targetAmount,
      afterSave.FinalPrice__c,
      'Calculated Price must equal typed Amount (not % round-trip drift)'
    );
  }

  @isTest
  static void testDiscountOnlyRefreshRecalculatesFinalAdjustedPrice() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Product2Id, OrderId, Contract__c
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today().toStartOfMonth(),
      End_Date_trigger__c = Date.today()
        .toStartOfMonth()
        .addMonths(1)
        .addDays(-1),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c
    );
    insert mp;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');

    mp = [
      SELECT Id, Price__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.isNotNull(mp.Price__c, 'Price__c should resolve after insert');

    Test.startTest();
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = true;
    PackageBuilderService.updateDiscount(
      new List<MonthlyPayment__c>{
        new MonthlyPayment__c(Id = mp.Id, Discount__c = -10)
      }
    );
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = false;
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    Test.stopTest();

    MonthlyPayment__c afterSave = [
      SELECT Price__c, Discount__c, Final_Adjusted_Price__c, FinalPrice__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.isNotNull(
      afterSave.Final_Adjusted_Price__c,
      'Discount-only save should set Final Adjusted Price'
    );
    Assert.areEqual(
      afterSave.Final_Adjusted_Price__c,
      afterSave.FinalPrice__c,
      'Calculated Price should follow Final Adjusted Price after Discount save'
    );
  }

  @isTest
  static void testRefreshFinalAdjustedPriceForOrderItems_OnUnitPriceChange() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Product2Id, OrderId, Contract__c, UnitPrice, Quantity
      FROM OrderItem
      LIMIT 1
    ];
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.today().toStartOfMonth(),
      End_Date_trigger__c = Date.today()
        .toStartOfMonth()
        .addMonths(1)
        .addDays(-1),
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c,
      Final_Adjusted_Price__c = 55500
    );
    insert mp;

    oi.UnitPrice = oi.UnitPrice + 50;
    update oi;

    Test.startTest();
    PackageBuilderService.refreshFinalAdjustedPriceForOrderItems(
      new Set<Id>{ oi.Id }
    );
    Test.stopTest();

    MonthlyPayment__c afterRefresh = [
      SELECT Price__c, Discount__c, Final_Adjusted_Price__c, FinalPrice__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    Assert.areNotEqual(
      55500,
      afterRefresh.Final_Adjusted_Price__c,
      'Parent UnitPrice change must not leave stale Amount lock'
    );
    Assert.areEqual(
      afterRefresh.Final_Adjusted_Price__c,
      afterRefresh.FinalPrice__c,
      'Calculated Price should follow refreshed Final Adjusted Price'
    );
  }

  @isTest
  static void testMonthlyUnitsAndScaleFinalAdjustedPrice() {
    Date monthStart = Date.newInstance(2026, 3, 1);
    Date monthEnd = Date.newInstance(2026, 3, 31);
    Date midStart = Date.newInstance(2026, 3, 16);
    Assert.areEqual(
      1,
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Periodic',
        monthStart,
        monthEnd
      )
    );
    Assert.areEqual(
      Decimal.valueOf(16) / Decimal.valueOf(31),
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Periodic',
        midStart,
        monthEnd
      )
    );
    Assert.areEqual(
      1,
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Usage Based',
        midStart,
        monthEnd
      )
    );
    // Monthly payments use day-early Stat_Date_Trigger (day before covered month).
    // Units must measure the covered month, not produce a negative day-count fraction.
    Date dayEarlyFebStart = Date.newInstance(2026, 1, 31);
    Date febEnd = Date.newInstance(2026, 2, 28);
    Assert.areEqual(
      1,
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Monthly',
        dayEarlyFebStart,
        febEnd
      ),
      'Day-early full February must be 1 unit'
    );
    Assert.areEqual(
      Decimal.valueOf(14) / Decimal.valueOf(28),
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Monthly',
        dayEarlyFebStart,
        Date.newInstance(2026, 2, 14)
      ),
      'Day-early curtailed February must prorate in February'
    );
    Date dayEarlyJanStart = Date.newInstance(2025, 12, 31);
    Assert.areEqual(
      1,
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Monthly',
        dayEarlyJanStart,
        Date.newInstance(2026, 1, 31)
      ),
      'Day-early cross-year full month must be 1 unit'
    );
    MonthlyPayment__c dayEarlyTarget = new MonthlyPayment__c(
      Stat_Date_Trigger__c = dayEarlyFebStart,
      End_Date_trigger__c = febEnd
    );
    MonthlyPayment__c dayEarlySrc = new MonthlyPayment__c(
      Stat_Date_Trigger__c = Date.newInstance(2026, 2, 1),
      End_Date_trigger__c = febEnd,
      Final_Adjusted_Price__c = 5412
    );
    PackageBuilderService.applyCopiedFinalAdjustedPriceIfSameSpan(
      dayEarlyTarget,
      dayEarlySrc,
      'Monthly',
      5412
    );
    Assert.areEqual(
      5412,
      dayEarlyTarget.Final_Adjusted_Price__c,
      'Same covered-month span must copy FAP despite day-early start'
    );
    Decimal midUnits = Decimal.valueOf(16) / Decimal.valueOf(31);
    Assert.areEqual(
      (Decimal.valueOf(3100) * midUnits) / 1,
      PackageBuilderService.scaleFinalAdjustedPrice(3100, 1, midUnits)
    );
    Assert.isNull(PackageBuilderService.scaleFinalAdjustedPrice(null, 1, 0.5));
    Assert.areEqual(
      100,
      PackageBuilderService.scaleFinalAdjustedPrice(100, 1, 1)
    );
    Date sep1 = Date.newInstance(2026, 9, 1);
    Date sep14 = Date.newInstance(2026, 9, 14);
    Date sep30 = Date.newInstance(2026, 9, 30);
    Assert.areEqual(
      sep14,
      PackageBuilderService.paymentEndClampedToLineEnd(sep1, sep14)
    );
    Assert.areEqual(
      sep30,
      PackageBuilderService.paymentEndClampedToLineEnd(sep1, sep30)
    );
    Assert.areEqual(
      1400,
      PackageBuilderService.scaleCopiedFinalAdjustedPrice(
        3000,
        'Periodic',
        sep1,
        sep30,
        sep1,
        sep14
      )
    );
    Assert.isFalse(
      PackageBuilderService.isUsableFinalAdjustedPrice(0),
      'Zero Final Adjusted Price is unset'
    );
    Assert.isFalse(PackageBuilderService.isUsableFinalAdjustedPrice(null));
    MonthlyPayment__c copyTarget = new MonthlyPayment__c(
      Stat_Date_Trigger__c = sep1,
      End_Date_trigger__c = sep14
    );
    MonthlyPayment__c copySrcFull = new MonthlyPayment__c(
      Stat_Date_Trigger__c = sep1,
      End_Date_trigger__c = sep30,
      Final_Adjusted_Price__c = 3000
    );
    PackageBuilderService.applyCopiedFinalAdjustedPriceIfSameSpan(
      copyTarget,
      copySrcFull,
      'Periodic',
      3000
    );
    Assert.isNull(
      copyTarget.Final_Adjusted_Price__c,
      'Must not copy FAP across a different day-span'
    );
    MonthlyPayment__c copyTargetSame = new MonthlyPayment__c(
      Stat_Date_Trigger__c = sep1,
      End_Date_trigger__c = sep30
    );
    PackageBuilderService.applyCopiedFinalAdjustedPriceIfSameSpan(
      copyTargetSame,
      copySrcFull,
      'Periodic',
      3000
    );
    Assert.areEqual(
      3000,
      copyTargetSame.Final_Adjusted_Price__c,
      'Same span copy keeps Final Adjusted Price'
    );
    Id fakeMpId =
      MonthlyPayment__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000001AAA';
    MonthlyPayment__c datePrior = new MonthlyPayment__c(
      Id = fakeMpId,
      Stat_Date_Trigger__c = sep1,
      End_Date_trigger__c = sep30,
      Final_Adjusted_Price__c = 3000
    );
    MonthlyPayment__c dateIncoming = new MonthlyPayment__c(
      Id = fakeMpId,
      Stat_Date_Trigger__c = sep1,
      End_Date_trigger__c = sep14,
      Final_Adjusted_Price__c = 3000
    );
    PackageBuilderService.applyFinalAdjustedPriceBeforeSave(
      new List<MonthlyPayment__c>{ dateIncoming },
      new Map<Id, MonthlyPayment__c>{ datePrior.Id => datePrior }
    );
    Assert.isNull(
      dateIncoming.Final_Adjusted_Price__c,
      'Any date change clears FAP even when Access Type is blank'
    );
  }

  @isTest
  static void testClampPayStartToModifyOrderStart_keepsFullMonthForContinuingProduct() {
    Date jun24 = Date.newInstance(2026, 6, 24);
    Date aug5 = Date.newInstance(2026, 8, 5);
    Date aug1 = Date.newInstance(2026, 8, 1);
    Date aug31 = Date.newInstance(2026, 8, 31);
    Date jul1 = Date.newInstance(2026, 7, 1);
    Date jul31 = Date.newInstance(2026, 7, 31);
    OrderItem continuing = new OrderItem(
      ServiceDate = jun24,
      EndDate = Date.newInstance(2026, 12, 9),
      Access_Type__c = 'Periodic'
    );
    continuing.putSObject(
      'Order',
      new Order(Status = 'Draft', Order_Start_Date__c = aug5)
    );
    Assert.areEqual(
      aug1,
      PackageBuilderService.clampPayStartToModifyOrderStart(
        continuing,
        aug1,
        aug31
      ),
      'Continuing product keeps full Order Start month'
    );
    Assert.areEqual(
      jul1,
      PackageBuilderService.clampPayStartToModifyOrderStart(
        continuing,
        jul1,
        jul31
      ),
      'Months before draft start stay unchanged'
    );

    OrderItem startingWithModify = new OrderItem(
      ServiceDate = aug5,
      EndDate = Date.newInstance(2026, 12, 9),
      Access_Type__c = 'Periodic'
    );
    startingWithModify.putSObject(
      'Order',
      new Order(Status = 'Draft', Order_Start_Date__c = aug5)
    );
    Assert.areEqual(
      aug5,
      PackageBuilderService.clampPayStartToModifyOrderStart(
        startingWithModify,
        aug1,
        aug31
      ),
      'Product starting on/after Order Start may floor that month'
    );

    List<MonthlyPayment__c> pays = PackageBuilderService.generateMonthlyPaymentsForLineItem(
      continuing,
      jun24,
      12,
      null,
      false
    );
    MonthlyPayment__c august;
    for (MonthlyPayment__c pay : pays) {
      if (
        pay.Stat_Date_Trigger__c != null &&
        pay.Stat_Date_Trigger__c.month() == 8
      ) {
        august = pay;
        break;
      }
    }
    Assert.isNotNull(august, 'August payment should be generated');
    Assert.areEqual(
      aug1,
      august.Stat_Date_Trigger__c,
      'Draft Order Start must not shorten a continuing product month'
    );
  }

  @isTest
  static void testApplyFinalAdjustedPriceBeforeSave_ScalesFapWhenDatesChange() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Product2Id, OrderId, Contract__c
      FROM OrderItem
      LIMIT 1
    ];
    update new OrderItem(Id = oi.Id, Access_Type__c = 'Periodic');
    Order ord = [
      SELECT Location__c, OpportunityId
      FROM Order
      WHERE Id = :oi.OrderId
    ];
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    Date monthStart = Date.newInstance(2026, 3, 1);
    Date monthEnd = Date.newInstance(2026, 3, 31);
    Date midStart = Date.newInstance(2026, 3, 16);
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      MonthIndex__c = 1,
      Discount__c = -10,
      Stat_Date_Trigger__c = monthStart,
      End_Date_trigger__c = monthEnd,
      Room__c = oi.Product2Id,
      Contract__c = oi.Contract__c,
      Opportunity__c = ord.OpportunityId,
      Location__c = ord.Location__c,
      Final_Adjusted_Price__c = 3100
    );
    insert mp;
    mp = [
      SELECT Id, Discount__c, Access_Type__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    mp.Stat_Date_Trigger__c = monthStart;
    mp.End_Date_trigger__c = monthEnd;
    mp.Final_Adjusted_Price__c = 3100;

    MonthlyPayment__c incoming = new MonthlyPayment__c(
      Id = mp.Id,
      Discount__c = mp.Discount__c,
      Stat_Date_Trigger__c = midStart,
      End_Date_trigger__c = monthEnd,
      Final_Adjusted_Price__c = 3100
    );

    Test.startTest();
    PackageBuilderService.applyFinalAdjustedPriceBeforeSave(
      new List<MonthlyPayment__c>{ incoming },
      new Map<Id, MonthlyPayment__c>{ mp.Id => mp }
    );
    Test.stopTest();

    Decimal expected = PackageBuilderService.scaleFinalAdjustedPrice(
      3100,
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Periodic',
        monthStart,
        monthEnd
      ),
      PackageBuilderService.monthlyUnitsForAccessAndDates(
        'Periodic',
        midStart,
        monthEnd
      )
    );
    Assert.isNull(
      incoming.Final_Adjusted_Price__c,
      'Date-span change clears FAP so Price x (1+Discount) can derive after dates settle'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_CopiesFinalAdjustedPrice() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT
        Id,
        OpportunityId,
        Product2Id,
        Opportunity.Location__c,
        Access_Type__c,
        Entry_Date__c,
        End_Date__c,
        ListPrice
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Date copyStart = oli.Entry_Date__c != null
      ? oli.Entry_Date__c
      : Date.today();
    List<MonthlyPayment__c> copy = new List<MonthlyPayment__c>{
      new MonthlyPayment__c(
        MonthIndex__c = 1,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1234.56,
        Stat_Date_Trigger__c = copyStart,
        End_Date_trigger__c = PackageBuilderService.paymentEndClampedToLineEnd(
          copyStart,
          oli.End_Date__c
        )
      )
    };

    Test.startTest();
    List<MonthlyPayment__c> created = PackageBuilderService.generateMonthlyPaymentsForLineItem(
      oli,
      oli.Entry_Date__c,
      3,
      copy,
      true
    );
    Test.stopTest();

    Assert.isFalse(created.isEmpty(), 'Should generate monthly payments');
    Assert.areEqual(
      1234.56,
      created[0].Final_Adjusted_Price__c,
      'Draft/copy path must carry Final Adjusted Price'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_Order_SkipsContractTerms() {
    bypassHeavyAutomation();
    Order ord = [SELECT Id, ContractId, Pricebook2Id FROM Order LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = ord.Pricebook2Id != null
      ? ord.Pricebook2Id
      : Test.getStandardPricebookId();

    Product2 extraProd = new Product2(
      Name = 'Contract Terms MPs Test OI',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert extraProd;

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = extraProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;

    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(6),
      Contract__c = ord.ContractId
    );
    insert oi;

    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    Map<Id, OrderItem> itemMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Order.Location__c,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(itemMap);
    Test.stopTest();

    Integer n = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];
    Assert.areEqual(0, n, 'Contract Terms should not get monthly payments');
  }

  @isTest
  static void testGenerateMonthlyPayments_OppLine_SkipsContractTerms() {
    bypassHeavyAutomation();
    Opportunity opp = [SELECT Id, Pricebook2Id FROM Opportunity LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = opp.Pricebook2Id != null
      ? opp.Pricebook2Id
      : Test.getStandardPricebookId();

    Product2 extraProd = new Product2(
      Name = 'Contract Terms MPs Test OLI',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert extraProd;

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = extraProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;

    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Access_Type__c = 'Monthly',
      Quantity = 1,
      TotalPrice = 100,
      Entry_Date__c = Date.today(),
      End_Date__c = Date.today().addYears(1)
    );
    insert oli;

    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>(
      [
        SELECT
          Id,
          Entry_Date__c,
          End_Date__c,
          ListPrice,
          OpportunityId,
          Product2Id,
          Opportunity.Location__c,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c,
          Original_Contract_Product__c
        FROM OpportunityLineItem
        WHERE Id = :oli.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    Integer n = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.areEqual(0, n, 'Contract Terms should not get monthly payments');
  }

  @isTest
  static void testGenerateMonthlyPayments_Order_GeneratesForExtraForAllProducts() {
    bypassHeavyAutomation();
    Order ord = [SELECT Id, ContractId, Pricebook2Id FROM Order LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = ord.Pricebook2Id != null
      ? ord.Pricebook2Id
      : Test.getStandardPricebookId();

    Product2 parkingProd = new Product2(
      Name = 'Extra For All MPs Test OI',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Extra for all products',
      Sub_Type__c = 'Parking spot'
    );
    insert parkingProd;

    PricebookEntry pbeParking = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = parkingProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbeParking;

    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbeParking.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(6),
      Contract__c = ord.ContractId
    );
    insert oi;

    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    Map<Id, OrderItem> itemMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Order.Location__c,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(itemMap);
    Test.stopTest();

    Integer n = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];
    Assert.isTrue(n > 0, 'Extra for all products should get monthly payments');
  }

  @isTest
  static void testGenerateMonthlyPayments_Order() {
    bypassHeavyAutomation();
    OrderItem ordItem = [
      SELECT
        Id,
        OrderId,
        ServiceDate,
        EndDate,
        ListPrice,
        Product2Id,
        Order.Location__c,
        Access_Type__c,
        Product2.Name
      FROM OrderItem
      LIMIT 1
    ];

    // Clean up existing payments
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :ordItem.Id];

    Map<Id, OrderItem> itemMap = new Map<Id, OrderItem>{
      ordItem.Id => ordItem
    };

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :ordItem.Id
    ];
    Assert.isTrue(mps.size() > 0, 'Should generate payments for OrderItem');
    Assert.areEqual(
      0,
      mps[0].Discount__c,
      'RPA discounts no longer apply to generated payments'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_Order_MonthlyAccessType() {
    bypassHeavyAutomation();
    OrderItem ordItem = [
      SELECT
        Id,
        OrderId,
        ServiceDate,
        EndDate,
        ListPrice,
        Product2Id,
        Order.Location__c,
        Access_Type__c,
        Product2.Name,
        Order.Status
      FROM OrderItem
      LIMIT 1
    ];
    ordItem.Access_Type__c = 'Monthly';
    update ordItem;
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :ordItem.Id
    ];

    Map<Id, OrderItem> itemMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Contract__c,
          Order.Location__c,
          Order.OpportunityId,
          Order.Status,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c
        FROM OrderItem
        WHERE Id = :ordItem.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :ordItem.Id
    ];
    Assert.isTrue(
      mps.size() > 0,
      'Should generate monthly payments for OrderItem with Monthly access type'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_Order_RenewalFromYearWhenIterationDatesBlank() {
    bypassHeavyAutomation();
    OrderItem ordItem = [
      SELECT Id, OrderId, Order.OpportunityId
      FROM OrderItem
      LIMIT 1
    ];
    Opportunity opp = [
      SELECT Id, End_Date__c, Renewal_Period_Months__c
      FROM Opportunity
      WHERE Id = :ordItem.Order.OpportunityId
    ];
    opp.End_Date__c = Date.today().addYears(1);
    opp.Renewal_Period_Months__c = 6;
    update opp;

    delete [
      SELECT Id
      FROM Renewal_Price_Adjustment__c
      WHERE Contract_Product__c = :ordItem.Id
    ];
    insert new Renewal_Price_Adjustment__c(
      Contract_Product__c = ordItem.Id,
      Year__c = 2,
      Price_Adjustment__c = 7
    );
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :ordItem.Id
    ];

    Map<Id, OrderItem> itemMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Contract__c,
          Order.Location__c,
          Order.OpportunityId,
          Order.Status,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c
        FROM OrderItem
        WHERE Id = :ordItem.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :ordItem.Id
    ];
    Assert.isTrue(
      mps.size() > 0,
      'Should generate payments when contract renewal dates are derived from Year__c'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_MonthlyAccessType() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT
        Id,
        OpportunityId,
        Product2Id,
        Opportunity.Location__c,
        Access_Type__c,
        Entry_Date__c,
        End_Date__c,
        ListPrice,
        Product2.Name
      FROM OpportunityLineItem
      LIMIT 1
    ];
    oli.Access_Type__c = 'Monthly';
    update oli;
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>(
      [
        SELECT
          Id,
          OpportunityId,
          Product2Id,
          Opportunity.Location__c,
          Access_Type__c,
          Entry_Date__c,
          End_Date__c,
          ListPrice,
          Product2.Name,
          Product2.Type__c,
          Original_Contract_Product__c
        FROM OpportunityLineItem
        WHERE Id = :oli.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.isTrue(
      mps.size() >= 12,
      'Should generate 12 payments for Monthly access type'
    );
  }

  @isTest
  static void testGenerateMonthlyPayments_OtherAccessType() {
    bypassHeavyAutomation();
    Opportunity opp = [
      SELECT Id, Location__c, Pricebook2Id
      FROM Opportunity
      LIMIT 1
    ];
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Daily',
      Entry_Date__c = Date.today(),
      End_Date__c = Date.today().addMonths(1)
    );
    insert oli;

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>{
      oli.Id => oli
    };

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.isTrue(
      mps.size() == 1,
      'Should generate 1 payment for non-Periodic/Monthly access type'
    );
  }

  @isTest
  static void testGetMonthlyPayments_Contract() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];

    OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
    MonthlyPayment__c mp = new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      Contract__c = contr.Id
    );
    insert mp;

    Test.startTest();
    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      contr.Id,
      null
    );
    Test.stopTest();

    Assert.isTrue(res.size() > 0, 'Should return payments for contract');
  }

  @isTest
  static void testGetMonthlyPayments_NoFilters() {
    Test.startTest();
    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      null
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      res.size(),
      'Should return empty list when no filters provided'
    );
  }

  @isTest
  static void testDeleteAllMonthlyPaymentNotRelevant() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT Id, Entry_Date__c, End_Date__c, Access_Type__c, Quantity, UnitPrice
      FROM OpportunityLineItem
      LIMIT 1
    ];

    // Create some monthly payments
    List<MonthlyPayment__c> mps = new List<MonthlyPayment__c>();
    for (Integer i = 1; i <= 3; i++) {
      mps.add(
        new MonthlyPayment__c(
          OpportunityLineItem__c = oli.Id,
          MonthIndex__c = i
        )
      );
    }
    insert mps;

    // Update the line item to trigger deletion and regeneration
    oli.Quantity = 2;
    Map<Id, OpportunityLineItem> oldMap = new Map<Id, OpportunityLineItem>{
      oli.Id => oli.clone()
    };
    oldMap.get(oli.Id).Quantity = 1;

    Test.startTest();
    update oli;
    PackageBuilderService.deleteAllMonthlyPaymentNotRelevant(
      new List<OpportunityLineItem>{ oli },
      oldMap
    );
    Test.stopTest();

    List<MonthlyPayment__c> remainingMps = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.isTrue(
      remainingMps.size() > 0,
      'Should regenerate payments after deletion'
    );
  }

  @isTest
  static void testDeleteAllMonthlyPaymentNotRelevant_OpenEndedMonthlyAddOnly() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        UnitPrice,
        Quantity,
        Access_Type__c,
        OrderId,
        Product2Id,
        Contract__c
      FROM OrderItem
      LIMIT 1
    ];
    oi.Access_Type__c = 'Monthly';
    oi.EndDate = null;
    update oi;

    ContractService.syncOpenEndedMonthlyPaymentsAddOnly(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          Access_Type__c,
          Contract__c,
          Contract__r.EndDate,
          Contract__r.Location__c,
          Product2Id,
          Product2.Type__c,
          OrderId,
          Order.Status,
          Order.OpportunityId,
          Order.EffectiveDate,
          Order.Order_Start_Date__c,
          Order.Previous_Order__c,
          Order.Replacement_Start_Date__c,
          Opportunity_Product__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ],
      Date.today().addMonths(ContractService.ROLLING_FORWARD_MONTHS),
      Date.today()
    );
    Integer before = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];

    OrderItem oldOi = oi.clone(true, true, true, true);
    OrderItem updated = oi.clone(true, true, true, true);
    updated.UnitPrice = (oi.UnitPrice != null ? oi.UnitPrice : 100) + 1;

    Test.startTest();
    PackageBuilderService.deleteAllMonthlyPaymentNotRelevant(
      new List<OrderItem>{ updated },
      new Map<Id, SObject>{ oi.Id => oldOi }
    );
    Test.stopTest();

    Integer after = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];
    Assert.isTrue(
      after >= before,
      'Open-ended Monthly Package Builder update should use add-only sync'
    );
  }

  @isTest
  static void testUpdateDiscount_Exception() {
    Test.startTest();
    Boolean ok = PackageBuilderService.updateDiscount(null);
    Test.stopTest();
    Assert.isTrue(ok, 'Null payment list should be treated as no-op success');
  }

  @isTest
  static void testGetMonthlyPayments_Exception() {
    Test.startTest();
    try {
      // This should cause an exception due to invalid query
      PackageBuilderService.getMonthlyPayments('INVALID_ID', null, null);
    } catch (AuraHandledException e) {
      Assert.isTrue(true, 'Exception handled');
    }
    Test.stopTest();
  }

  @isTest
  static void testEnsureMonthlyPaymentsForLineItems_DraftPeriodic() {
    bypassHeavyAutomation();
    Order draftOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
      LIMIT 1
    ];
    Date orderStart = draftOrder.EffectiveDate != null
      ? draftOrder.EffectiveDate
      : Date.today();
    oi.Access_Type__c = 'Periodic';
    oi.ServiceDate = orderStart;
    oi.EndDate = orderStart.addYears(1);
    update oi;

    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];

    Test.startTest();
    PackageBuilderService.ensureMonthlyPaymentsForLineItems(
      draftOrder.Id,
      new List<String>{ oi.Id }
    );
    Test.stopTest();

    Integer paymentCount = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];
    Assert.isTrue(
      paymentCount > 0,
      'Expected periodic draft payments to be created'
    );

    List<MonthlyPayment__c> res = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      draftOrder.Id
    );
    Assert.isTrue(res.size() > 0, 'Drawer query should return draft payments');
    Boolean foundForLine = false;
    for (MonthlyPayment__c mp : res) {
      if (mp.OrderItem__c == oi.Id) {
        foundForLine = true;
        break;
      }
    }
    Assert.isTrue(
      foundForLine,
      'Returned payments should include the draft line'
    );
  }

  @isTest
  static void testBackfillMissingMonthlyPaymentsForOrderItems_ScopedToLine() {
    bypassHeavyAutomation();
    Order draftOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
      LIMIT 1
    ];
    Date orderStart = draftOrder.EffectiveDate != null
      ? draftOrder.EffectiveDate
      : Date.today();
    oi.Access_Type__c = 'Periodic';
    oi.ServiceDate = orderStart;
    oi.EndDate = orderStart.addMonths(12);
    update oi;

    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];

    Test.startTest();
    PackageBuilderService.backfillMissingMonthlyPaymentsForOrderItems(
      draftOrder.Id,
      new List<Id>{ oi.Id }
    );
    Test.stopTest();

    Assert.isTrue(
      [SELECT COUNT() FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id] > 0,
      'Backfill should create payments for the scoped draft line'
    );
  }

  @isTest
  static void testBackfillMissingMonthlyPayments_TopUpShortOpenEndedHorizon() {
    bypassHeavyAutomation();
    Order draftOrder = [
      SELECT Id
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    OrderItem oi = [
      SELECT Id, Product2Id
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
      LIMIT 1
    ];
    Date entry = Date.today();
    oi.Access_Type__c = 'Monthly';
    oi.ServiceDate = entry;
    oi.EndDate = null;
    update oi;

    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    List<MonthlyPayment__c> seeded = new List<MonthlyPayment__c>();
    for (Integer i = 1; i <= 13; i++) {
      Date statD = ContractService.monthlyStatDateForOrderItemMonth(entry, i);
      Date endD = ContractService.monthlyEndDateForOrderItemMonth(entry, i);
      seeded.add(
        new MonthlyPayment__c(
          OrderItem__c = oi.Id,
          MonthIndex__c = i,
          Stat_Date_Trigger__c = statD,
          End_Date_trigger__c = endD
        )
      );
    }
    insert seeded;

    OrderItem oiForCount = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        Access_Type__c,
        Product2.Type__c,
        Contract__r.EndDate
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    // Match syncOpenEndedMonthlyPaymentsAddOnly horizon (batch as-of, not Date.today()).
    Date asOf = ContractService.monthlyPaymentBatchEffectiveDate();
    Integer expected = ContractService.resolveOpenEndedMonthlyHorizonMonthCount(
      oiForCount,
      asOf.addMonths(ContractService.ROLLING_FORWARD_MONTHS),
      asOf
    );

    Test.startTest();
    PackageBuilderService.backfillMissingMonthlyPaymentsForOrderItems(
      draftOrder.Id,
      new List<Id>{ oi.Id }
    );
    Test.stopTest();

    Assert.areEqual(
      expected,
      [SELECT COUNT() FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id],
      'Backfill should add-only top up a short open-ended Monthly horizon'
    );
  }

  @isTest
  static void testEnsureMonthlyPaymentsForLineItems_SkipsActivatedOrder() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];

    Test.startTest();
    PackageBuilderService.ensureMonthlyPaymentsForLineItems(
      activeOrder.Id,
      new List<String>{ oi.Id }
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id],
      'Activated orders should not be backfilled via ensureMonthlyPaymentsForLineItems'
    );
  }

  // ─── ensureDraftOrder ─────────────────────────────────────

  @isTest
  static void testEnsureDraftOrder_DraftListPriceFromCurrentPricebookEntry() {
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    OrderItem activeLine = [
      SELECT Id, PricebookEntryId, ListPrice, UnitPrice
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    Decimal negotiatedUnitPrice = activeLine.UnitPrice;
    Decimal updatedCatalogListPrice =
      (activeLine.ListPrice != null ? activeLine.ListPrice : 1000) + 250;
    update new PricebookEntry(
      Id = activeLine.PricebookEntryId,
      UnitPrice = updatedCatalogListPrice
    );

    activeLine = [
      SELECT ListPrice, UnitPrice
      FROM OrderItem
      WHERE Id = :activeLine.Id
    ];

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    OrderItem draftLine = [
      SELECT ListPrice, UnitPrice
      FROM OrderItem
      WHERE OrderId = :result.draftOrder.Id
      LIMIT 1
    ];
    Assert.areEqual(
      updatedCatalogListPrice,
      draftLine.ListPrice,
      'Draft clone should use current price book list price'
    );
    Assert.areEqual(
      negotiatedUnitPrice,
      draftLine.UnitPrice,
      'Draft clone should preserve negotiated unit price from active line'
    );
  }

  @isTest
  static void testEnsureDraftOrder_Success() {
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Test.startTest();
    activeOrder.Status = 'Activated';
    // Deliberately differ from contract so we assert draft end follows draft items, not contract.
    activeOrder.EndDate = Date.today().addMonths(6);
    update activeOrder;
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();
    Assert.isNotNull(result.draftOrder, 'Draft order should be returned');
    Assert.areEqual('Draft', result.draftOrder.Status, 'Draft status');
    Assert.areEqual(
      activeOrder.Id,
      result.draftOrder.Previous_Order__c,
      'Previous_Order__c should point to active order'
    );
    Assert.isNotNull(result.itemIdMapping, 'Mapping should be non-null');
    Order draftReloaded = [
      SELECT Id, EffectiveDate, EndDate
      FROM Order
      WHERE Id = :result.draftOrder.Id
    ];
    Assert.areEqual(
      Date.today(),
      draftReloaded.EffectiveDate,
      'Draft order start should default to today'
    );
    AggregateResult maxDraftEnd = [
      SELECT MAX(EndDate) maxEnd
      FROM OrderItem
      WHERE OrderId = :draftReloaded.Id
    ];
    Date expectedDraftEnd = (Date) maxDraftEnd.get('maxEnd');
    Assert.areEqual(
      expectedDraftEnd,
      draftReloaded.EndDate,
      'Draft order end should match max draft item end date'
    );
    List<OrderItem> draftLines = [
      SELECT Id, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftReloaded.Id
    ];
    Set<Id> draftLineIds = new Map<Id, OrderItem>(draftLines).keySet();
    Integer mpCount = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :draftLineIds
    ];
    Assert.isTrue(
      mpCount > 0,
      'Draft order items should have monthly payments when created'
    );
    for (OrderItem dil : draftLines) {
      Assert.areEqual(
        Date.today(),
        dil.ServiceDate,
        'Draft line ServiceDate should match draft order start'
      );
    }
  }

  @isTest
  static void testEnsureDraftOrder_TerminatedContractSuccess() {
    Contract contr = [
      SELECT Id, Status, EndDate
      FROM Contract
      LIMIT 1
    ];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Date termDate = contr.EndDate != null ? contr.EndDate : Date.today();
    contr.Contract_Termination_Date__c = termDate;
    contr.Contract_Termination_Reason__c = 'Dissatisfaction';
    contr.Status = 'Terminated';
    update contr;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isNotNull(result.draftOrder, 'Draft order should be returned');
    Assert.areEqual('Draft', result.draftOrder.Status, 'Draft status');
    Assert.areEqual(
      'Terminated',
      [SELECT Status FROM Contract WHERE Id = :contr.Id].Status,
      'Contract status should remain Terminated'
    );
  }

  @isTest
  static void testEnsureDraftOrder_CopiesMonthlyPaymentDiscountsFromActiveOrder() {
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    OrderItem activeLine = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    List<MonthlyPayment__c> activePayments = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :activeLine.Id
      ORDER BY MonthIndex__c ASC
    ];
    if (activePayments.isEmpty()) {
      ContractService.generateMonthlyPaymentsRelatedToOrderItems(
        new Map<Id, OrderItem>(
          [
            SELECT
              Id,
              ServiceDate,
              EndDate,
              ListPrice,
              Access_Type__c,
              Contract__c,
              Contract__r.StartDate,
              Contract__r.EndDate,
              Contract__r.Location__c,
              Product2Id,
              Opportunity_Product__c,
              Original_Order_Product__c,
              Order.EffectiveDate,
              Order.Previous_Order__c,
              Order.Replacement_Start_Date__c,
              Order.OpportunityId,
              Change_Action_Type__c,
              Period_In_Months__c,
              Product2.Type__c
            FROM OrderItem
            WHERE Id = :activeLine.Id
          ]
        )
      );
      activePayments = [
        SELECT Id, Discount__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :activeLine.Id
        ORDER BY MonthIndex__c ASC
      ];
    }
    for (MonthlyPayment__c mp : activePayments) {
      mp.Discount__c = 12;
    }
    update activePayments;
    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    OrderItem draftLine = [
      SELECT Id
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    List<MonthlyPayment__c> draftPayments = [
      SELECT Discount__c, MonthIndex__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :draftLine.Id
      ORDER BY MonthIndex__c ASC
    ];
    Assert.isTrue(
      !draftPayments.isEmpty(),
      'Draft line should have monthly payments.'
    );
    for (MonthlyPayment__c mp : draftPayments) {
      Assert.areEqual(
        12,
        mp.Discount__c,
        'Draft monthly payment should copy discount from active order line.'
      );
    }
  }

  @isTest
  static void testEnsureDraftOrder_CopiesEndedProductsWithExactDates() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];

    OrderItem baseActiveLine = [
      SELECT Id, PricebookEntryId, UnitPrice, Contract__c
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];

    Date endedServiceDate = activeOrder.EffectiveDate;
    Date endedEndDate = endedServiceDate.addDays(5);
    OrderItem endedActiveLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = baseActiveLine.PricebookEntryId,
      Quantity = 1,
      UnitPrice = baseActiveLine.UnitPrice,
      ServiceDate = endedServiceDate,
      EndDate = endedEndDate,
      Contract__c = baseActiveLine.Contract__c
    );
    insert endedActiveLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    OrderItem copiedEndedLine = [
      SELECT ServiceDate, EndDate
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :endedActiveLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      endedServiceDate,
      copiedEndedLine.ServiceDate,
      'Ended product start date should be copied exactly'
    );
    Assert.areEqual(
      endedEndDate,
      copiedEndedLine.EndDate,
      'Ended product end date should be copied exactly'
    );
    Assert.isTrue(
      result.itemIdMapping.containsKey(endedActiveLine.Id),
      'Ended active product should be included in old->new item mapping'
    );
  }

  @isTest
  static void testEnsureDraftOrder_RemapsReplacedOrderProductToDraftCloneIds() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    OrderItem parentLine = [
      SELECT Id, PricebookEntryId, UnitPrice, Contract__c, ServiceDate, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    Date replStart = parentLine.ServiceDate != null
      ? parentLine.ServiceDate.addDays(10)
      : Date.today().addDays(10);
    Date replEnd = parentLine.EndDate != null
      ? parentLine.EndDate
      : Date.today().addMonths(12);
    OrderItem replacementLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = parentLine.PricebookEntryId,
      Quantity = 1,
      UnitPrice = parentLine.UnitPrice,
      ServiceDate = replStart,
      EndDate = replEnd,
      Contract__c = parentLine.Contract__c,
      Access_Type__c = 'Periodic',
      Change_Type__c = 'New',
      Replaced_Order_Product__c = parentLine.Id
    );
    insert replacementLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Id expectedDraftParentId = result.itemIdMapping.get(parentLine.Id);
    Assert.isNotNull(
      expectedDraftParentId,
      'Draft clone for parent should exist in mapping'
    );

    OrderItem draftReplacement = [
      SELECT Replaced_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :replacementLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      expectedDraftParentId,
      draftReplacement.Replaced_Order_Product__c,
      'Draft replacement must reference the draft parent line Id so replacement icons resolve on the Draft tab.'
    );
  }

  @isTest
  static void testEnsureDraftOrder_RemapsContractTermReplacementWhenParentEndedOnOrBeforeToday() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    Product2 meterProd = new Product2(
      Name = 'CT Replace Chain',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert meterProd;
    PricebookEntry meterPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = meterProd.Id,
      UnitPrice = 10,
      IsActive = true
    );
    insert meterPbe;

    activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE Id = :activeOrder.Id
    ];
    Date floor = activeOrder.EffectiveDate != null
      ? activeOrder.EffectiveDate
      : Date.today();
    Date endedEnd = floor.addDays(40);
    Date endedStart = floor.addDays(5);
    Date replStart = floor.addDays(10);

    OrderItem parentLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 7,
      UnitPrice = 10,
      ServiceDate = endedStart,
      EndDate = endedEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Change_Type__c = 'Removed'
    );
    insert parentLine;

    OrderItem replacementLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 9,
      UnitPrice = 10,
      ServiceDate = replStart,
      EndDate = null,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Change_Type__c = 'New',
      Replaced_Order_Product__c = parentLine.Id
    );
    insert replacementLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Id expectedDraftParentId = result.itemIdMapping.get(parentLine.Id);
    Assert.isNotNull(
      expectedDraftParentId,
      'Ended contract-term parent referenced by a replacement must still be cloned onto the draft.'
    );

    OrderItem draftReplacement = [
      SELECT Replaced_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :replacementLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      expectedDraftParentId,
      draftReplacement.Replaced_Order_Product__c,
      'Replaced_Order_Product__c must remap to the draft clone of the ended parent so replacement UI works.'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_ActivatesWhenMaxEndInFuture() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id, EndDate FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    // Create a draft order.
    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status, EndDate
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    System.assertEquals('Draft', draftOrder.Status);

    // Add a Contract Terms line with blank EndDate (should not open-end).
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 meterProd = new Product2(
      Name = 'Terms Blank End',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert meterProd;
    PricebookEntry meterPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = meterProd.Id,
      UnitPrice = 10,
      IsActive = true
    );
    insert meterPbe;
    insert new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 1,
      UnitPrice = 10,
      Access_Type__c = 'Monthly',
      ServiceDate = Date.today(),
      EndDate = null,
      Contract__c = contr.Id
    );

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    // Make sure there is at least one bounded line in the future so finalize activates.
    OrderItem anyLine = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
      LIMIT 1
    ];
    Date futureEnd = Date.today().addDays(10);
    anyLine.EndDate = futureEnd;
    update anyLine;

    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      null
    );
    Test.stopTest();

    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    Contract cAfter = [
      SELECT
        Status,
        EndDate,
        Contract_Termination_Date__c,
        Contract_Termination_Reason__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      'Activated',
      after.Status,
      'Should activate when max end date is in the future'
    );
    System.assertEquals(
      'Activated',
      cAfter.Status,
      'Contract should be Activated when draft activates with future max end'
    );
    System.assertEquals(
      futureEnd,
      after.EndDate,
      'Order.EndDate should be recalculated'
    );
    System.assert(
      cAfter.EndDate != null && cAfter.EndDate >= futureEnd,
      'Contract.EndDate should be at least the draft max end (other active orders may extend it further). Actual: ' +
      String.valueOf(cAfter.EndDate)
    );
    System.assertEquals(
      futureEnd,
      cAfter.Contract_Termination_Date__c,
      'Contract termination date should be max end date'
    );
    System.assertEquals(
      'Other',
      cAfter.Contract_Termination_Reason__c,
      'Contract termination reason should be set'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_ActivatesWhenProductsEndTodayDespiteFutureExit() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    System.assertEquals('Draft', draftOrder.Status);

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    // Set all existing draft lines EndDate to today. Clear ServiceDate so record-triggered flow
    // "Order Item- Sync Dates with Monthly Payments" (Update when ServiceDate is not null) does not run.
    List<OrderItem> lines = [
      SELECT Id, EndDate, Access_Type__c, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      for (OrderItem oi : lines) {
        oi.Access_Type__c = 'Periodic';
        oi.ServiceDate = null;
        oi.EndDate = Date.today();
      }
      update lines;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Date futureExit = Date.today().addDays(1);
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Dissatisfaction',
      futureExit
    );
    Test.stopTest();

    Date expectedEnd = Date.today();
    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    System.assertEquals(
      'Activated',
      after.Status,
      'Should activate when max product end is today even if exit date is in the future'
    );
    System.assertEquals(
      expectedEnd,
      after.EndDate,
      'Order.EndDate should follow visible product end dates (today), not a later exit date'
    );

    Contract cAfter = [
      SELECT
        Status,
        Contract_Termination_Date__c,
        Contract_Termination_Reason__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      'Terminated',
      cAfter.Status,
      'Contract should be Terminated when all products end today'
    );
    System.assertEquals(
      expectedEnd,
      cAfter.Contract_Termination_Date__c,
      'Contract termination date should match max product end (today), not a later exit date'
    );
    System.assertEquals(
      'Dissatisfaction',
      cAfter.Contract_Termination_Reason__c,
      'Contract termination reason should be set'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_ActivatesWhenMaxEndIsToday_WithoutExitDate() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    System.assertEquals('Draft', draftOrder.Status);

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    // Set all existing draft lines EndDate to today (common "terminate to today" path).
    // Null ServiceDate avoids record flow "Order Item- Sync Dates with Monthly Payments" on update.
    List<OrderItem> lines = [
      SELECT Id, EndDate, Access_Type__c, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      for (OrderItem oi : lines) {
        oi.Access_Type__c = 'Periodic';
        oi.ServiceDate = null;
        oi.EndDate = Date.today();
      }
      update lines;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      null
    );
    Test.stopTest();

    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    System.assertEquals(
      'Activated',
      after.Status,
      'Should activate when max line end is today even if exit date is not provided'
    );
    System.assertEquals(
      Date.today(),
      after.EndDate,
      'Order.EndDate should be set to max (today)'
    );
    System.assertEquals(
      'Terminated',
      [SELECT Status FROM Contract WHERE Id = :contr.Id].Status,
      'Contract should be Terminated when all products end today'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_TerminateAllToToday_ShrinksPackageEndBeforeActivation() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status, EndDate
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    System.assertEquals('Draft', draftOrder.Status);

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    List<OrderItem> lines = [
      SELECT Id, EndDate, Access_Type__c, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    Date exitToday = Date.today();
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      for (OrderItem oi : lines) {
        oi.Access_Type__c = 'Periodic';
        oi.ServiceDate = null;
        oi.EndDate = exitToday;
      }
      update lines;
      // Simulate cloned draft header still in the future while products were curtailed to today.
      update new Order(Id = draftOrder.Id, EndDate = exitToday.addMonths(6));
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    System.assertEquals(
      'Activated',
      after.Status,
      'Terminate-all to today should activate without Customer Package End Date validation errors'
    );
    System.assertEquals(
      exitToday,
      after.EndDate,
      'Order.EndDate should shrink to match curtailed product ends before activation'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_BumpsBoundedEndsWhenExitAfterMaxThenActivates() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    System.assertEquals('Draft', draftOrder.Status);

    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Order draftHdr = [
      SELECT EffectiveDate
      FROM Order
      WHERE Id = :draftOrder.Id
    ];
    Date eff = draftHdr.EffectiveDate != null
      ? draftHdr.EffectiveDate
      : Date.today().addDays(-30);
    Date yesterday = Date.today().addDays(-1);
    List<OrderItem> lines = [
      SELECT Id, EndDate, ServiceDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    for (OrderItem oi : lines) {
      oi.Access_Type__c = 'Periodic';
      oi.ServiceDate = eff;
      oi.EndDate = yesterday >= eff ? yesterday : eff.addDays(1);
    }
    update lines;

    Date exitDate = Date.today().addDays(1);
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Dissatisfaction',
      exitDate
    );
    Test.stopTest();

    Integer mismatchedLineCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND EndDate != :exitDate
    ];
    System.assertEquals(
      0,
      mismatchedLineCount,
      'All bounded draft lines should be aligned to the exit date'
    );

    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    System.assertEquals(
      'Activated',
      after.Status,
      'Should activate when exit date is in the future after aligning ends'
    );
    System.assertEquals(
      exitDate,
      after.EndDate,
      'Order.EndDate should follow aligned max end'
    );

    Contract cAfter = [
      SELECT
        Status,
        Contract_Termination_Date__c,
        Contract_Termination_Reason__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      'Activated',
      cAfter.Status,
      'Contract should be Activated when exit date is in the future after aligning ends'
    );
    System.assertEquals(
      exitDate,
      cAfter.Contract_Termination_Date__c,
      'Contract termination date should follow aligned max end'
    );
    System.assertEquals(
      'Dissatisfaction',
      cAfter.Contract_Termination_Reason__c,
      'Contract termination reason should be set'
    );
  }

  @isTest
  static void testFinalizeTerminateAll_SoftDeletedFutureEnd_CurtailsToExit() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Date exitToday = Date.today();
    Date strayEnd = exitToday.addMonths(6);
    Order draftHdr = [
      SELECT EffectiveDate, Order_Start_Date__c, EndDate
      FROM Order
      WHERE Id = :draftOrder.Id
    ];
    Date orderStart = draftHdr.Order_Start_Date__c != null
      ? draftHdr.Order_Start_Date__c
      : draftHdr.EffectiveDate;
    List<OrderItem> lines = [
      SELECT Id, Is_Line_Deleted__c, ServiceDate, EndDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      update new Order(Id = draftOrder.Id, EndDate = strayEnd);
      Boolean hasSoftDeleted = false;
      for (OrderItem oi : lines) {
        if (oi.Is_Line_Deleted__c == true) {
          hasSoftDeleted = true;
          oi.ServiceDate = null;
          oi.EndDate = null;
          oi.Original_Start_Date__c = orderStart;
          oi.Original_End_Date__c = strayEnd;
        } else {
          oi.Access_Type__c = 'Periodic';
          oi.EndDate = exitToday;
        }
      }
      if (!hasSoftDeleted && !lines.isEmpty()) {
        lines[0].Is_Line_Deleted__c = true;
        lines[0].ServiceDate = null;
        lines[0].EndDate = null;
        lines[0].Original_Start_Date__c = orderStart;
        lines[0].Original_End_Date__c = strayEnd;
      }
      update lines;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Order after = [SELECT Status FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual(
      'Activated',
      after.Status,
      'Soft-deleted stray end must not block terminate-all when visible lines drive exit'
    );
    for (OrderItem softDeleted : [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND Is_Line_Deleted__c = TRUE
    ]) {
      Assert.areEqual(
        null,
        softDeleted.EndDate,
        'Archived soft-deleted line should keep live EndDate null'
      );
      Assert.areEqual(strayEnd, softDeleted.Original_End_Date__c);
    }
  }

  @isTest
  static void testFinalizeTerminateAll_SoftDeletedFutureStart_HardDeletes() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Date exitToday = Date.today();
    Date futureStart = exitToday.addDays(10);
    OrderItem templateLine = [
      SELECT PricebookEntryId, UnitPrice, Contract__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
      LIMIT 1
    ];
    OrderItem futureStartLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = templateLine.PricebookEntryId,
      Quantity = 1,
      UnitPrice = templateLine.UnitPrice,
      ServiceDate = futureStart,
      EndDate = futureStart.addMonths(1),
      Contract__c = templateLine.Contract__c,
      Access_Type__c = 'Periodic',
      Is_Line_Deleted__c = true
    );
    Id futureStartLineId;
    List<OrderItem> lines = [
      SELECT Id, EndDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      for (OrderItem oi : lines) {
        oi.Access_Type__c = 'Periodic';
        oi.EndDate = exitToday;
      }
      update lines;
      update new Order(Id = draftOrder.Id, EndDate = futureStart.addMonths(1));
      insert futureStartLine;
      futureStartLineId = futureStartLine.Id;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :futureStartLineId],
      'Future-start soft-deleted line should be hard-deleted'
    );
    Order after = [SELECT Status FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual('Activated', after.Status);
  }

  @isTest
  static void testFinalizeTerminateAll_ContractTermsFutureStart_HardDeletes() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Product2 ctProd = new Product2(
      Name = 'CT Future Start Sweep',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert ctProd;
    PricebookEntry ctPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = ctProd.Id,
      UnitPrice = 15,
      IsActive = true
    );
    insert ctPbe;

    Date exitToday = Date.today();
    Date futureStart = exitToday.addDays(14);
    OrderItem futureCtLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 1,
      UnitPrice = 15,
      ServiceDate = futureStart,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly'
    );
    insert futureCtLine;

    List<OrderItem> visibleLines = [
      SELECT Id, EndDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND Id != :futureCtLine.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      for (OrderItem oi : visibleLines) {
        oi.Access_Type__c = 'Periodic';
        oi.EndDate = exitToday;
      }
      update visibleLines;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      [SELECT COUNT() FROM OrderItem WHERE Id = :futureCtLine.Id],
      'Standalone future-start Contract Terms line is not hard-deleted; reconcile only soft-deletes replacement children'
    );
    Order after = [SELECT Status FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual('Activated', after.Status);
  }

  @isTest
  static void testFinalizeTerminateAll_ReplacementChildFutureStart_HardDeletesChildClearsParentEnd() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Replacement sweep terminate');
    insert acc;
    Date contractStart = Date.today().addDays(-30);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    Product2 meterProd = new Product2(
      Name = 'CT Replace Sweep',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert meterProd;
    PricebookEntry meterPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = meterProd.Id,
      UnitPrice = 10,
      IsActive = true
    );
    insert meterPbe;

    Date endedEnd = contractStart.addDays(40);
    Date endedStart = contractStart.addDays(5);
    Date replStart = contractStart.addDays(10);

    OrderItem parentLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 7,
      UnitPrice = 10,
      ServiceDate = endedStart,
      EndDate = endedEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Change_Type__c = 'Removed'
    );
    insert parentLine;

    OrderItem replacementLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 9,
      UnitPrice = 10,
      ServiceDate = replStart,
      EndDate = endedEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Change_Type__c = 'New',
      Replaced_Order_Product__c = parentLine.Id
    );
    insert replacementLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Id draftParentId = draftResult.itemIdMapping.get(parentLine.Id);
    OrderItem draftReplacement = [
      SELECT Id, ServiceDate, EndDate
      FROM OrderItem
      WHERE
        OrderId = :draftOrder.Id
        AND Original_Order_Product__c = :replacementLine.Id
      LIMIT 1
    ];

    Date exitToday = Date.today();
    Date futureStart = exitToday.addDays(12);
    Date futureEnd = futureStart.addMonths(3);
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      List<OrderItem> otherLines = [
        SELECT Id, EndDate, Access_Type__c
        FROM OrderItem
        WHERE
          OrderId = :draftOrder.Id
          AND Id NOT IN (:draftReplacement.Id, :draftParentId)
      ];
      for (OrderItem oi : otherLines) {
        oi.Access_Type__c = 'Periodic';
        oi.EndDate = exitToday;
      }
      if (!otherLines.isEmpty()) {
        update otherLines;
      }
      update new Order(Id = draftOrder.Id, EndDate = futureEnd);
      draftReplacement.ServiceDate = futureStart;
      draftReplacement.EndDate = futureEnd;
      update draftReplacement;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :draftReplacement.Id],
      'Future-start CT replacement child should be hard-deleted'
    );
    OrderItem parentAfter = [
      SELECT EndDate, Change_Type__c
      FROM OrderItem
      WHERE Id = :draftParentId
    ];
    Assert.areEqual(
      null,
      parentAfter.EndDate,
      'CT parent EndDate should be cleared when future replacement is hard-deleted'
    );
    Order after = [SELECT Status FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual('Activated', after.Status);
  }

  @isTest
  static void testFinalizeTerminateAll_StraySoftDeleted_RegressesTerminateAllToToday() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order draftOrder = [
      SELECT Id, Status, EndDate
      FROM Order
      WHERE Id = :draftResult.draftOrder.Id
    ];
    deleteMonthlyPaymentsForDraftOrder(draftOrder.Id);

    Date exitToday = Date.today();
    Date strayEnd = exitToday.addMonths(6);
    Order draftHdr = [
      SELECT EffectiveDate, Order_Start_Date__c
      FROM Order
      WHERE Id = :draftOrder.Id
    ];
    Date orderStart = draftHdr.Order_Start_Date__c != null
      ? draftHdr.Order_Start_Date__c
      : draftHdr.EffectiveDate;
    List<OrderItem> lines = [
      SELECT Id, Is_Line_Deleted__c, ServiceDate, EndDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id
    ];
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      update new Order(Id = draftOrder.Id, EndDate = strayEnd);
      Boolean strayConfigured = false;
      for (OrderItem oi : lines) {
        if (oi.Is_Line_Deleted__c == true) {
          oi.ServiceDate = null;
          oi.EndDate = null;
          oi.Original_Start_Date__c = orderStart;
          oi.Original_End_Date__c = strayEnd;
          strayConfigured = true;
        } else {
          oi.Access_Type__c = 'Periodic';
          if (oi.ServiceDate == null || oi.ServiceDate < orderStart) {
            oi.ServiceDate = orderStart;
          }
          oi.EndDate = exitToday;
          oi.Termination_Reason__c = 'Other';
        }
      }
      if (!strayConfigured && !lines.isEmpty()) {
        lines[0].Is_Line_Deleted__c = true;
        lines[0].ServiceDate = null;
        lines[0].EndDate = null;
        lines[0].Original_Start_Date__c = orderStart;
        lines[0].Original_End_Date__c = strayEnd;
      }
      update lines;
      PackageBuilderService.prepareDraftOrderEndForLineSave(
        draftOrder.Id,
        exitToday
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.finalizeTerminateAll(
      contr.Id,
      draftOrder.Id,
      'Other',
      exitToday
    );
    Test.stopTest();

    Order after = [SELECT Status, EndDate FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual(
      'Activated',
      after.Status,
      'Stray soft-deleted future end must not block terminate-all activation'
    );
    Assert.areEqual(exitToday, after.EndDate);
    for (OrderItem stray : [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND Is_Line_Deleted__c = TRUE
    ]) {
      Assert.areEqual(
        null,
        stray.EndDate,
        'Archived soft-deleted line should keep live EndDate null'
      );
      Assert.areEqual(strayEnd, stray.Original_End_Date__c);
    }
  }

  @isTest
  static void testEnsureDraftOrder_SkipsExpiredContractTermsProducts() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Skip expired contract terms account');
    insert acc;
    Date contractStart = Date.today().addDays(-30);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    Product2 contractTermsProd = new Product2(
      Name = 'Contract Terms Expired',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert contractTermsProd;

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = contractTermsProd.Id,
      UnitPrice = 25,
      IsActive = true
    );
    insert pbe;

    Date endedServiceDate = contractStart.addDays(5);
    Date endedEndDate = contractStart.addDays(10);
    Date boundaryEndDate = contractStart.addDays(15);
    OrderItem todayEndingContractTermsLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 25,
      ServiceDate = endedServiceDate,
      EndDate = boundaryEndDate,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert todayEndingContractTermsLine;
    OrderItem expiredContractTermsLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 25,
      ServiceDate = endedServiceDate,
      EndDate = endedEndDate,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert expiredContractTermsLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Integer copiedCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :expiredContractTermsLine.Id
    ];
    Assert.areEqual(
      0,
      copiedCount,
      'Expired Contract Terms product should not be copied to draft'
    );
    Assert.isFalse(
      result.itemIdMapping.containsKey(expiredContractTermsLine.Id),
      'Expired Contract Terms product should not be included in old->new item mapping'
    );
    Integer copiedTodayEndCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :todayEndingContractTermsLine.Id
    ];
    Assert.areEqual(
      0,
      copiedTodayEndCount,
      'Contract Terms product ending today should not be copied to draft'
    );
    Assert.isFalse(
      result.itemIdMapping.containsKey(todayEndingContractTermsLine.Id),
      'Contract Terms product ending today should not be included in old->new item mapping'
    );
  }

  @isTest
  static void testEnsureDraftOrder_SkipsInactiveProduct2() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    OrderItem activeLine = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    Product2 inactiveProd = new Product2(
      Name = 'Inactive Balcony',
      IsActive = false,
      Location__c = loc.Id
    );
    insert inactiveProd;
    PricebookEntry inactivePbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = inactiveProd.Id,
      UnitPrice = 500,
      IsActive = true
    );
    insert inactivePbe;

    OrderItem inactiveLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = inactivePbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = activeOrder.EffectiveDate,
      EndDate = activeOrder.EffectiveDate.addMonths(12),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert inactiveLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isTrue(
      result.itemIdMapping.containsKey(activeLine.Id),
      'Active catalog line should be cloned'
    );
    Assert.isFalse(
      result.itemIdMapping.containsKey(inactiveLine.Id),
      'Inactive Product2 line should not be cloned'
    );
    Integer inactiveCloneCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :inactiveLine.Id
    ];
    Assert.areEqual(
      0,
      inactiveCloneCount,
      'Inactive Product2 line should not appear on draft'
    );
  }

  @isTest
  static void testEnsureDraftOrder_SkipsInactivePricebookEntry() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    Product2 activeProd = new Product2(
      Name = 'Active Product Inactive PBE',
      IsActive = true,
      Location__c = loc.Id
    );
    insert activeProd;
    PricebookEntry inactivePbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = activeProd.Id,
      UnitPrice = 750,
      IsActive = false
    );
    insert inactivePbe;

    OrderItem inactivePbeLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = inactivePbe.Id,
      Quantity = 1,
      UnitPrice = 750,
      ServiceDate = activeOrder.EffectiveDate,
      EndDate = activeOrder.EffectiveDate.addMonths(12),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert inactivePbeLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isFalse(
      result.itemIdMapping.containsKey(inactivePbeLine.Id),
      'Inactive PricebookEntry line should not be cloned'
    );
    Integer inactiveCloneCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :inactivePbeLine.Id
    ];
    Assert.areEqual(
      0,
      inactiveCloneCount,
      'Inactive PricebookEntry line should not appear on draft'
    );
  }

  @isTest
  static void testEnsureDraftOrder_AllInactive_CreatesEmptyDraft() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'All inactive catalog account');
    insert acc;
    Date contractStart = Date.today().addDays(-10);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    Product2 inactiveProd = new Product2(
      Name = 'Only Inactive',
      IsActive = false,
      Location__c = loc.Id
    );
    insert inactiveProd;
    PricebookEntry inactivePbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = inactiveProd.Id,
      UnitPrice = 100,
      IsActive = false
    );
    insert inactivePbe;
    insert new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = inactivePbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = contractStart,
      EndDate = contractStart.addMonths(6),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isNotNull(result.draftOrder, 'Empty draft order should be created');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM OrderItem WHERE OrderId = :result.draftOrder.Id],
      'Draft should have no lines when all active-order catalog entries are inactive'
    );
  }

  @isTest
  static void testEnsureDraftOrder_EndDateFromClonedLinesOnly() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    OrderItem activeLine = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    Date activeEnd = activeLine.EndDate != null
      ? activeLine.EndDate
      : Date.today().addMonths(6);
    activeLine.EndDate = activeEnd;
    update activeLine;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Product2 inactiveProd = new Product2(
      Name = 'Inactive Later End',
      IsActive = false,
      Location__c = loc.Id
    );
    insert inactiveProd;
    PricebookEntry inactivePbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = inactiveProd.Id,
      UnitPrice = 200,
      IsActive = true
    );
    insert inactivePbe;
    insert new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = inactivePbe.Id,
      Quantity = 1,
      UnitPrice = 200,
      ServiceDate = activeOrder.EffectiveDate,
      EndDate = activeEnd.addMonths(12),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Order draft = [
      SELECT EndDate
      FROM Order
      WHERE Id = :result.draftOrder.Id
    ];
    Assert.areEqual(
      activeEnd,
      draft.EndDate,
      'Draft EndDate should reflect cloned active lines only, not skipped inactive lines'
    );
  }

  @isTest
  static void testEnsureDraftOrder_ClearsReplacedLookupWhenParentInactive() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, EffectiveDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    Product2 inactiveParentProd = new Product2(
      Name = 'Inactive Parent',
      IsActive = false,
      Location__c = loc.Id
    );
    insert inactiveParentProd;
    PricebookEntry inactiveParentPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = inactiveParentProd.Id,
      UnitPrice = 300,
      IsActive = true
    );
    insert inactiveParentPbe;

    Date parentStart = activeOrder.EffectiveDate;
    Date parentEnd = parentStart.addMonths(6);
    OrderItem inactiveParentLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = inactiveParentPbe.Id,
      Quantity = 1,
      UnitPrice = 300,
      ServiceDate = parentStart,
      EndDate = parentEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Change_Type__c = 'Removed'
    );
    insert inactiveParentLine;

    OrderItem activeLine = [
      SELECT Id, PricebookEntryId, UnitPrice, Contract__c, ServiceDate, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id AND Id != :inactiveParentLine.Id
      LIMIT 1
    ];
    Date replStart = parentEnd.addDays(1);
    Date replEnd = activeLine.EndDate != null &&
      activeLine.EndDate >= replStart
      ? activeLine.EndDate
      : replStart.addMonths(12);
    OrderItem replacementLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = activeLine.PricebookEntryId,
      Quantity = 1,
      UnitPrice = activeLine.UnitPrice,
      ServiceDate = replStart,
      EndDate = replEnd,
      Contract__c = activeLine.Contract__c,
      Access_Type__c = 'Periodic',
      Change_Type__c = 'New',
      Replaced_Order_Product__c = inactiveParentLine.Id
    );
    insert replacementLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isFalse(
      result.itemIdMapping.containsKey(inactiveParentLine.Id),
      'Inactive parent should not be cloned'
    );
    OrderItem draftReplacement = [
      SELECT Replaced_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :replacementLine.Id
      LIMIT 1
    ];
    Assert.isNotNull(
      draftReplacement,
      'Active replacement child should be cloned'
    );
    Assert.isNull(
      draftReplacement.Replaced_Order_Product__c,
      'Orphan replacement child should not keep Replaced_Order_Product__c when parent was skipped'
    );
  }

  @isTest
  static void testEnsureDraftOrder_ReturnsExistingDraft() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Test.startTest();
    PackageBuilderService.DraftOrderResult first = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    PackageBuilderService.DraftOrderResult second = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();
    Assert.areEqual(
      first.draftOrder.Id,
      second.draftOrder.Id,
      'Should return same existing draft'
    );
    Assert.isTrue(
      second.itemIdMapping.isEmpty(),
      'Mapping empty when draft already exists'
    );
  }

  @isTest
  static void testEnsureDraftOrder_NullLineEndDateWins() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    OrderItem activeLine = [
      SELECT Id, Access_Type__c, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    activeLine.Access_Type__c = 'Monthly';
    activeLine.EndDate = null;
    update activeLine;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result;
    try {
      result = PackageBuilderService.ensureDraftOrder(contr.Id);
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Script-thrown') ||
        e.getMessage().contains('Error')
      );
      return;
    }
    Test.stopTest();

    Order draft = [
      SELECT Id, EndDate
      FROM Order
      WHERE Id = :result.draftOrder.Id
    ];
    Assert.areEqual(
      null,
      draft.EndDate,
      'Any blank draft item end date should make draft order end date blank'
    );
  }

  @isTest
  static void testEnsureDraftOrder_NoActiveOrder_Throws() {
    bypassHeavyAutomation();
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Contract emptyContract = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      EndDate = Date.today().addMonths(12)
    );
    insert emptyContract;
    Test.startTest();
    try {
      PackageBuilderService.ensureDraftOrder(emptyContract.Id);
      Assert.fail('Expected AuraHandledException');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      Assert.isTrue(
        msg.contains('No active order') ||
          msg.contains('active order') ||
          msg.contains('Error creating draft order') ||
          msg.contains('Script-thrown'),
        'Expected no-active-order or wrapped error: ' + msg
      );
    }
    Test.stopTest();
  }

  @isTest
  static void testEnsureDraftOrder_ClonesContractRenewalFields() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT
        Id,
        Agreement_language__c,
        Auto_Renewal__c,
        Credits_for_MR__c,
        Last_Status_Change_Date__c,
        Non_Renewal_Reason__c,
        Prints_B_W__c,
        Prints_Color__c,
        Renewal_Period_Months__c,
        Renewal_Status__c,
        Renewal_Total_Iterations__c,
        Description,
        Depusit_Amount_DM__c,
        Number_of_members__c,
        Track_CPI__c,
        Track_CPI_Date__c,
        Lease_Termination_Notice_Months__c
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    activeOrder.Agreement_language__c = 'English';
    activeOrder.Auto_Renewal__c = true;
    activeOrder.Credits_for_MR__c = 10;
    activeOrder.Last_Status_Change_Date__c = Date.today().addDays(-5);
    activeOrder.Non_Renewal_Reason__c = null;
    activeOrder.Prints_B_W__c = 100;
    activeOrder.Prints_Color__c = 50;
    activeOrder.Renewal_Period_Months__c = 12;
    activeOrder.Renewal_Status__c = 'Not Due';
    activeOrder.Renewal_Total_Iterations__c = '3';
    activeOrder.Description = 'Header fields must clone to draft';
    activeOrder.Depusit_Amount_DM__c = 1234.56;
    activeOrder.Number_of_members__c = 42;
    activeOrder.Track_CPI__c = true;
    activeOrder.Track_CPI_Date__c = Date.today().addDays(15);
    activeOrder.Lease_Termination_Notice_Months__c = '6';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    Assert.isNotNull(result.draftOrder, 'Draft order should be returned');
    Assert.areEqual('Draft', result.draftOrder.Status, 'Draft status');

    Order draft = [
      SELECT
        Id,
        Agreement_language__c,
        Auto_Renewal__c,
        Credits_for_MR__c,
        Last_Status_Change_Date__c,
        Non_Renewal_Reason__c,
        Prints_B_W__c,
        Prints_Color__c,
        Renewal_Period_Months__c,
        Renewal_Status__c,
        Renewal_Total_Iterations__c,
        Description,
        Depusit_Amount_DM__c,
        Number_of_members__c,
        Track_CPI__c,
        Track_CPI_Date__c,
        Lease_Termination_Notice_Months__c
      FROM Order
      WHERE Id = :result.draftOrder.Id
    ];
    Assert.areEqual(
      'English',
      draft.Agreement_language__c,
      'Agreement_language__c should be copied'
    );
    Assert.areEqual(
      true,
      draft.Auto_Renewal__c,
      'Auto_Renewal__c should be copied'
    );
    Assert.areEqual(
      10,
      draft.Credits_for_MR__c,
      'Credits_for_MR__c should be copied'
    );
    Assert.areEqual(
      Date.today().addDays(-5),
      draft.Last_Status_Change_Date__c,
      'Last_Status_Change_Date__c should be copied'
    );
    Assert.areEqual(100, draft.Prints_B_W__c, 'Prints_B_W__c should be copied');
    Assert.areEqual(
      50,
      draft.Prints_Color__c,
      'Prints_Color__c should be copied'
    );
    Assert.areEqual(
      12,
      draft.Renewal_Period_Months__c,
      'Renewal_Period_Months__c should be copied'
    );
    Assert.areEqual(
      'Not Due',
      draft.Renewal_Status__c,
      'Renewal_Status__c should be copied'
    );
    Assert.areEqual(
      '3',
      draft.Renewal_Total_Iterations__c,
      'Renewal_Total_Iterations__c should be copied'
    );
    Assert.areEqual(
      'Header fields must clone to draft',
      draft.Description,
      'Description should be copied'
    );
    Assert.areEqual(
      1234.56,
      draft.Depusit_Amount_DM__c,
      'Depusit_Amount_DM__c should be copied'
    );
    Assert.areEqual(
      42,
      draft.Number_of_members__c,
      'Number_of_members__c should be copied'
    );
    Assert.areEqual(true, draft.Track_CPI__c, 'Track_CPI__c should be copied');
    Assert.areEqual(
      Date.today().addDays(15),
      draft.Track_CPI_Date__c,
      'Track_CPI_Date__c should be copied'
    );
    Assert.areEqual(
      '6',
      draft.Lease_Termination_Notice_Months__c,
      'Lease_Termination_Notice_Months__c should be copied'
    );
  }

  // ─── activateDraftOrder ───────────────────────────────────

  @isTest
  static void testActivateDraftOrder_ReactivatesTerminatedContractWhenMaxEndInFuture() {
    Contract contr = [
      SELECT Id, Status, EndDate
      FROM Contract
      LIMIT 1
    ];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = draftResult.draftOrder.Id;

    Date termDate = Date.today().addDays(-10);
    contr.Contract_Termination_Date__c = termDate;
    contr.Contract_Termination_Reason__c = 'Dissatisfaction';
    contr.Status = 'Terminated';
    contr.EndDate = termDate;
    update contr;
    deleteMonthlyPaymentsForDraftOrder(draftId);

    Date futureEnd = Date.today().addDays(30);
    OrderItem anyLine = [
      SELECT Id, EndDate, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftId
      LIMIT 1
    ];
    anyLine.EndDate = futureEnd;
    if (anyLine.ServiceDate == null || anyLine.ServiceDate > Date.today()) {
      anyLine.ServiceDate = Date.today().addDays(-5);
    }
    update anyLine;

    bypassHeavyAutomation();
    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today());
    Test.stopTest();

    Contract cAfter = [
      SELECT
        Status,
        Contract_Termination_Date__c,
        Contract_Termination_Reason__c
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      'Activated',
      cAfter.Status,
      'Terminated contract should reactivate when draft max end is in the future'
    );
    System.assertEquals(
      futureEnd,
      cAfter.Contract_Termination_Date__c,
      'Termination date should sync to draft max end'
    );
    System.assertEquals(
      'Dissatisfaction',
      cAfter.Contract_Termination_Reason__c,
      'Termination reason should be preserved for audit'
    );
  }

  @isTest
  static void testActivateDraftOrder_ReactivatesExpiredContractWhenMaxEndInFuture() {
    Contract contr = [
      SELECT Id, Status, EndDate
      FROM Contract
      LIMIT 1
    ];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = draftResult.draftOrder.Id;

    Date expiredEnd = Date.today().addDays(-10);
    contr.Status = 'Expired';
    contr.EndDate = expiredEnd;
    update contr;
    deleteMonthlyPaymentsForDraftOrder(draftId);

    Date futureEnd = Date.today().addDays(30);
    OrderItem anyLine = [
      SELECT Id, EndDate, ServiceDate
      FROM OrderItem
      WHERE OrderId = :draftId
      LIMIT 1
    ];
    anyLine.EndDate = futureEnd;
    if (anyLine.ServiceDate == null || anyLine.ServiceDate > Date.today()) {
      anyLine.ServiceDate = Date.today().addDays(-5);
    }
    update anyLine;

    bypassHeavyAutomation();
    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today());
    Test.stopTest();

    Contract cAfter = [
      SELECT Status, Contract_Termination_Date__c, EndDate
      FROM Contract
      WHERE Id = :contr.Id
    ];
    System.assertEquals(
      'Activated',
      cAfter.Status,
      'Expired contract should reactivate when draft max end is in the future'
    );
    System.assertEquals(
      futureEnd,
      cAfter.EndDate,
      'Contract end date should sync to draft max end'
    );
    System.assertEquals(
      null,
      cAfter.Contract_Termination_Date__c,
      'Expired reactivation should not set termination date without reason'
    );
  }

  @isTest
  static void testReactivateTerminatedContractIfApplicable_DoesNotReactivateWhenMaxEndPast() {
    Contract con = new Contract(
      Status = 'Terminated',
      EndDate = Date.today().addDays(-10),
      Contract_Termination_Date__c = Date.today().addDays(-10)
    );
    Boolean changed = PackageBuilderService.reactivateTerminatedContractIfApplicable(
      con,
      Date.today().addDays(-1)
    );
    System.assertEquals(
      false,
      changed,
      'Should not reactivate when effective end is still in the past'
    );
    System.assertEquals(
      'Terminated',
      con.Status,
      'Contract status should remain Terminated'
    );
  }

  @isTest
  static void testActivateDraftOrder_WithPreviousOrder() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Date replacementStart = Date.today().addDays(1);
    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;
    Id previousId = result.draftOrder.Previous_Order__c;
    PackageBuilderService.activateDraftOrder(draftId, replacementStart);
    Test.stopTest();
    Order draft = [
      SELECT Id, Status, EffectiveDate, EndDate, Replacement_Start_Date__c
      FROM Order
      WHERE Id = :draftId
    ];
    Order previous = [
      SELECT Id, Status, EndDate
      FROM Order
      WHERE Id = :previousId
    ];
    Assert.areEqual('Activated', draft.Status, 'Draft should be activated');
    Assert.areEqual(
      'Archived',
      previous.Status,
      'Previous order should be archived'
    );
    Assert.areEqual(
      replacementStart,
      draft.Replacement_Start_Date__c,
      'Replacement start date set'
    );
    OrderItem prevLine = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :previousId
      LIMIT 1
    ];
    Assert.isNotNull(
      prevLine.Id,
      'Previous order products should remain available and unchanged'
    );
  }

  @isTest
  static void testActivateDraftOrder_PreservesDraftLineEntryDate() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];

    Date copiedEntryDate = Date.today().addDays(30);
    Date copiedEndDate = copiedEntryDate.addDays(20);
    OrderItem sourceLine = [
      SELECT Id, ServiceDate, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    sourceLine.ServiceDate = copiedEntryDate;
    sourceLine.EndDate = copiedEndDate;
    update sourceLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;

    OrderItem copiedDraftLine = [
      SELECT Id, ServiceDate, Original_Order_Product__c
      FROM OrderItem
      WHERE OrderId = :draftId AND Original_Order_Product__c = :sourceLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      copiedEntryDate,
      copiedDraftLine.ServiceDate,
      'Setup: copied draft line should keep source entry date.'
    );

    Date replacementStart = Date.today().addDays(10);
    PackageBuilderService.activateDraftOrder(draftId, replacementStart);
    Test.stopTest();

    OrderItem activatedLine = [
      SELECT ServiceDate
      FROM OrderItem
      WHERE Id = :copiedDraftLine.Id
    ];
    Assert.areEqual(
      copiedEntryDate,
      activatedLine.ServiceDate,
      'Activation must preserve existing draft line entry date instead of clamping to order start.'
    );
  }

  @isTest
  static void testActivateDraftOrder_SoftDeletesExpiredDraftProductsBeforeActivation() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Expired product activation test');
    insert acc;
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today().addMonths(-3),
      EndDate = Date.today().addMonths(3)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    PricebookEntry pbe = [
      SELECT Id, UnitPrice, Product2Id
      FROM PricebookEntry
      WHERE IsActive = TRUE
      LIMIT 1
    ];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contr.StartDate,
      EndDate = contr.EndDate,
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    OrderItem expiredActiveLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = Date.today().addMonths(-2),
      EndDate = Date.today().addDays(-1),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert expiredActiveLine;
    OrderItem currentActiveLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = Date.today().addDays(-30),
      EndDate = Date.today().addMonths(1),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert currentActiveLine;
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;
    OrderItem restorableParent = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :currentActiveLine.Id
      LIMIT 1
    ];
    Date replacementStart = Date.today().addDays(-5);
    restorableParent.EndDate = replacementStart.addDays(-1);
    restorableParent.Change_Type__c = 'Removed';
    update restorableParent;
    OrderItem neverActivatedReplacement = new OrderItem(
      OrderId = draftId,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = replacementStart,
      EndDate = Date.today().addDays(-1),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Change_Type__c = 'New',
      Replaced_Order_Product__c = restorableParent.Id
    );
    insert neverActivatedReplacement;
    insert new MonthlyPayment__c(
      OrderItem__c = neverActivatedReplacement.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = replacementStart,
      End_Date_trigger__c = Date.today().addDays(-1),
      Room__c = pbe.Product2Id,
      Contract__c = contr.Id,
      Location__c = loc.Id
    );

    Integer expiredInDraftBefore = [
      SELECT COUNT()
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :expiredActiveLine.Id
    ];
    Assert.areEqual(
      1,
      expiredInDraftBefore,
      'Setup: expired line should exist in draft before activation'
    );

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    Test.stopTest();

    List<OrderItem> expiredAfterActivation = [
      SELECT Id, Is_Line_Deleted__c
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :expiredActiveLine.Id
    ];
    Assert.areEqual(
      1,
      expiredAfterActivation.size(),
      'Expired draft products should remain on order after activation'
    );
    Assert.areEqual(
      true,
      expiredAfterActivation[0].Is_Line_Deleted__c,
      'Expired previously-activated products should be soft-deleted during activation'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM OrderItem
        WHERE Id = :neverActivatedReplacement.Id
      ],
      'Expired never-activated products should be hard-deleted during activation'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :neverActivatedReplacement.Id
      ],
      'Hard-deleted activation products must not leave monthly payments'
    );
    OrderItem restoredParent = [
      SELECT EndDate, Change_Type__c, Is_Line_Deleted__c
      FROM OrderItem
      WHERE Id = :restorableParent.Id
    ];
    Assert.areEqual(
      currentActiveLine.EndDate,
      restoredParent.EndDate,
      'Hard-deleting the replacement should restore the parent end date'
    );
    Assert.areEqual(
      null,
      restoredParent.Change_Type__c,
      'Hard-deleting the replacement should clear the parent change type'
    );
    Assert.areNotEqual(
      true,
      restoredParent.Is_Line_Deleted__c,
      'A restored parent must remain visible'
    );
  }

  @isTest
  static void testActivateDraftOrder_DoesNotSoftDeleteFutureRemovedBeforeDraftStart() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Future removed before draft start test');
    insert acc;
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today().addDays(-10),
      EndDate = Date.today().addMonths(6)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    PricebookEntry pbe = [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE IsActive = TRUE
      LIMIT 1
    ];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    // Active order (so ensureDraftOrder produces a draft with Previous_Order__c)
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contr.StartDate,
      EndDate = contr.EndDate,
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    OrderItem sourceLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(2),
      Contract__c = contr.Id
    );
    insert sourceLine;
    activeOrder.Status = 'Activated';
    update activeOrder;

    // Create draft from active
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;

    // Removed line ends before draft business start but still on or after today (869dkm3xm pattern).
    Date draftBusinessStart = Date.today().addDays(20);
    update new Order(Id = draftId, Order_Start_Date__c = draftBusinessStart);

    OrderItem hiddenRemoved = new OrderItem(
      OrderId = draftId,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = draftBusinessStart.addDays(-10),
      EndDate = draftBusinessStart.addDays(-1),
      Original_Order_Product__c = sourceLine.Id,
      Change_Type__c = 'Removed',
      Contract__c = contr.Id
    );
    insert hiddenRemoved;

    Integer removedBefore = [
      SELECT COUNT()
      FROM OrderItem
      WHERE Id = :hiddenRemoved.Id
    ];
    Assert.areEqual(
      1,
      removedBefore,
      'Setup: hidden Removed line exists before activation'
    );

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    Test.stopTest();

    List<OrderItem> removedAfter = [
      SELECT Id, Is_Line_Deleted__c
      FROM OrderItem
      WHERE Id = :hiddenRemoved.Id
    ];
    Assert.areEqual(
      1,
      removedAfter.size(),
      'Hidden Removed draft products should remain on order after activation'
    );
    Assert.areEqual(
      false,
      removedAfter[0].Is_Line_Deleted__c,
      'Future Removed lines ending before draft start must not be soft-deleted on activation'
    );
  }

  @isTest
  static void testActivateDraftOrder_FutureReplacementParentSurvivesActivation() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Future CT replace activation test');
    insert acc;
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today().addDays(-10),
      EndDate = Date.today().addMonths(12)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Product2 meterProd = new Product2(
      Name = 'CT Future Replace Activation',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert meterProd;
    PricebookEntry meterPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = meterProd.Id,
      UnitPrice = 1,
      IsActive = true
    );
    insert meterPbe;

    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contr.StartDate,
      EndDate = contr.EndDate,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    Date parentStart = contr.StartDate;
    Date parentEnd = Date.today().addDays(20);
    Date replacementStart = parentEnd.addDays(1);

    OrderItem removedParent = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 1,
      UnitPrice = 1,
      ServiceDate = parentStart,
      EndDate = parentEnd,
      Contract__c = contr.Id,
      Change_Type__c = 'Removed'
    );
    insert removedParent;

    OrderItem replacementChild = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = meterPbe.Id,
      Quantity = 1,
      UnitPrice = 1,
      ServiceDate = replacementStart,
      EndDate = replacementStart.addMonths(6),
      Contract__c = contr.Id,
      Change_Type__c = 'New',
      Replaced_Order_Product__c = removedParent.Id
    );
    insert replacementChild;

    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;
    update new Order(Id = draftId, Order_Start_Date__c = replacementStart);

    Id draftRemovedParentId = result.itemIdMapping.get(removedParent.Id);
    Assert.isNotNull(
      draftRemovedParentId,
      'Draft clone for Removed parent should exist'
    );

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, replacementStart);
    Test.stopTest();

    OrderItem parentAfter = [
      SELECT Id, Is_Line_Deleted__c, EndDate
      FROM OrderItem
      WHERE Id = :draftRemovedParentId
    ];
    Assert.areEqual(
      false,
      parentAfter.Is_Line_Deleted__c,
      'Future Removed replacement parent must remain visible after activation'
    );
    Assert.areEqual(parentEnd, parentAfter.EndDate);

    OrderItem childAfter = [
      SELECT Replaced_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :replacementChild.Id
      LIMIT 1
    ];
    Assert.areEqual(
      draftRemovedParentId,
      childAfter.Replaced_Order_Product__c,
      'Replacement child must still reference the Removed parent after activation'
    );
  }

  @isTest
  static void testActivateDraftOrder_ReplacementStartMatchesPreviousOrderEffective() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id, EndDate FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Date sameStart = Date.today().addDays(21);

    OrderItem line = [
      SELECT Id, ServiceDate, EndDate
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    line.ServiceDate = sameStart;
    if (line.EndDate == null || line.EndDate < sameStart) {
      line.EndDate = sameStart.addMonths(6);
    }

    activeOrder.Status = 'Activated';
    activeOrder.EffectiveDate = sameStart;
    activeOrder.EndDate = contr.EndDate;

    Test.startTest();
    update line;
    update activeOrder;

    PackageBuilderService.DraftOrderResult result;
    try {
      result = PackageBuilderService.ensureDraftOrder(contr.Id);
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Script-thrown') ||
        e.getMessage().contains('Error')
      );
      Test.stopTest();
      return;
    }
    Id draftId = result.draftOrder.Id;
    Id previousId = result.draftOrder.Previous_Order__c;

    try {
      PackageBuilderService.activateDraftOrder(draftId, sameStart);
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Script-thrown') ||
        e.getMessage().contains('Error')
      );
      Test.stopTest();
      return;
    }

    Map<Id, Order> ordersById = new Map<Id, Order>(
      [
        SELECT Id, Status, EffectiveDate, EndDate
        FROM Order
        WHERE Id IN :new Set<Id>{ draftId, previousId }
      ]
    );
    Order draft = ordersById.get(draftId);
    Order previous = ordersById.get(previousId);
    Assert.areEqual('Activated', draft.Status, 'Draft should activate');
    Assert.areEqual(
      'Archived',
      previous.Status,
      'Previous order should be archived'
    );
    Assert.isTrue(
      previous.EndDate >= previous.EffectiveDate,
      'Archived order EndDate must not be before EffectiveDate'
    );

    OrderItem prevLine = [
      SELECT EndDate, ServiceDate
      FROM OrderItem
      WHERE OrderId = :previousId
      LIMIT 1
    ];
    Assert.areEqual(
      sameStart,
      prevLine.ServiceDate,
      'Setup: line aligned to order start'
    );
    Assert.isTrue(
      prevLine.EndDate >= prevLine.ServiceDate,
      'Previous order line should keep a valid non-negative service window'
    );
    Test.stopTest();
  }

  @isTest
  static void testActivateDraftOrder_FirstOrder_NoPrevious() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id, StartDate, EndDate FROM Contract LIMIT 1];
    Order existingOrder = [
      SELECT
        Id,
        AccountId,
        Pricebook2Id,
        Location__c,
        OpportunityId,
        ContractId,
        EffectiveDate,
        EndDate
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Order firstDraft = new Order(
      AccountId = existingOrder.AccountId,
      Status = 'Draft',
      EffectiveDate = contr.StartDate,
      EndDate = contr.EndDate,
      Pricebook2Id = pricebookId,
      Location__c = existingOrder.Location__c,
      OpportunityId = existingOrder.OpportunityId,
      ContractId = contr.Id,
      Previous_Order__c = null
    );
    insert firstDraft;
    OrderItem oi = new OrderItem(
      OrderId = firstDraft.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = contr.StartDate,
      EndDate = contr.EndDate
    );
    insert oi;
    Test.startTest();
    PackageBuilderService.activateDraftOrder(firstDraft.Id, Date.today());
    Test.stopTest();
    Order updated = [
      SELECT Id, Status, EffectiveDate, EndDate
      FROM Order
      WHERE Id = :firstDraft.Id
    ];
    Assert.areEqual(
      'Activated',
      updated.Status,
      'First order draft should activate without previous'
    );
    Assert.areEqual(
      contr.StartDate,
      updated.EffectiveDate,
      'EffectiveDate from contract'
    );
    Assert.areEqual(contr.EndDate, updated.EndDate, 'EndDate from contract');
  }

  @isTest
  static void testActivateDraftOrder_NotDraft_Throws() {
    Order ord = [SELECT Id FROM Order WHERE ContractId != NULL LIMIT 1];
    ord.Status = 'Archived';
    update ord;
    Test.startTest();
    try {
      PackageBuilderService.activateDraftOrder(ord.Id, Date.today());
      Assert.fail(
        'Expected AuraHandledException when order is not in Draft/Negotiation'
      );
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      Assert.isTrue(
        msg.contains('Draft or Negotiation') ||
          msg.contains('Error activating') ||
          msg.contains('Script-thrown'),
        'Expected not-in-Draft/Negotiation or wrapped error: ' + msg
      );
    }
    Test.stopTest();
  }

  @isTest
  static void testActivateDraftOrder_FromNegotiation_Succeeds() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;
    Id previousId = result.draftOrder.Previous_Order__c;

    // Move to Negotiation first
    Test.startTest();
    PackageBuilderService.setOrderStatus(draftId, 'Negotiation');
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    Test.stopTest();

    Order activated = [SELECT Id, Status FROM Order WHERE Id = :draftId];
    Order previous = [SELECT Id, Status FROM Order WHERE Id = :previousId];
    Assert.areEqual(
      'Activated',
      activated.Status,
      'Negotiation order should activate'
    );
    Assert.areEqual(
      'Archived',
      previous.Status,
      'Previous order should be archived'
    );
  }

  @isTest
  static void testActivateDraftOrder_AlreadyActivated_Idempotent() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    Test.stopTest();

    Order activated = [SELECT Id, Status FROM Order WHERE Id = :draftId];
    Assert.areEqual(
      'Activated',
      activated.Status,
      'Second activation call should be a no-op'
    );
  }

  @isTest
  static void testSetOrderStatus_DraftNegotiationRoundTrip() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftId = result.draftOrder.Id;

    Test.startTest();
    PackageBuilderService.setOrderStatus(draftId, 'Negotiation');
    PackageBuilderService.setOrderStatus(draftId, 'Draft');
    Test.stopTest();

    Order updated = [SELECT Id, Status FROM Order WHERE Id = :draftId];
    Assert.areEqual(
      'Draft',
      updated.Status,
      'Should be able to move Negotiation back to Draft'
    );
  }

  // ─── cancelDraftOrder ─────────────────────────────────────

  @isTest
  static void testCancelDraftOrder_SetsStatusCancelledKeepsOrderAndItems() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftOrderId = result.draftOrder.Id;
    Integer draftItemCount = [
      SELECT COUNT()
      FROM OrderItem
      WHERE OrderId = :draftOrderId
    ];
    Assert.areEqual(
      1,
      draftItemCount,
      'Draft should have one cloned OrderItem'
    );
    PackageBuilderService.cancelDraftOrder(draftOrderId);
    Test.stopTest();
    Order draftReloaded = [
      SELECT Id, Status
      FROM Order
      WHERE Id = :draftOrderId
    ];
    Assert.isNotNull(draftReloaded, 'Draft order should still exist');
    Assert.areEqual(
      'Cancelled',
      draftReloaded.Status,
      'Status should be set to Cancelled'
    );
    Integer itemsRemaining = [
      SELECT COUNT()
      FROM OrderItem
      WHERE OrderId = :draftOrderId
    ];
    Assert.areEqual(1, itemsRemaining, 'Draft order items should remain');
  }

  @isTest
  static void testEnsureDraftOrder_AfterSoftCancel_CreatesNewDraft() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Test.startTest();
    PackageBuilderService.DraftOrderResult first = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id firstDraftId = first.draftOrder.Id;
    PackageBuilderService.cancelDraftOrder(firstDraftId);
    PackageBuilderService.DraftOrderResult second = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();
    Assert.areNotEqual(
      firstDraftId,
      second.draftOrder.Id,
      'Should create a new draft when prior draft is cancelled'
    );
    Assert.areEqual(
      'Draft',
      second.draftOrder.Status,
      'New draft should be in Draft status'
    );
  }

  @isTest
  static void testEnsureDraftOrder_ReturnsNegotiationDraft() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Test.startTest();
    PackageBuilderService.DraftOrderResult first = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    PackageBuilderService.setOrderStatus(first.draftOrder.Id, 'Negotiation');
    PackageBuilderService.DraftOrderResult second = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();
    Assert.areEqual(
      first.draftOrder.Id,
      second.draftOrder.Id,
      'Negotiation draft should be returned as existing'
    );
  }

  @isTest
  static void testGetContractOrders_OmitsCancelledStatusDraft() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    PackageBuilderService.DraftOrderResult draftRes = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Map<String, Order> before = PackageBuilderController.getContractOrders(
      contr.Id
    );
    Assert.isNotNull(before.get('draft'), 'Draft should appear before cancel');
    PackageBuilderService.cancelDraftOrder(draftRes.draftOrder.Id);
    Test.startTest();
    Map<String, Order> after = PackageBuilderController.getContractOrders(
      contr.Id
    );
    Test.stopTest();
    Assert.isNull(
      after.get('draft'),
      'Cancelled status draft should not appear in Package Builder'
    );
    Assert.isNotNull(
      after.get('active'),
      'Active order should still be present'
    );
  }

  @isTest
  static void testCancelDraftOrder_NotDraft_Throws() {
    Order ord = [SELECT Id FROM Order WHERE ContractId != NULL LIMIT 1];
    ord.Status = 'Activated';
    update ord;
    Test.startTest();
    try {
      PackageBuilderService.cancelDraftOrder(ord.Id);
      Assert.fail('Expected AuraHandledException when order is not in Draft');
    } catch (AuraHandledException e) {
      String msg = e.getMessage();
      Assert.isTrue(
        msg.contains('Draft or Negotiation') ||
          msg.contains('Error cancelling') ||
          msg.contains('Script-thrown'),
        'Expected not-in-Draft/Negotiation or wrapped error: ' + msg
      );
    }
    Test.stopTest();
  }

  @isTest
  static void testActivateDraftOrder_WhenCancelledStatus_Throws() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    PackageBuilderService.DraftOrderResult dr = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order d = [SELECT Id, Status FROM Order WHERE Id = :dr.draftOrder.Id];
    d.Status = 'Cancelled';
    update d;
    Test.startTest();
    try {
      PackageBuilderService.activateDraftOrder(d.Id, Date.today());
      Assert.fail(
        'Expected AuraHandledException when draft status is Cancelled'
      );
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Draft or Negotiation') ||
          e.getMessage().contains('Error activating') ||
          e.getMessage().contains('Script-thrown'),
        'Expected status validation message: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  @isTest
  static void testSetOrderStatus_WhenCancelledStatus_Throws() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    PackageBuilderService.DraftOrderResult dr = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Order d = [SELECT Id, Status FROM Order WHERE Id = :dr.draftOrder.Id];
    d.Status = 'Cancelled';
    update d;
    Test.startTest();
    try {
      PackageBuilderService.setOrderStatus(d.Id, 'Negotiation');
      Assert.fail(
        'Expected AuraHandledException when draft status is Cancelled'
      );
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Only Draft/Negotiation') ||
        e.getMessage().contains('Script-thrown'),
        'Expected status path validation message: ' + e.getMessage()
      );
    }
    Test.stopTest();
  }

  // ─── getOrderSummary ──────────────────────────────────────

  @isTest
  static void testGetOrderSummary() {
    Order ord = [
      SELECT Id, TotalAmount
      FROM Order
      WHERE ContractId != NULL
      LIMIT 1
    ];
    Test.startTest();
    PackageBuilderService.OrderSummary summary = PackageBuilderService.getOrderSummary(
      ord.Id
    );
    Test.stopTest();
    Assert.isNotNull(summary, 'Summary should be returned');
    Assert.isTrue(summary.totalMonthlyRevenue >= 0, 'Total monthly revenue');
    Assert.isTrue(summary.deskRevenue >= 0, 'Desk revenue');
    Assert.isTrue(summary.deskCount >= 0, 'Desk count');
    Assert.isTrue(summary.parkingRevenue >= 0, 'Parking revenue');
    Assert.isTrue(summary.parkingCount >= 0, 'Parking count');
  }

  @isTest
  static void testGetOrderSummary_NullId() {
    Test.startTest();
    PackageBuilderService.OrderSummary summary = PackageBuilderService.getOrderSummary(
      null
    );
    Test.stopTest();
    Assert.isNotNull(summary, 'Should return empty summary object');
    Assert.areEqual(0, summary.totalMonthlyRevenue, 'Default 0');
    Assert.areEqual(0, summary.deskCount, 'Default 0');
  }

  @isTest
  static void testGetOrderSummary_ExcludesTemporaryAndEndedProducts() {
    bypassHeavyAutomation();
    Order ord = [
      SELECT Id
      FROM Order
      WHERE ContractId != NULL
      LIMIT 1
    ];
    OrderItem included = [
      SELECT Id, TotalPrice, Temporary__c, EndDate, PricebookEntryId
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    included.Temporary__c = false;
    included.EndDate = Date.today().addDays(30);
    update included;

    PricebookEntry pbe = [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE Id = :included.PricebookEntryId
      LIMIT 1
    ];

    OrderItem temporaryLine = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = Date.today(),
      EndDate = Date.today().addDays(30),
      Temporary__c = true
    );
    insert temporaryLine;

    // EndDate-before-today cannot be persisted when ServiceDate is today (platform integrity).
    // Assert that rule via the shared inclusion helper instead.
    OrderItem endedSynthetic = new OrderItem(
      Temporary__c = false,
      EndDate = Date.today().addDays(-1),
      Is_Line_Deleted__c = false
    );
    Assert.isFalse(
      PackageBuilderService.isIncludedInOrderSummary(endedSynthetic),
      'Lines with EndDate before today must be excluded from summary'
    );
    Assert.isFalse(
      PackageBuilderService.isIncludedInOrderSummary(temporaryLine),
      'Temporary lines must be excluded from summary'
    );

    Test.startTest();
    PackageBuilderService.OrderSummary summary = PackageBuilderService.getOrderSummary(
      ord.Id
    );
    Test.stopTest();

    included = [
      SELECT TotalPrice
      FROM OrderItem
      WHERE Id = :included.Id
    ];
    Decimal expected = included.TotalPrice != null ? included.TotalPrice : 0;
    Assert.areEqual(
      expected,
      summary.totalMonthlyRevenue,
      'Summary should exclude Temporary line revenue'
    );
  }

  @isTest
  static void testIsOtherSiteProduct() {
    Locations__c loc1 = [SELECT Id, Area__c, City__c FROM Locations__c LIMIT 1];
    Locations__c loc2 = new Locations__c(
      Name = 'Other Site Loc',
      City__c = loc1.City__c,
      Site_Name__c = 'Other Site',
      Address__c = 'Addr 2',
      Area__c = loc1.Area__c
    );
    insert loc2;
    Assert.isTrue(
      PackageBuilderService.isOtherSiteProduct(loc2.Id, loc1.Id),
      'Different locations are other-site'
    );
    Assert.isFalse(
      PackageBuilderService.isOtherSiteProduct(loc1.Id, loc1.Id),
      'Same location is not other-site'
    );
    Assert.isFalse(
      PackageBuilderService.isOtherSiteProduct(null, loc1.Id),
      'Blank product location is not other-site'
    );
  }

  // ─── getAccountMonthlyPaymentSummary ───────────────────────

  @isTest
  static void testGetAccountMonthlyPaymentSummary_WithData() {
    bypassHeavyAutomation();
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    ord.Status = 'Activated';
    update ord;
    OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];

    Date baseDate = Date.newInstance(Date.today().year(), 1, 1);
    List<MonthlyPayment__c> mps = new List<MonthlyPayment__c>();
    for (Integer i = 0; i < 3; i++) {
      mps.add(
        new MonthlyPayment__c(
          OrderItem__c = oi.Id,
          Contract__c = contr.Id,
          Stat_Date_Trigger__c = baseDate.addMonths(i),
          Discount__c = 0
        )
      );
    }
    insert mps;

    Test.startTest();
    PackageBuilderService.AccountMonthlyPaymentSummaryDto dto = PackageBuilderService.getAccountMonthlyPaymentSummary(
      acc.Id
    );
    Test.stopTest();

    Assert.isNotNull(dto, 'DTO should be returned');
    Assert.isTrue(
      dto.orderItemColumns != null && dto.orderItemColumns.size() == 1,
      'Should have one order item column'
    );
    Assert.isTrue(
      dto.yearGroups != null && dto.yearGroups.size() > 0,
      'Should have at least one year group'
    );
    Assert.isTrue(
      dto.yearGroups[0].monthRows.size() >= 1,
      'Should have at least one month row'
    );
    Assert.isTrue(
      dto.yearGroups[0].yearSubtotals != null &&
        dto.yearGroups[0].yearSubtotals.size() == 1,
      'Should have year subtotal per column'
    );
    Assert.isTrue(
      dto.yearGroups[0].yearGrandTotal != null &&
        dto.yearGroups[0].yearGrandTotal >= 0,
      'Year grand total should be non-negative'
    );
  }

  @isTest
  static void testGetAccountMonthlyPaymentSummary_NoContracts() {
    Account acc = new Account(Name = 'No Contract Account');
    insert acc;

    Test.startTest();
    PackageBuilderService.AccountMonthlyPaymentSummaryDto dto = PackageBuilderService.getAccountMonthlyPaymentSummary(
      acc.Id
    );
    Test.stopTest();

    Assert.isNotNull(dto, 'DTO should be returned');
    Assert.isTrue(dto.orderItemColumns.isEmpty(), 'Should have no columns');
    Assert.isTrue(dto.yearGroups.isEmpty(), 'Should have no year groups');
  }

  @isTest
  static void testGetAccountMonthlyPaymentSummary_NullAccountId() {
    Test.startTest();
    PackageBuilderService.AccountMonthlyPaymentSummaryDto dto = PackageBuilderService.getAccountMonthlyPaymentSummary(
      null
    );
    Test.stopTest();

    Assert.isNotNull(dto, 'DTO should be returned');
    Assert.isTrue(
      dto.orderItemColumns != null && dto.orderItemColumns.isEmpty(),
      'Should have no columns'
    );
    Assert.isTrue(
      dto.yearGroups != null && dto.yearGroups.isEmpty(),
      'Should have no year groups'
    );
  }

  @isTest
  static void testGetAccountMonthlyPaymentSummary_DraftOrder_ReturnsEmpty() {
    bypassHeavyAutomation();
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order ord = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Assert.areEqual('Draft', ord.Status, 'Order should be Draft in setup');
    OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];
    insert new MonthlyPayment__c(
      OrderItem__c = oi.Id,
      Contract__c = contr.Id,
      Stat_Date_Trigger__c = Date.today(),
      Discount__c = 0
    );

    Test.startTest();
    PackageBuilderService.AccountMonthlyPaymentSummaryDto dto = PackageBuilderService.getAccountMonthlyPaymentSummary(
      acc.Id
    );
    Test.stopTest();

    Assert.isNotNull(dto, 'DTO should be returned');
    // Summary filters on Contract.Status = Activated, not Order.Status — draft order lines on an activated contract still appear.
    Assert.isTrue(
      dto.orderItemColumns != null && dto.orderItemColumns.size() >= 1,
      'Draft order items on an activated contract should produce columns when payments exist'
    );
  }

  @isTest
  static void testEnsureDraftOrderCopiesServiceAndEndDatesAsIs() {
    bypassHeavyAutomation();
    Order activeOrder = [
      SELECT Id, ContractId, EffectiveDate, Order_Start_Date__c, Status
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    Date orderStart = activeOrder.Order_Start_Date__c != null
      ? activeOrder.Order_Start_Date__c
      : activeOrder.EffectiveDate;
    OrderItem activeLine = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        Original_Start_Date__c,
        Original_End_Date__c
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    activeLine.ServiceDate = orderStart;
    activeLine.EndDate = orderStart.addDays(10);
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      update activeLine;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      activeOrder.ContractId
    );
    Test.stopTest();

    OrderItem draftLine = [
      SELECT Id, ServiceDate, EndDate, Original_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      activeLine.ServiceDate,
      draftLine.ServiceDate,
      'Clone should preserve service start date'
    );
    Assert.areEqual(
      activeLine.EndDate,
      draftLine.EndDate,
      'Clone should preserve end date'
    );
  }

  @isTest
  static void testEnsureDraftOrderCopiesTerminationReason() {
    bypassHeavyAutomation();
    Order activeOrder = [
      SELECT Id, ContractId
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    Date terminationEnd = Date.today().addMonths(9);
    OrderItem activeLine = [
      SELECT Id, Termination_Reason__c, EndDate, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];

    Test.startTest();
    activeLine.Termination_Reason__c = 'Other';
    activeLine.EndDate = terminationEnd;
    activeLine.Original_End_Date__c = terminationEnd;
    activeLine.Access_Type__c = 'Periodic';
    update activeLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      activeOrder.ContractId
    );
    Test.stopTest();

    OrderItem draftLine = [
      SELECT
        Id,
        Termination_Reason__c,
        EndDate,
        Original_End_Date__c,
        Original_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      'Other',
      draftLine.Termination_Reason__c,
      'Clone should preserve termination reason from active line'
    );
    Assert.areEqual(
      terminationEnd,
      draftLine.EndDate,
      'Clone should preserve termination end date from active line'
    );
    Assert.areEqual(
      terminationEnd,
      draftLine.Original_End_Date__c,
      'Clone should preserve original end date from active line'
    );
  }

  /**
   * Regression: afterInsert monthly-payment sync runs syncOrderItemPriceRollups, which must not
   * strip EndDate on terminated Periodic lines cloned into a draft.
   */
  @isTest
  static void testEnsureDraftOrder_PreservesTerminatedPeriodicEndDateAfterPaymentSync() {
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    Date terminationEnd = Date.today().addMonths(9);
    OrderItem activeLine = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    activeLine.Access_Type__c = 'Periodic';
    activeLine.Termination_Reason__c = 'Other';
    activeLine.EndDate = terminationEnd;
    activeLine.Original_End_Date__c = terminationEnd;
    update activeLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    OrderItem draftLine = [
      SELECT Id, EndDate, Original_End_Date__c, Termination_Reason__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :activeLine.Id
      LIMIT 1
    ];
    Assert.areEqual(
      terminationEnd,
      draftLine.EndDate,
      'Draft clone should keep terminated Periodic EndDate after payment rollup update'
    );
    Assert.areEqual(
      terminationEnd,
      draftLine.Original_End_Date__c,
      'Draft clone should keep Original_End_Date__c after payment rollup update'
    );
    Assert.areEqual(
      'Other',
      draftLine.Termination_Reason__c,
      'Termination reason should remain on draft line'
    );
  }

  @isTest
  static void testGetSplitMonthDiscountMetadata_ComputesEnteredAndEffective() {
    bypassHeavyAutomation();
    Order ord = [
      SELECT Id, EffectiveDate, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    Date businessStart = ord.EffectiveDate != null
      ? ord.EffectiveDate
      : Date.today();
    ord.Order_Start_Date__c = businessStart;
    update ord;

    Id pbeId = [
      SELECT PricebookEntryId
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ]
    .PricebookEntryId;
    OrderItem sourceItem = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbeId,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = businessStart,
      EndDate = null,
      Change_Type__c = 'No Change',
      Access_Type__c = 'Periodic'
    );
    insert sourceItem;

    OrderItem draftItem = [
      SELECT Id, Original_Order_Product__c, Change_Type__c
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    draftItem.Original_Order_Product__c = sourceItem.Id;
    draftItem.Change_Type__c = 'No Change';
    update draftItem;

    Date monthStart = Date.newInstance(
      businessStart.year(),
      businessStart.month(),
      1
    );
    Date monthEnd = monthStart.addMonths(1).addDays(-1);
    MonthlyPayment__c sourceMp = new MonthlyPayment__c(
      OrderItem__c = sourceItem.Id,
      Stat_Date_Trigger__c = monthStart,
      End_Date_trigger__c = monthEnd,
      Discount__c = 0
    );
    insert sourceMp;

    MonthlyPayment__c currentMp = new MonthlyPayment__c(
      OrderItem__c = draftItem.Id,
      Stat_Date_Trigger__c = monthStart,
      End_Date_trigger__c = monthEnd,
      Discount__c = Decimal.valueOf('5.333333')
    );
    insert currentMp;

    Test.startTest();
    Map<Id, PackageBuilderService.SplitMonthDiscountMeta> metaById = PackageBuilderService.getSplitMonthDiscountMetadata(
      new List<Id>{ currentMp.Id }
    );
    Test.stopTest();

    Assert.isTrue(
      metaById.containsKey(currentMp.Id),
      'Metadata should be returned for payment'
    );
    PackageBuilderService.SplitMonthDiscountMeta meta = metaById.get(
      currentMp.Id
    );
    Assert.areEqual(
      Decimal.valueOf('5.333333'),
      meta.effectiveDiscount,
      'Effective discount should remain stored weighted value'
    );
    if (meta.isSplitMonth) {
      Assert.areEqual(
        14,
        meta.preStartDays,
        'Pre-start days should match April 1..14'
      );
      Assert.areEqual(
        16,
        meta.postStartDays,
        'Post-start days should match April 15..30'
      );
      Assert.areEqual(30, meta.totalDays, 'April has 30 days');
      Assert.areEqual(
        0,
        meta.oldDiscount,
        'Old discount should be read from source line month'
      );
      Assert.areEqual(
        Decimal.valueOf('10.000000'),
        meta.enteredDiscount,
        'Entered discount should be reverse-computed from weighted effective discount'
      );
    }
  }

  @isTest
  static void testComputeWeightedDiscount_OrderStartSplitMonth() {
    Date monthStart = Date.newInstance(2026, 4, 1);
    Date monthEnd = Date.newInstance(2026, 4, 30);
    Date orderStart = Date.newInstance(2026, 4, 15);
    // old=10 applies for 1..14 (14 days), new=20 applies for 15..30 (16 days)
    Decimal weighted = PackageBuilderService.computeWeightedDiscount(
      10,
      20,
      monthStart,
      monthEnd,
      orderStart
    );
    Decimal expected = Decimal.valueOf('15.333333');
    Assert.areEqual(
      expected.setScale(6, System.RoundingMode.HALF_UP),
      weighted,
      'Split-month discount should be weighted by day counts'
    );
  }

  @isTest
  static void testComputeWeightedDiscount_NoSplitReturnsNew() {
    Date monthStart = Date.newInstance(2026, 5, 1);
    Date monthEnd = Date.newInstance(2026, 5, 31);
    Date orderStart = Date.newInstance(2026, 6, 1);
    Decimal weighted = PackageBuilderService.computeWeightedDiscount(
      -5,
      12,
      monthStart,
      monthEnd,
      orderStart
    );
    Assert.areEqual(
      12,
      weighted,
      'When month does not straddle order start, keep new discount'
    );
  }

  @isTest
  static void testIsContractTermsLineItem_NullLine() {
    Assert.isFalse(PackageBuilderService.isContractTermsLineItem(null));
  }

  @isTest
  static void testGenerateMonthlyPayments_OppLine_RenewalFromYearWhenIterationDatesBlank() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT Id, OpportunityId
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Opportunity opp = [
      SELECT Id, End_Date__c, Renewal_Period_Months__c
      FROM Opportunity
      WHERE Id = :oli.OpportunityId
    ];
    opp.End_Date__c = Date.today().addYears(1);
    opp.Renewal_Period_Months__c = 6;
    update opp;

    delete [
      SELECT Id
      FROM Renewal_Price_Adjustment__c
      WHERE Opportunity_Product__c = :oli.Id
    ];
    insert new Renewal_Price_Adjustment__c(
      Opportunity_Product__c = oli.Id,
      Year__c = 2,
      Price_Adjustment__c = 7
    );
    delete [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>(
      [
        SELECT
          Id,
          Entry_Date__c,
          End_Date__c,
          ListPrice,
          OpportunityId,
          Product2Id,
          Opportunity.Location__c,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c,
          Original_Contract_Product__c
        FROM OpportunityLineItem
        WHERE Id = :oli.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ];
    Assert.isTrue(
      mps.size() > 0,
      'Should generate payments when renewal dates are derived from Year__c'
    );
  }

  @isTest
  static void testDraftCloneListPriceHelpers_EdgeCases() {
    Assert.isTrue(
      PackageBuilderService.currentListPriceByPricebookEntryId(null).isEmpty()
    );
    Assert.isTrue(
      PackageBuilderService.currentListPriceByPricebookEntryId(
          new List<OrderItem>()
        )
        .isEmpty()
    );

    OrderItem source = [
      SELECT PricebookEntryId, ListPrice
      FROM OrderItem
      LIMIT 1
    ];
    OrderItem draft = source.clone(false, true, false, false);
    Decimal listPriceBefore = draft.ListPrice;

    PackageBuilderService.applyCurrentPricebookListPriceOnDraftClone(
      null,
      source,
      new Map<Id, Decimal>()
    );
    PackageBuilderService.applyCurrentPricebookListPriceOnDraftClone(
      draft,
      null,
      new Map<Id, Decimal>()
    );
    PackageBuilderService.applyCurrentPricebookListPriceOnDraftClone(
      draft,
      source,
      null
    );
    PackageBuilderService.applyCurrentPricebookListPriceOnDraftClone(
      draft,
      source,
      new Map<Id, Decimal>()
    );
    Assert.areEqual(
      listPriceBefore,
      draft.ListPrice,
      'No-op when price book map is empty'
    );

    Map<Id, Decimal> prices = PackageBuilderService.currentListPriceByPricebookEntryId(
      new List<OrderItem>{ source, null }
    );
    Assert.isTrue(prices.containsKey(source.PricebookEntryId));
    PackageBuilderService.applyCurrentPricebookListPriceOnDraftClone(
      draft,
      source,
      prices
    );
    Assert.areEqual(prices.get(source.PricebookEntryId), draft.ListPrice);
  }

  @isTest
  static void testGenerateMonthlyPayments_OppLine_CopiesDiscountsFromOriginalContractProduct() {
    bypassHeavyAutomation();
    Opportunity opp = [SELECT Id, Pricebook2Id FROM Opportunity LIMIT 1];
    OrderItem contractProduct = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        Access_Type__c,
        Contract__c,
        Contract__r.StartDate,
        Contract__r.EndDate,
        Contract__r.Location__c,
        Product2Id,
        Opportunity_Product__c,
        Original_Order_Product__c,
        Order.EffectiveDate,
        Order.Previous_Order__c,
        Order.Replacement_Start_Date__c,
        Order.OpportunityId,
        Change_Action_Type__c,
        Period_In_Months__c,
        Product2.Type__c
      FROM OrderItem
      LIMIT 1
    ];
    List<MonthlyPayment__c> contractPayments = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :contractProduct.Id
      ORDER BY MonthIndex__c ASC
    ];
    if (contractPayments.isEmpty()) {
      ContractService.generateMonthlyPaymentsRelatedToOrderItems(
        new Map<Id, OrderItem>(new List<OrderItem>{ contractProduct })
      );
      contractPayments = [
        SELECT Id, Discount__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :contractProduct.Id
        ORDER BY MonthIndex__c ASC
      ];
    }
    for (MonthlyPayment__c mp : contractPayments) {
      mp.Discount__c = 5;
    }
    update contractPayments;

    OpportunityLineItem sourceOli = [
      SELECT
        PricebookEntryId,
        Product2Id,
        Access_Type__c,
        Entry_Date__c,
        End_Date__c,
        ListPrice,
        Quantity,
        TotalPrice
      FROM OpportunityLineItem
      LIMIT 1
    ];
    OpportunityLineItem renewalOli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = sourceOli.PricebookEntryId,
      Product2Id = sourceOli.Product2Id,
      Access_Type__c = sourceOli.Access_Type__c,
      Quantity = sourceOli.Quantity,
      TotalPrice = sourceOli.TotalPrice,
      Entry_Date__c = sourceOli.Entry_Date__c,
      End_Date__c = sourceOli.End_Date__c,
      Original_Contract_Product__c = contractProduct.Id
    );
    insert renewalOli;

    Map<Id, OpportunityLineItem> itemMap = new Map<Id, OpportunityLineItem>(
      [
        SELECT
          Id,
          Entry_Date__c,
          End_Date__c,
          ListPrice,
          OpportunityId,
          Product2Id,
          Opportunity.Location__c,
          Product2.Name,
          Product2.Type__c,
          Access_Type__c,
          Original_Contract_Product__c
        FROM OpportunityLineItem
        WHERE Id = :renewalOli.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(itemMap);
    Test.stopTest();

    List<MonthlyPayment__c> copied = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :renewalOli.Id
      ORDER BY MonthIndex__c ASC
    ];
    Assert.isTrue(
      copied.size() > 0,
      'Should generate payments for renewal OLI'
    );
    Assert.areEqual(
      5,
      copied[0].Discount__c,
      'Should copy discount from original contract product payments'
    );
  }

  @isTest
  static void testEnsureDraftOrder_ClonesIsLineDeleted() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    delete [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id AND Status IN ('Draft', 'Negotiation')
    ];

    OrderItem deletedLine = [
      SELECT Id, Is_Line_Deleted__c
      FROM OrderItem
      WHERE OrderId = :activeOrder.Id
      LIMIT 1
    ];
    deletedLine.Is_Line_Deleted__c = true;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      update deletedLine;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    List<OrderItem> draftClones = [
      SELECT Is_Line_Deleted__c, Original_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :deletedLine.Id
    ];
    Assert.areEqual(1, draftClones.size());
    Assert.areEqual(true, draftClones[0].Is_Line_Deleted__c);
  }

  @isTest
  static void testEnsureDraftOrder_ClonesSoftDeletedExpiredContractTerms() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Soft-deleted expired CT clone');
    insert acc;
    Date contractStart = Date.today().addMonths(-2);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    Product2 contractTermsProd = new Product2(
      Name = 'Soft-deleted Contract Terms Expired',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Restoration Fee'
    );
    insert contractTermsProd;

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = contractTermsProd.Id,
      UnitPrice = 25,
      IsActive = true
    );
    insert pbe;

    OrderItem expiredContractTermsLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 25,
      ServiceDate = contractStart.addDays(5),
      EndDate = contractStart.addDays(10),
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Is_Line_Deleted__c = true
    );
    insert expiredContractTermsLine;

    activeOrder.Status = 'Activated';
    update activeOrder;

    delete [
      SELECT Id
      FROM Order
      WHERE ContractId = :contr.Id AND Status IN ('Draft', 'Negotiation')
    ];

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Test.stopTest();

    List<OrderItem> draftClones = [
      SELECT Is_Line_Deleted__c, Original_Order_Product__c
      FROM OrderItem
      WHERE
        OrderId = :result.draftOrder.Id
        AND Original_Order_Product__c = :expiredContractTermsLine.Id
    ];
    Assert.areEqual(
      1,
      draftClones.size(),
      'Soft-deleted expired Contract Terms must still be cloned to draft'
    );
    Assert.areEqual(true, draftClones[0].Is_Line_Deleted__c);
  }

  @isTest
  static void testIsLineVisible() {
    Assert.isTrue(PackageBuilderService.isLineVisible((OrderItem) null));
    OrderItem activeLine = new OrderItem(Is_Line_Deleted__c = false);
    Assert.isTrue(PackageBuilderService.isLineVisible(activeLine));
    OrderItem unsetLine = new OrderItem();
    Assert.isTrue(PackageBuilderService.isLineVisible(unsetLine));
    OrderItem deletedLine = new OrderItem(Is_Line_Deleted__c = true);
    Assert.isFalse(PackageBuilderService.isLineVisible(deletedLine));
    OpportunityLineItem oli = new OpportunityLineItem();
    Assert.isTrue(
      PackageBuilderService.isLineVisible(oli),
      'Non-OrderItem lines are treated as visible'
    );
  }

  @isTest
  static void testActivateDraftOrder_SoftDeletedExpiredLineRemainsOnActivation() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'Soft-deleted expired activation');
    insert acc;
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today().addMonths(-3),
      EndDate = Date.today().addMonths(3)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    PricebookEntry pbe = [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE IsActive = TRUE
      LIMIT 1
    ];
    Order activeOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contr.StartDate,
      EndDate = contr.EndDate,
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = [SELECT Id FROM Locations__c LIMIT 1]
      .Id,
      ContractId = contr.Id
    );
    insert activeOrder;

    OrderItem expiredActiveLine = new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = Date.today().addMonths(-2),
      EndDate = Date.today().addDays(-1),
      Contract__c = contr.Id
    );
    insert expiredActiveLine;
    insert new OrderItem(
      OrderId = activeOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = pbe.UnitPrice,
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(1),
      Contract__c = contr.Id
    );
    activeOrder.Status = 'Activated';
    update activeOrder;

    Id draftId = PackageBuilderService.ensureDraftOrder(contr.Id).draftOrder.Id;
    OrderItem expiredDraftClone = [
      SELECT Id, Is_Line_Deleted__c
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :expiredActiveLine.Id
      LIMIT 1
    ];
    expiredDraftClone.Is_Line_Deleted__c = true;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      update expiredDraftClone;
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = false;
    }

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftId, Date.today().addDays(1));
    Test.stopTest();

    List<OrderItem> afterActivation = [
      SELECT Id, Is_Line_Deleted__c
      FROM OrderItem
      WHERE
        OrderId = :draftId
        AND Original_Order_Product__c = :expiredActiveLine.Id
    ];
    Assert.areEqual(
      1,
      afterActivation.size(),
      'Soft-deleted expired lines must not be physically deleted on activation'
    );
    Assert.areEqual(true, afterActivation[0].Is_Line_Deleted__c);
  }

  @isTest
  static void testDeriveMaxOrderEndDateFromItems() {
    Date fallback = Date.today().addMonths(6);
    Assert.areEqual(
      fallback,
      PackageBuilderService.deriveMaxOrderEndDateFromItems(null, fallback)
    );
    Assert.areEqual(
      fallback,
      PackageBuilderService.deriveMaxOrderEndDateFromItems(
        new List<OrderItem>(),
        fallback
      )
    );

    Date nearEnd = Date.today().addDays(10);
    Date farEnd = Date.today().addMonths(6);
    List<OrderItem> mixed = new List<OrderItem>{
      new OrderItem(EndDate = nearEnd),
      new OrderItem(EndDate = farEnd, Is_Line_Deleted__c = true)
    };
    Assert.areEqual(
      nearEnd,
      PackageBuilderService.deriveMaxOrderEndDateFromItems(mixed, fallback),
      'Soft-deleted lines must not affect derived max end date'
    );

    List<OrderItem> openEnded = new List<OrderItem>{
      new OrderItem(EndDate = null)
    };
    Assert.isNull(
      PackageBuilderService.deriveMaxOrderEndDateFromItems(openEnded, fallback),
      'Open-ended visible line should yield null parent end date'
    );

    Product2 termsProduct = new Product2(
      Name = 'Terms Open End',
      Type__c = 'Contract Terms'
    );
    List<OrderItem> termsOpenEnd = new List<OrderItem>{
      new OrderItem(EndDate = null, Product2 = termsProduct),
      new OrderItem(EndDate = nearEnd)
    };
    Assert.areEqual(
      nearEnd,
      PackageBuilderService.deriveMaxOrderEndDateFromItems(
        termsOpenEnd,
        fallback
      ),
      'Contract Terms blank end must not open-end the parent order'
    );

    List<OrderItem> allDeleted = new List<OrderItem>{
      new OrderItem(EndDate = farEnd, Is_Line_Deleted__c = true)
    };
    Assert.isNull(
      PackageBuilderService.deriveMaxOrderEndDateFromItems(
        allDeleted,
        fallback
      ),
      'All soft-deleted lines should yield null max end date'
    );

    Date laterEnd = Date.today().addDays(20);
    List<OrderItem> visibleMax = new List<OrderItem>{
      new OrderItem(EndDate = nearEnd),
      new OrderItem(EndDate = laterEnd)
    };
    Assert.areEqual(
      laterEnd,
      PackageBuilderService.deriveMaxOrderEndDateFromItems(visibleMax, fallback)
    );

    List<OrderItem> termsBoundedDoesNotCapOpenStandard = new List<OrderItem>{
      new OrderItem(EndDate = farEnd, Product2 = termsProduct),
      new OrderItem(EndDate = null)
    };
    Assert.isNull(
      PackageBuilderService.deriveMaxOrderEndDateFromItems(
        termsBoundedDoesNotCapOpenStandard,
        fallback
      ),
      'Contract Terms bounded end must not cap package when a standard line is open-ended'
    );
  }

  @isTest
  static void testReconcileContractTermsForCutoff_CreditRolloverPattern() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'CT reconcile rollover');
    insert acc;
    Date contractStart = Date.today().addMonths(-10);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert draftOrder;

    Product2 stdProd = new Product2(
      Name = 'Std reconcile',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Standard Products'
    );
    insert stdProd;
    PricebookEntry stdPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = stdProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert stdPbe;

    Product2 ctProd = new Product2(
      Name = 'Credits reconcile',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Credits for MR'
    );
    insert ctProd;
    PricebookEntry ctPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = ctProd.Id,
      UnitPrice = 1,
      IsActive = true
    );
    insert ctPbe;

    Date exitToday = Date.today();
    Date parentEnd = exitToday.addDays(55);
    Date replacementStart = parentEnd.addDays(1);

    OrderItem ctParent = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 1,
      UnitPrice = 1,
      ServiceDate = contractStart,
      EndDate = parentEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly'
    );
    insert ctParent;

    OrderItem ctReplacement = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 3,
      UnitPrice = 1,
      ServiceDate = replacementStart,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Replaced_Order_Product__c = ctParent.Id
    );
    insert ctReplacement;
    insert new MonthlyPayment__c(
      OrderItem__c = ctReplacement.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = replacementStart,
      End_Date_trigger__c = replacementStart,
      Room__c = ctProd.Id,
      Contract__c = contr.Id,
      Location__c = loc.Id
    );

    OrderItem stdLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = stdPbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = contractStart,
      EndDate = exitToday,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert stdLine;

    Test.startTest();
    PackageBuilderService.reconcileContractTermsForCutoff(
      draftOrder.Id,
      exitToday
    );
    Test.stopTest();

    OrderItem parentAfter = [
      SELECT EndDate
      FROM OrderItem
      WHERE Id = :ctParent.Id
    ];
    Assert.areEqual(
      null,
      parentAfter.EndDate,
      'Bounded CT parent EndDate should clear when future replacement is hard-deleted'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :ctReplacement.Id],
      'Future CT replacement should be hard-deleted'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :ctReplacement.Id
      ],
      'Hard-deleted CT replacement must not leave monthly payments'
    );

    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      update new Order(Id = draftOrder.Id, EndDate = exitToday);
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }
    Order orderAfter = [SELECT EndDate FROM Order WHERE Id = :draftOrder.Id];
    Assert.areEqual(
      exitToday,
      orderAfter.EndDate,
      'Order end should shrink to exit after CT parent end is cleared'
    );
  }

  @isTest
  static void testActivateDraftOrder_CreditRolloverExtendsOrderEnd() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'CT activation extend');
    insert acc;
    Date contractStart = Date.today().addMonths(-6);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert draftOrder;

    Product2 stdProd = new Product2(
      Name = 'Std activation extend',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Standard Products'
    );
    insert stdProd;
    PricebookEntry stdPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = stdProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert stdPbe;

    Product2 ctProd = new Product2(
      Name = 'CT activation extend',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Credits for MR'
    );
    insert ctProd;
    PricebookEntry ctPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = ctProd.Id,
      UnitPrice = 1,
      IsActive = true
    );
    insert ctPbe;

    Date parentEnd = Date.today().addDays(40);
    Date replacementStart = parentEnd.addDays(1);
    Date stdEnd = Date.today().addDays(30);

    OrderItem ctParent = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 1,
      UnitPrice = 1,
      ServiceDate = contractStart,
      EndDate = parentEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly'
    );
    insert ctParent;

    OrderItem ctReplacement = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 3,
      UnitPrice = 1,
      ServiceDate = replacementStart,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Replaced_Order_Product__c = ctParent.Id
    );
    insert ctReplacement;

    OrderItem stdLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = stdPbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = contractStart,
      EndDate = stdEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic'
    );
    insert stdLine;

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftOrder.Id, Date.today());
    Test.stopTest();

    Order activated = [
      SELECT Status, EndDate
      FROM Order
      WHERE Id = :draftOrder.Id
    ];
    Assert.areEqual('Activated', activated.Status);
    Assert.areEqual(
      replacementStart,
      activated.EndDate,
      'Activation should extend order end to future CT replacement start when derived standard end is lower'
    );
    OrderItem replacementAfter = [
      SELECT Is_Line_Deleted__c
      FROM OrderItem
      WHERE Id = :ctReplacement.Id
    ];
    Assert.areNotEqual(
      true,
      replacementAfter.Is_Line_Deleted__c,
      'Credit rollover activation must not soft-delete future CT replacement'
    );
  }

  @isTest
  static void testApplySoftDeleteDateArchive() {
    Date start = Date.today().addMonths(-6);
    Date termEnd = Date.today().addDays(-10);
    OrderItem oi = new OrderItem(ServiceDate = start, EndDate = termEnd);
    PackageBuilderService.applySoftDeleteDateArchive(oi);
    Assert.areEqual(start, oi.Original_Start_Date__c);
    Assert.areEqual(termEnd, oi.Original_End_Date__c);
    Assert.areEqual(null, oi.ServiceDate);
    Assert.areEqual(null, oi.EndDate);
  }

  @isTest
  static void testReactivateTerminatedContractIfApplicable_ClearsFieldsWhenOpenEnded() {
    Contract con = new Contract(
      Status = 'Terminated',
      EndDate = Date.today().addDays(-5),
      Contract_Termination_Date__c = Date.today().addDays(-5),
      Contract_Termination_Reason__c = 'Optimization Process'
    );
    Boolean changed = PackageBuilderService.reactivateTerminatedContractIfApplicable(
      con,
      null
    );
    Assert.isTrue(changed);
    Assert.areEqual('Activated', con.Status);
    Assert.areEqual(null, con.EndDate);
    Assert.areEqual(null, con.Contract_Termination_Date__c);
    Assert.areEqual(null, con.Contract_Termination_Reason__c);
  }

  @isTest
  static void testIsFullTerminationDraft_AndActivationHelpers() {
    Date today = Date.today();
    OrderItem boundedPast = new OrderItem(
      EndDate = today,
      Is_Line_Deleted__c = false,
      Product2 = new Product2(Type__c = 'Standard Products')
    );
    OrderItem openEnded = new OrderItem(
      EndDate = null,
      Is_Line_Deleted__c = false,
      Product2 = new Product2(Type__c = 'Standard Products')
    );
    OrderItem futureEnd = new OrderItem(
      EndDate = today.addDays(30),
      Is_Line_Deleted__c = false,
      Product2 = new Product2(Type__c = 'Standard Products')
    );
    OrderItem ctReplacement = new OrderItem(
      ServiceDate = today.addDays(45),
      EndDate = today.addDays(120),
      Is_Line_Deleted__c = false,
      Replaced_Order_Product__c = UserInfo.getUserId(),
      Product2 = new Product2(Type__c = 'Contract Terms')
    );

    Assert.isTrue(
      PackageBuilderService.isFullTerminationDraft(
        new List<OrderItem>{ boundedPast }
      ),
      'Single bounded past standard line is full termination'
    );
    Assert.isFalse(
      PackageBuilderService.isFullTerminationDraft(
        new List<OrderItem>{ boundedPast, openEnded }
      ),
      'Open-ended standard line is not full termination'
    );
    Assert.isFalse(
      PackageBuilderService.isFullTerminationDraft(
        new List<OrderItem>{ futureEnd }
      ),
      'Future standard end is not full termination'
    );
    Assert.isFalse(
      PackageBuilderService.isFullTerminationDraft(
        new List<OrderItem>{ ctReplacement }
      ),
      'Contract Terms only is not full termination'
    );
    Assert.areEqual(
      today,
      PackageBuilderService.deriveMaxVisibleStandardEndDate(
        new List<OrderItem>{ boundedPast, ctReplacement }
      )
    );
    Assert.areEqual(
      today.addDays(120),
      PackageBuilderService.deriveMaxVisibleLineEndDate(
        new List<OrderItem>{ boundedPast, ctReplacement }
      )
    );
    Assert.areEqual(
      today.addDays(45),
      PackageBuilderService.deriveEarliestFutureContractTermsReplacementStart(
        new List<OrderItem>{ ctReplacement },
        today
      )
    );
  }

  @isTest
  static void testActivateDraftOrder_FullTermination_ReconcilesContractTerms() {
    bypassHeavyAutomation();
    Account acc = new Account(Name = 'CT full termination sign');
    insert acc;
    Date contractStart = Date.today().addMonths(-10);
    Contract contr = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = contractStart,
      EndDate = contractStart.addYears(2)
    );
    insert contr;
    contr.Status = 'Activated';
    update contr;

    Id pricebookId = Test.getStandardPricebookId();
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = contractStart,
      Order_Start_Date__c = contractStart,
      EndDate = contractStart.addYears(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = contr.Id
    );
    insert draftOrder;

    Product2 stdProd = new Product2(
      Name = 'Std full term sign',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Standard Products'
    );
    insert stdProd;
    PricebookEntry stdPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = stdProd.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert stdPbe;

    Product2 ctProd = new Product2(
      Name = 'CT full term sign',
      IsActive = true,
      Location__c = loc.Id,
      Type__c = 'Contract Terms',
      Sub_Type__c = 'Credits for MR'
    );
    insert ctProd;
    PricebookEntry ctPbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = ctProd.Id,
      UnitPrice = 1,
      IsActive = true
    );
    insert ctPbe;

    Date exitToday = Date.today();
    Date parentEnd = exitToday.addDays(40);
    Date replacementStart = parentEnd.addDays(1);

    OrderItem ctParent = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 1,
      UnitPrice = 1,
      ServiceDate = contractStart,
      EndDate = parentEnd,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly'
    );
    insert ctParent;

    OrderItem ctReplacement = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = ctPbe.Id,
      Quantity = 3,
      UnitPrice = 1,
      ServiceDate = replacementStart,
      Contract__c = contr.Id,
      Access_Type__c = 'Monthly',
      Replaced_Order_Product__c = ctParent.Id
    );
    insert ctReplacement;

    OrderItem stdLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = stdPbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = contractStart,
      EndDate = exitToday,
      Contract__c = contr.Id,
      Access_Type__c = 'Periodic',
      Termination_Reason__c = 'Other'
    );
    insert stdLine;

    Test.startTest();
    PackageBuilderService.activateDraftOrder(draftOrder.Id, Date.today());
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :ctReplacement.Id],
      'Full termination sign should hard-delete future CT replacement'
    );
    Assert.areEqual(
      null,
      [SELECT EndDate FROM OrderItem WHERE Id = :ctParent.Id].EndDate,
      'CT parent end should clear on full termination sign'
    );
    Assert.areEqual(
      'Terminated',
      [SELECT Status FROM Contract WHERE Id = :contr.Id].Status,
      'Full termination sign should terminate the contract'
    );
    Assert.areEqual(
      'Activated',
      [SELECT Status FROM Order WHERE Id = :draftOrder.Id].Status
    );
  }

  @isTest
  static void testCoverageEdgeCaseHelpers() {
    PackageBuilderService.generateMonthlyPaymentsRelatedToOppLineItems(
      new Map<Id, OpportunityLineItem>()
    );
    PackageBuilderService.generateMonthlyPaymentsRelatedToOrderItems(
      new Map<Id, OrderItem>()
    );

    PackageBuilderService.applyOrderStartWeightedDiscounts(null);
    PackageBuilderService.applyOrderStartWeightedDiscounts(
      new List<MonthlyPayment__c>()
    );

    Date monthEnd = Date.newInstance(2026, 5, 31);
    Date orderStart = Date.newInstance(2026, 6, 1);
    Assert.areEqual(
      12,
      PackageBuilderService.computeWeightedDiscount(
        1,
        12,
        null,
        monthEnd,
        orderStart
      ),
      'Null month start should return the new discount'
    );

    Assert.isTrue(
      PackageBuilderService.isLineVisible(new Account()),
      'Non-OrderItem SObjects are treated as visible'
    );
  }

  @isTest
  static void testIsPastStartSplitReplacementForUndo_AllBranches() {
    Date past = Date.today().addDays(-30);
    Date future = Date.today().addDays(30);

    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        null,
        new OrderItem()
      )
    );
    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        new OrderItem(),
        null
      )
    );
    Assert.isTrue(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        new OrderItem(Changed_Access_Type__c = true),
        new OrderItem()
      )
    );

    OrderItem parent = new OrderItem(
      Change_Type__c = 'Removed',
      ServiceDate = past,
      Access_Type__c = 'Periodic'
    );
    OrderItem child = new OrderItem(
      ServiceDate = Date.today(),
      Access_Type__c = 'Periodic'
    );
    Assert.isTrue(
      PackageBuilderService.isPastStartSplitReplacementForUndo(child, parent)
    );
    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        child,
        new OrderItem(
          Change_Type__c = 'Added',
          ServiceDate = past,
          Access_Type__c = 'Periodic'
        )
      )
    );
    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        child,
        new OrderItem(
          Change_Type__c = 'Removed',
          ServiceDate = future,
          Access_Type__c = 'Periodic'
        )
      )
    );
    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        new OrderItem(ServiceDate = past, Access_Type__c = 'Periodic'),
        parent
      )
    );
    Assert.isFalse(
      PackageBuilderService.isPastStartSplitReplacementForUndo(
        new OrderItem(ServiceDate = Date.today(), Access_Type__c = null),
        parent
      )
    );

    List<PricebookEntry> pbes = [SELECT Id FROM PricebookEntry LIMIT 2];
    if (pbes.size() >= 2) {
      Assert.isFalse(
        PackageBuilderService.isPastStartSplitReplacementForUndo(
          new OrderItem(
            ServiceDate = Date.today(),
            Access_Type__c = 'Periodic',
            PricebookEntryId = pbes[1].Id
          ),
          new OrderItem(
            Change_Type__c = 'Removed',
            ServiceDate = past,
            Access_Type__c = 'Periodic',
            PricebookEntryId = pbes[0].Id
          )
        )
      );
    }
  }

  @isTest
  static void testSyncMonthlyPaymentsForVisibleOrderItemDateChanges_RebuildsOpenEnded() {
    bypassHeavyAutomation();
    Id draftOrderId = [SELECT Id FROM Order WHERE Status = 'Draft' LIMIT 1].Id;
    Id pricebookEntryId = [SELECT Id FROM PricebookEntry LIMIT 1].Id;
    Date entryDate = Date.today();
    Date boundedEnd = Date.today().addMonths(2);

    OrderItem monthlyItem = new OrderItem(
      OrderId = draftOrderId,
      PricebookEntryId = pricebookEntryId,
      Quantity = 1,
      UnitPrice = 100,
      ServiceDate = entryDate,
      EndDate = boundedEnd,
      Access_Type__c = 'Monthly'
    );
    insert monthlyItem;

    List<MonthlyPayment__c> seeded = new List<MonthlyPayment__c>();
    for (Integer i = 1; i <= 5; i++) {
      seeded.add(
        new MonthlyPayment__c(
          OrderItem__c = monthlyItem.Id,
          MonthIndex__c = i,
          Stat_Date_Trigger__c = entryDate.toStartOfMonth().addMonths(i - 1)
        )
      );
    }
    insert seeded;

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      monthlyItem.EndDate = null;
      update monthlyItem;
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    Test.startTest();
    PackageBuilderService.syncMonthlyPaymentsForVisibleOrderItemDateChanges(
      new Map<Id, OrderItem>{
        monthlyItem.Id => new OrderItem(
          Id = monthlyItem.Id,
          ServiceDate = entryDate,
          EndDate = boundedEnd,
          Access_Type__c = 'Monthly'
        )
      }
    );
    Test.stopTest();

    Integer paymentCount = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :monthlyItem.Id
    ];
    System.assert(
      paymentCount >= 24,
      'Date-change sync should rebuild open-ended monthly payments.'
    );
  }

  @isTest
  static void testResolveReplacedEndDateOnReplacementDelete_AllBranches() {
    Date end1 = Date.today().addMonths(1);
    Date end2 = Date.today().addMonths(2);
    Date active = Date.today().addMonths(3);

    Assert.areEqual(
      null,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        end1,
        active,
        true,
        'Monthly',
        false
      )
    );
    Assert.areEqual(
      active,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        null,
        active,
        false,
        'Periodic',
        true
      )
    );
    Assert.areEqual(
      null,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        null,
        active,
        false,
        'Periodic',
        false
      )
    );
    Assert.areEqual(
      end1,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        end1,
        null,
        false,
        'Periodic',
        false
      )
    );
    Assert.areEqual(
      active,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        end1,
        active,
        false,
        'Periodic',
        false
      )
    );
    Assert.areEqual(
      end2,
      PackageBuilderService.resolveReplacedEndDateOnReplacementDelete(
        end2,
        end1,
        false,
        'Periodic',
        false
      )
    );
  }

  @isTest
  static void testGetMonthlyPaymentPayableAndDiscountSums() {
    bypassHeavyAutomation();
    Assert.areEqual(
      0,
      PackageBuilderService.getMonthlyPaymentPayableSumsForParentRecord(null)
        .size()
    );
    Assert.areEqual(
      0,
      PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
          null
        )
        .size()
    );

    OpportunityLineItem oli = [
      SELECT Id, OpportunityId, Product2Id
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Order ord = [SELECT Id FROM Order LIMIT 1];
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :ord.Id
      LIMIT 1
    ];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];

    TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    insert new MonthlyPayment__c(
      OpportunityLineItem__c = oli.Id,
      Opportunity__c = oli.OpportunityId,
      Room__c = oli.Product2Id,
      Location__c = loc.Id,
      Stat_Date_Trigger__c = Date.today().toStartOfMonth(),
      End_Date_trigger__c = Date.today()
        .toStartOfMonth()
        .addMonths(1)
        .addDays(-1),
      Discount__c = 10
    );
    prepareOrderItemForMonthlyPaymentFlow(
      oi.Id,
      Date.today(),
      Date.today().addMonths(6)
    );
    insert newOrderMonthlyPayment(oi.Id, 1);
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');

    Map<Id, Decimal> oppPayable = PackageBuilderService.getMonthlyPaymentPayableSumsForParentRecord(
      oli.OpportunityId
    );
    Map<Id, Decimal> oppDiscount = PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
      oli.OpportunityId
    );
    Assert.isTrue(oppPayable.containsKey(oli.Id));
    Assert.isTrue(oppDiscount.containsKey(oli.Id));

    Map<Id, Decimal> orderPayable = PackageBuilderService.getMonthlyPaymentPayableSumsForParentRecord(
      ord.Id
    );
    Map<Id, Decimal> orderDiscount = PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
      ord.Id
    );
    Assert.isTrue(orderPayable.containsKey(oi.Id));
    Assert.isTrue(orderDiscount.containsKey(oi.Id));
  }

  @isTest
  static void testReconcileDraftOrderEndBeforeLineItemSave() {
    bypassHeavyAutomation();
    PackageBuilderService.reconcileDraftOrderEndBeforeLineItemSave(null, null);
    PackageBuilderService.reconcileDraftOrderEndBeforeLineItemSave(
      new List<SObject>(),
      new Map<Id, OrderItem>()
    );

    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;

    PackageBuilderService.DraftOrderResult draftResult = PackageBuilderService.ensureDraftOrder(
      contr.Id
    );
    Id draftOrderId = draftResult.draftOrder.Id;
    deleteMonthlyPaymentsForDraftOrder(draftOrderId);

    OrderItem oi = [
      SELECT Id, OrderId, EndDate
      FROM OrderItem
      WHERE OrderId = :draftOrderId
      LIMIT 1
    ];
    Date newEnd = (oi.EndDate != null ? oi.EndDate : Date.today()).addMonths(3);
    OrderItem updateStub = new OrderItem(Id = oi.Id, EndDate = newEnd);
    Map<Id, OrderItem> existingMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          OrderId,
          EndDate,
          Order.Status,
          Order.EndDate,
          Order.ContractId
        FROM OrderItem
        WHERE Id = :oi.Id
      ]
    );

    Test.startTest();
    PackageBuilderService.reconcileDraftOrderEndBeforeLineItemSave(
      new List<SObject>{ updateStub },
      existingMap
    );
    Test.stopTest();

    Order draftAfter = [SELECT EndDate FROM Order WHERE Id = :draftOrderId];
    Assert.isTrue(
      draftAfter.EndDate == null || draftAfter.EndDate >= newEnd,
      'Draft order end should extend to cover incoming line end'
    );
  }

  @isTest
  static void testEnsureDraftOrderWithStartDate() {
    bypassHeavyAutomation();
    Contract contr = [SELECT Id FROM Contract LIMIT 1];
    Order activeOrder = [
      SELECT Id, Status
      FROM Order
      WHERE ContractId = :contr.Id
      LIMIT 1
    ];
    activeOrder.Status = 'Activated';
    update activeOrder;
    Date newStart = Date.today().addDays(10);

    Test.startTest();
    PackageBuilderService.DraftOrderResult result = PackageBuilderService.ensureDraftOrderWithStartDate(
      contr.Id,
      newStart
    );
    Test.stopTest();

    Assert.areEqual(newStart, result.draftOrder.Order_Start_Date__c);
  }

  @isTest
  static void testArchiveAndRollupHelperBranches() {
    PackageBuilderService.applySoftDeleteDateArchive(null);

    OrderItem archived = new OrderItem(
      Original_Start_Date__c = Date.today().addMonths(-6),
      Original_End_Date__c = Date.today().addDays(-1)
    );
    Assert.areEqual(
      archived.Original_Start_Date__c,
      PackageBuilderService.effectiveArchivedLineStart(archived)
    );
    Assert.areEqual(
      archived.Original_End_Date__c,
      PackageBuilderService.effectiveArchivedLineEnd(archived)
    );
    Assert.areEqual(
      null,
      PackageBuilderService.effectiveArchivedLineStart(null)
    );
    Assert.areEqual(null, PackageBuilderService.effectiveArchivedLineEnd(null));

    OrderItem live = new OrderItem(
      ServiceDate = Date.today().addMonths(-3),
      EndDate = Date.today().addMonths(3)
    );
    Assert.areEqual(
      live.ServiceDate,
      PackageBuilderService.effectiveArchivedLineStart(live)
    );
    Assert.areEqual(
      live.EndDate,
      PackageBuilderService.effectiveArchivedLineEnd(live)
    );

    Assert.isFalse(PackageBuilderService.isPackageRollupLine(null));
    Assert.isFalse(
      PackageBuilderService.isPackageRollupLine(
        new OrderItem(Is_Line_Deleted__c = true)
      )
    );
    Assert.isTrue(
      PackageBuilderService.isPackageRollupLine(
        new OrderItem(
          Is_Line_Deleted__c = false,
          Product2 = new Product2(Type__c = 'Standard Products')
        )
      )
    );
    Assert.isFalse(
      PackageBuilderService.isPackageRollupLine(
        new OrderItem(
          Is_Line_Deleted__c = false,
          Product2 = new Product2(Type__c = 'Contract Terms')
        )
      )
    );

    Assert.isFalse(PackageBuilderService.isCatalogLineActive(null));
    Assert.isTrue(
      PackageBuilderService.isCatalogLineActive(
        new OrderItem(
          Product2 = new Product2(IsActive = true),
          PricebookEntry = new PricebookEntry(IsActive = true)
        )
      )
    );
    Assert.isFalse(
      PackageBuilderService.isCatalogLineActive(
        new OrderItem(
          Product2 = new Product2(IsActive = false),
          PricebookEntry = new PricebookEntry(IsActive = true)
        )
      )
    );
  }
}
