@isTest(IsParallel=false)
private class RecurringPriceIncreaseService_Test {
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
      Name = 'RPI Loc',
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

    Account acc = new Account(Name = 'RPI Account');
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
    OpportunityLineItem oliPeriodic = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      TotalPrice = 1000,
      Access_Type__c = 'Periodic',
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
    insert new List<OpportunityLineItem>{ oliMonthly, oliPeriodic, oliRent };

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
    OrderItem oiLate = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = 'Periodic',
      ServiceDate = today.addMonths(2),
      EndDate = today.addMonths(14)
    );
    insert new List<OrderItem>{ oiMonthly, oiLate };
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
    Decimal percentPoints
  ) {
    RecurringPriceIncreaseService.RuleDraft draft = new RecurringPriceIncreaseService.RuleDraft();
    draft.frequencyMonths = frequencyMonths;
    draft.startDate = startDate;
    draft.increaseType = RecurringPriceIncreaseService.TYPE_PERCENT;
    draft.increasePercent = percentPoints;
    return draft;
  }

  private static RecurringPriceIncreaseService.RuleDraft valueDraft(
    Integer frequencyMonths,
    Date startDate,
    Decimal amount
  ) {
    RecurringPriceIncreaseService.RuleDraft draft = new RecurringPriceIncreaseService.RuleDraft();
    draft.frequencyMonths = frequencyMonths;
    draft.startDate = startDate;
    draft.increaseType = RecurringPriceIncreaseService.TYPE_VALUE;
    draft.increaseAmount = amount;
    return draft;
  }

  /**
   * Monthly_Payment_Update_dates flow owns Stat_Date_Trigger__c from
   * OrderItem.ServiceDate + MonthIndex__c. Insert MonthIndex only, then
   * re-query actual month starts for assertions.
   */
  private static void prepareOrderItemServiceWindow(
    Id orderItemId,
    Date serviceDate,
    Date endDate,
    String accessType
  ) {
    OrderItem current = [
      SELECT
        Id,
        OrderId,
        Order.Order_Start_Date__c,
        Order.EffectiveDate,
        Order.ContractId,
        Order.Contract.StartDate
      FROM OrderItem
      WHERE Id = :orderItemId
    ];
    // Keep Contract.StartDate <= Order start <= OrderItem.ServiceDate.
    Date orderStart = current.Order.Order_Start_Date__c != null
      ? current.Order.Order_Start_Date__c
      : current.Order.EffectiveDate;
    if (
      serviceDate != null && (orderStart == null || serviceDate < orderStart)
    ) {
      if (current.Order.ContractId != null) {
        Date contractStart = current.Order.Contract != null
          ? current.Order.Contract.StartDate
          : null;
        if (contractStart == null || serviceDate < contractStart) {
          update new Contract(
            Id = current.Order.ContractId,
            StartDate = serviceDate
          );
        }
      }
      update new Order(
        Id = current.OrderId,
        Order_Start_Date__c = serviceDate,
        EffectiveDate = serviceDate
      );
    }
    update new OrderItem(
      Id = orderItemId,
      ServiceDate = serviceDate,
      EndDate = endDate,
      Access_Type__c = accessType
    );
  }

  private static List<MonthlyPayment__c> insertMonthsByIndex(
    Id orderItemId,
    List<Integer> monthIndexes,
    Decimal seedDiscount
  ) {
    List<MonthlyPayment__c> rows = new List<MonthlyPayment__c>();
    for (Integer idx : monthIndexes) {
      rows.add(
        new MonthlyPayment__c(
          OrderItem__c = orderItemId,
          MonthIndex__c = idx,
          Discount__c = seedDiscount,
          User_Price_Adjustment__c = 0
        )
      );
    }
    insert rows;
    return [
      SELECT
        Id,
        MonthIndex__c,
        Start_date__c,
        Stat_Date_Trigger__c,
        Discount__c,
        User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :orderItemId
      ORDER BY MonthIndex__c ASC
    ];
  }

  private static Date mpMonth(MonthlyPayment__c mp) {
    if (mp.Start_date__c != null) {
      return mp.Start_date__c.toStartOfMonth();
    }
    return mp.Stat_Date_Trigger__c == null
      ? null
      : mp.Stat_Date_Trigger__c.toStartOfMonth();
  }

  private static Map<Date, MonthlyPayment__c> paymentsByMonth(Id orderItemId) {
    Map<Date, MonthlyPayment__c> byMonth = new Map<Date, MonthlyPayment__c>();
    for (MonthlyPayment__c mp : [
      SELECT
        Id,
        MonthIndex__c,
        Start_date__c,
        Stat_Date_Trigger__c,
        Discount__c,
        User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :orderItemId
    ]) {
      Date key = mpMonth(mp);
      if (key != null) {
        byMonth.put(key, mp);
      }
    }
    return byMonth;
  }

  @isTest
  static void math_stepCount_startMonthIsStepOne() {
    Date start = Date.newInstance(2026, 4, 15);
    System.assertEquals(
      1,
      RecurringPriceIncreaseService.stepCount(
        Date.newInstance(2026, 4, 1),
        start,
        3
      )
    );
    System.assertEquals(
      1,
      RecurringPriceIncreaseService.stepCount(
        Date.newInstance(2026, 5, 1),
        start,
        3
      )
    );
    System.assertEquals(
      1,
      RecurringPriceIncreaseService.stepCount(
        Date.newInstance(2026, 6, 1),
        start,
        3
      )
    );
    System.assertEquals(
      2,
      RecurringPriceIncreaseService.stepCount(
        Date.newInstance(2026, 7, 1),
        start,
        3
      )
    );
    System.assertEquals(
      0,
      RecurringPriceIncreaseService.stepCount(
        Date.newInstance(2026, 3, 1),
        start,
        3
      )
    );
  }

  @isTest
  static void math_percentCompounds_andFixedAdds() {
    Date start = Date.newInstance(2026, 4, 1);
    System.assertEquals(
      1100,
      RecurringPriceIncreaseService.commercialAt(
        1000,
        start,
        3,
        RecurringPriceIncreaseService.TYPE_PERCENT,
        10,
        null,
        Date.newInstance(2026, 4, 1)
      )
    );
    System.assertEquals(
      1210,
      RecurringPriceIncreaseService.commercialAt(
        1000,
        start,
        3,
        RecurringPriceIncreaseService.TYPE_PERCENT,
        10,
        null,
        Date.newInstance(2026, 7, 1)
      )
    );
    System.assertEquals(
      1100,
      RecurringPriceIncreaseService.commercialAt(
        1000,
        start,
        6,
        RecurringPriceIncreaseService.TYPE_VALUE,
        null,
        100,
        Date.newInstance(2026, 4, 1)
      )
    );
    System.assertEquals(
      1200,
      RecurringPriceIncreaseService.commercialAt(
        1000,
        start,
        6,
        RecurringPriceIncreaseService.TYPE_VALUE,
        null,
        100,
        Date.newInstance(2026, 10, 1)
      )
    );
  }

  @isTest
  static void saveRules_percentProjectsFuture_leavesPastUntouched() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, ServiceDate, EndDate, UnitPrice, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Decimal originalUnit = oi.UnitPrice;
    Date today = Date.today();
    Date serviceStart = today.addMonths(-2);
    Date endDate = today.addMonths(14);
    // MonthIndex 1/3/6 => serviceStart, today, today+3 under the date flow.
    prepareOrderItemServiceWindow(
      oi.Id,
      serviceStart,
      endDate,
      oi.Access_Type__c
    );
    List<MonthlyPayment__c> seeded = insertMonthsByIndex(
      oi.Id,
      new List<Integer>{ 1, 3, 6 },
      0
    );
    System.assertEquals(3, seeded.size(), 'Expected three flow-dated payments');
    Date pastMonth = mpMonth(seeded[0]);
    Date thisMonth = mpMonth(seeded[1]);
    Date nextStep = mpMonth(seeded[2]);
    System.assertEquals(serviceStart.toStartOfMonth(), pastMonth);
    System.assertEquals(today.toStartOfMonth(), thisMonth);
    System.assertEquals(today.toStartOfMonth().addMonths(3), nextStep);
    System.assert(
      pastMonth < today.toStartOfMonth(),
      'First month must be past'
    );

    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(3, today, 10);

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    Test.stopTest();

    System.assertEquals(1, res.updatedLines);
    System.assert(res.updatedPayments >= 2, 'Future/current months projected');

    Map<Date, MonthlyPayment__c> byMonth = paymentsByMonth(oi.Id);
    System.assert(byMonth.containsKey(pastMonth), 'Past month row missing');
    System.assert(byMonth.containsKey(thisMonth), 'Current month row missing');
    System.assert(byMonth.containsKey(nextStep), 'Next step row missing');
    System.assertEquals(
      0,
      byMonth.get(pastMonth).Discount__c,
      'Past months must stay untouched'
    );
    System.assertEquals(
      10,
      byMonth.get(thisMonth).Discount__c.setScale(0),
      'Start month is step 1 (+10 percent)'
    );
    System.assertEquals(
      21,
      byMonth.get(nextStep).Discount__c.setScale(0),
      'Next frequency step compounds to +21 percent'
    );

    OrderItem stamped = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Current_Effective_Price__c,
        UnitPrice,
        EndDate,
        ServiceDate
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, stamped.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(1100, stamped.Current_Effective_Price__c);
    System.assertEquals(originalUnit, stamped.UnitPrice, 'UnitPrice unchanged');
    System.assertEquals(
      endDate,
      stamped.EndDate,
      'End date unchanged by rule save'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Iteration__c WHERE Order_Product__c = :oi.Id],
      'Must not create Iterations'
    );
  }

  @isTest
  static void saveRules_fixedValueAddsEachStep() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(14),
      oi.Access_Type__c
    );
    // MonthIndex 1 and 7 => today and today+6 months.
    List<MonthlyPayment__c> seeded = insertMonthsByIndex(
      oi.Id,
      new List<Integer>{ 1, 7 },
      0
    );
    Date thisMonth = mpMonth(seeded[0]);
    Date nextStep = mpMonth(seeded[1]);
    System.assertEquals(today.toStartOfMonth(), thisMonth);
    System.assertEquals(today.toStartOfMonth().addMonths(6), nextStep);

    Test.startTest();
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      valueDraft(6, today, 100),
      false
    );
    Test.stopTest();

    Map<Date, MonthlyPayment__c> byMonth = paymentsByMonth(oi.Id);
    System.assert(byMonth.containsKey(thisMonth), 'Current month row missing');
    System.assert(byMonth.containsKey(nextStep), 'Next step row missing');
    System.assertEquals(10, byMonth.get(thisMonth).Discount__c.setScale(0));
    System.assertEquals(20, byMonth.get(nextStep).Discount__c.setScale(0));
  }

  @isTest
  static void saveRules_minStartValidation() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(
      3,
      Date.today().addDays(-1),
      5
    );
    Boolean thrown = false;
    try {
      RecurringPriceIncreaseService.saveRules(
        new List<Id>{ oi.Id },
        draft,
        false
      );
    } catch (AuraHandledException e) {
      thrown = true;
    }
    System.assertEquals(true, thrown, 'Past start date must be blocked');
  }

  @isTest
  static void saveRules_skipsIneligibleRentWithMessage() {
    bypassHeavyAutomation();
    OpportunityLineItem rent = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Rent'
      LIMIT 1
    ];
    OpportunityLineItem monthly = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRules(
      new List<Id>{ rent.Id, monthly.Id },
      percentDraft(3, Date.today(), 5),
      false
    );
    Test.stopTest();

    System.assertEquals(1, res.updatedLines);
    System.assertEquals(1, res.skippedIneligible);
    System.assertEquals(1, res.skippedMessages.size());
    System.assert(
      res.skippedMessages[0].contains('Monthly and Periodic'),
      res.skippedMessages[0]
    );
    OpportunityLineItem rentAfter = [
      SELECT Recurring_Price_Increase_Enabled__c
      FROM OpportunityLineItem
      WHERE Id = :rent.Id
    ];
    System.assertEquals(false, rentAfter.Recurring_Price_Increase_Enabled__c);
  }

  @isTest
  static void saveRules_mixedServiceDates_effectiveStartPerLine() {
    bypassHeavyAutomation();
    OrderItem early = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    OrderItem late = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    Date today = Date.today();
    Date lateService = today.addMonths(2);
    prepareOrderItemServiceWindow(
      early.Id,
      today,
      today.addMonths(12),
      early.Access_Type__c
    );
    prepareOrderItemServiceWindow(
      late.Id,
      lateService,
      lateService.addMonths(12),
      late.Access_Type__c
    );
    // Early: current month. Late: only its service-start month.
    // Past-before-effective covered in percent test.
    List<MonthlyPayment__c> earlyMps = insertMonthsByIndex(
      early.Id,
      new List<Integer>{ 1 },
      0
    );
    List<MonthlyPayment__c> lateMps = insertMonthsByIndex(
      late.Id,
      new List<Integer>{ 1 },
      0
    );
    Date earlyMonth = mpMonth(earlyMps[0]);
    Date lateMonth = mpMonth(lateMps[0]);
    System.assertEquals(today.toStartOfMonth(), earlyMonth);
    System.assertEquals(lateService.toStartOfMonth(), lateMonth);

    Test.startTest();
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ early.Id, late.Id },
      percentDraft(3, today, 10),
      false
    );
    Test.stopTest();

    early = [SELECT Id, ServiceDate FROM OrderItem WHERE Id = :early.Id];
    late = [SELECT Id, ServiceDate FROM OrderItem WHERE Id = :late.Id];
    Date earlyEffective = RecurringPriceIncreaseService.resolveEffectiveStart(
      today,
      early.ServiceDate,
      today,
      today
    );
    Date lateEffective = RecurringPriceIncreaseService.resolveEffectiveStart(
      today,
      late.ServiceDate,
      today,
      today
    );
    System.assertEquals(today, earlyEffective);
    System.assertEquals(lateService, lateEffective);
    System.assert(
      lateEffective > earlyEffective,
      'Late line effective start must be after early line'
    );

    Map<Date, MonthlyPayment__c> earlyByMonth = paymentsByMonth(early.Id);
    Map<Date, MonthlyPayment__c> lateByMonth = paymentsByMonth(late.Id);
    System.assertEquals(
      10,
      earlyByMonth.get(earlyMonth).Discount__c.setScale(0),
      'Early line projects on its effective start month'
    );
    System.assertEquals(
      10,
      lateByMonth.get(lateMonth).Discount__c.setScale(0),
      'Late line first increase on its later effective start month'
    );
  }

  @isTest
  static void disable_keepsValues_leavesPayments() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(12), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    Decimal projected = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ]
    .Discount__c;

    Test.startTest();
    RecurringPriceIncreaseService.disableRules(new List<Id>{ oi.Id }, false);
    Test.stopTest();

    OrderItem afterDisable = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Percent__c,
        Recurring_Increase_Frequency_Months__c,
        Recurring_Increase_Start_Date__c,
        Recurring_Increase_Type__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(
      false,
      afterDisable.Recurring_Price_Increase_Enabled__c
    );
    System.assertEquals(10, afterDisable.Recurring_Increase_Percent__c);
    System.assertEquals(3, afterDisable.Recurring_Increase_Frequency_Months__c);
    System.assertEquals(today, afterDisable.Recurring_Increase_Start_Date__c);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_PERCENT,
      afterDisable.Recurring_Increase_Type__c
    );
    System.assertEquals(
      projected,
      [
        SELECT Discount__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :oi.Id
        LIMIT 1
      ]
      .Discount__c,
      'Disable must not rewrite MPs'
    );
    System.assertEquals(
      null,
      RecurringPriceIncreaseService.resolveDiscount(
        oi.Id,
        today.toStartOfMonth(),
        0
      ),
      'Disabled rule stops consult'
    );
  }

  @isTest
  static void remove_clearsValues_leavesPayments() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(12), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    Decimal projected = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ]
    .Discount__c;

    Test.startTest();
    RecurringPriceIncreaseService.removeRules(new List<Id>{ oi.Id }, false);
    Test.stopTest();

    OrderItem afterRemove = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Percent__c,
        Recurring_Increase_Frequency_Months__c,
        Recurring_Increase_Start_Date__c,
        Recurring_Increase_Type__c,
        Recurring_Increase_Amount__c,
        Current_Effective_Price__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(false, afterRemove.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(null, afterRemove.Recurring_Increase_Percent__c);
    System.assertEquals(
      null,
      afterRemove.Recurring_Increase_Frequency_Months__c
    );
    System.assertEquals(null, afterRemove.Recurring_Increase_Start_Date__c);
    System.assertEquals(null, afterRemove.Recurring_Increase_Type__c);
    System.assertEquals(null, afterRemove.Recurring_Increase_Amount__c);
    System.assertEquals(null, afterRemove.Current_Effective_Price__c);
    System.assertEquals(
      projected,
      [
        SELECT Discount__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :oi.Id
        LIMIT 1
      ]
      .Discount__c
    );
  }

  @isTest
  static void terminatedAndArchived_blocked() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    update new OrderItem(Id = oi.Id, Termination_Reason__c = 'Other');

    Boolean terminatedThrown = false;
    try {
      RecurringPriceIncreaseService.saveRules(
        new List<Id>{ oi.Id },
        percentDraft(3, Date.today(), 5),
        false
      );
    } catch (AuraHandledException e) {
      terminatedThrown = true;
    }
    System.assertEquals(true, terminatedThrown);

    update new OrderItem(Id = oi.Id, Termination_Reason__c = null);

    Boolean archivedThrown = false;
    try {
      RecurringPriceIncreaseService.saveRules(
        new List<Id>{ oi.Id },
        percentDraft(3, Date.today(), 5),
        true
      );
    } catch (AuraHandledException e) {
      archivedThrown = true;
    }
    System.assertEquals(true, archivedThrown);

    update new OrderItem(Id = oi.Id, Is_Line_Deleted__c = true);
    Boolean deletedThrown = false;
    try {
      RecurringPriceIncreaseService.disableRules(new List<Id>{ oi.Id }, false);
    } catch (AuraHandledException e) {
      deletedThrown = true;
    }
    System.assertEquals(true, deletedThrown);
  }

  @isTest
  static void updateDiscount_withActiveRule_keepsUserEnteredDiscount() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(12), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);

    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );

    MonthlyPayment__c mp = [
      SELECT Id, Discount__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ];
    System.assertEquals(10, mp.Discount__c.setScale(0));

    // Grid edit: user sets Price Adjustment to +4.5%; keep as-is under active rule.
    MonthlyPayment__c edit = new MonthlyPayment__c(
      Id = mp.Id,
      Discount__c = 4.5
    );

    Test.startTest();
    PackageBuilderService.updateDiscount(new List<MonthlyPayment__c>{ edit });
    Test.stopTest();

    mp = [
      SELECT Discount__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    System.assertEquals(
      4.5,
      mp.Discount__c.setScale(1),
      'Discount stays as user entered'
    );
    System.assertEquals(
      4.5,
      mp.User_Price_Adjustment__c.setScale(1),
      'User_Price_Adjustment bookkeeping mirrors entered Discount'
    );

    // Unchanged Save (fields only) must not rewrite MPs.
    RecurringPriceIncreaseService.SaveResult second = RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    System.assertEquals(
      0,
      second.updatedPayments,
      'Unchanged rule must skip MP re-project'
    );
    mp = [
      SELECT Discount__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    System.assertEquals(4.5, mp.Discount__c.setScale(1));
    System.assertEquals(4.5, mp.User_Price_Adjustment__c.setScale(1));
  }

  @isTest
  static void saveRules_firstEnable_stepsOffStartMonthFinal() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c, UnitPrice, Quantity
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(12),
      oi.Access_Type__c
    );
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    MonthlyPayment__c mp = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ];
    // Pre-existing negotiated Final = list * 1.50 (e.g. 1000 → 1500).
    mp.Discount__c = 50;
    update mp;

    Test.startTest();
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 20),
      false
    );
    Test.stopTest();

    mp = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    // 50% Final then +20% recurring => list * 1.5 * 1.2 = list * 1.80 => Discount 80.
    System.assertEquals(
      80,
      mp.Discount__c.setScale(0),
      'First enable must step off start-month Final, not list alone'
    );
  }

  @isTest
  static void saveRules_unchanged_doesNotStackPayments() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(14),
      oi.Access_Type__c
    );
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1, 4 }, 0);

    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(3, today, 10);
    RecurringPriceIncreaseService.SaveResult first = RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    System.assert(first.updatedPayments >= 1, 'First apply projects MPs');
    Map<Date, MonthlyPayment__c> afterFirst = paymentsByMonth(oi.Id);
    Date startMonth = today.toStartOfMonth();
    Decimal firstDiscount = afterFirst.get(startMonth).Discount__c;

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult second = RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    Test.stopTest();

    System.assertEquals(1, second.updatedLines);
    System.assertEquals(
      0,
      second.updatedPayments,
      'Save fields only must not re-project'
    );
    Map<Date, MonthlyPayment__c> afterSecond = paymentsByMonth(oi.Id);
    System.assertEquals(
      firstDiscount,
      afterSecond.get(startMonth).Discount__c,
      'Discount must not stack on identical re-save'
    );
    System.assertEquals(
      10,
      afterSecond.get(startMonth).Discount__c.setScale(0)
    );
  }

  @isTest
  static void resolveEffectiveStart_consultOmitsTodayFloor() {
    Date chosen = Date.newInstance(2026, 1, 15);
    Date service = Date.newInstance(2025, 6, 1);
    Date contract = Date.newInstance(2025, 1, 1);
    // 3-arg overload: max(chosen, service, contract) — no today.
    Date withoutToday = RecurringPriceIncreaseService.resolveEffectiveStart(
      chosen,
      service,
      contract
    );
    System.assertEquals(chosen, withoutToday);
    // Explicit null today matches 3-arg.
    System.assertEquals(
      withoutToday,
      RecurringPriceIncreaseService.resolveEffectiveStart(
        chosen,
        service,
        contract,
        null
      )
    );
    // With today after chosen, 4-arg floors up (legacy save-validation helper).
    Date todayFloor = Date.newInstance(2026, 9, 1);
    System.assertEquals(
      todayFloor,
      RecurringPriceIncreaseService.resolveEffectiveStart(
        chosen,
        service,
        contract,
        todayFloor
      )
    );
  }

  @isTest
  static void project_ignoresStoredUserLayer_usesFinalChain() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(12), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    MonthlyPayment__c mp = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ];
    mp.User_Price_Adjustment__c = -0.05;
    update mp;

    Test.startTest();
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    Test.stopTest();

    mp = [
      SELECT Discount__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    System.assertEquals(-0.05, mp.User_Price_Adjustment__c);
    // Final-chain from list/prior ignores User_Price_Adjustment on project.
    System.assertEquals(10, mp.Discount__c.setScale(0));
  }

  @isTest
  static void helpers_eligibilityAndMaxDate() {
    System.assertEquals(
      true,
      RecurringPriceIncreaseService.isEligibleAccessType('Monthly')
    );
    System.assertEquals(
      true,
      RecurringPriceIncreaseService.isEligibleAccessType('Periodic')
    );
    System.assertEquals(
      false,
      RecurringPriceIncreaseService.isEligibleAccessType('Rent')
    );
    Date a = Date.today();
    Date b = a.addDays(5);
    System.assertEquals(b, RecurringPriceIncreaseService.maxDate(a, b));
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_PERCENT,
      RecurringPriceIncreaseService.normalizeIncreaseType('Percent')
    );
  }

  @isTest
  static void consultOnCreate_generateHonorsActiveRule_userAdjZero() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(14), 'Monthly');
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    Test.startTest();
    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    oi = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        Access_Type__c,
        Contract__c,
        Contract__r.Location__c,
        Product2Id,
        OrderId,
        Order.Status,
        Order.OpportunityId,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.Previous_Order__c,
        Order.Replacement_Start_Date__c,
        Opportunity_Product__c,
        Period_In_Months__c,
        Product2.Type__c,
        Original_Order_Product__c,
        Change_Action_Type__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    ContractService.generateMonthlyPaymentsRelatedToOrderItems(
      new Map<Id, OrderItem>{ oi.Id => oi }
    );
    Test.stopTest();

    Map<Date, MonthlyPayment__c> byMonth = paymentsByMonth(oi.Id);
    Date startMonth = today.toStartOfMonth();
    Date nextStep = startMonth.addMonths(3);
    System.assert(
      byMonth.containsKey(startMonth),
      'Start month payment missing'
    );
    System.assert(byMonth.containsKey(nextStep), 'Next step payment missing');
    System.assertEquals(0, byMonth.get(startMonth).User_Price_Adjustment__c);
    System.assertEquals(0, byMonth.get(nextStep).User_Price_Adjustment__c);
    System.assertEquals(
      10,
      byMonth.get(startMonth).Discount__c.setScale(0),
      'Start month consult = step 1'
    );
    System.assertEquals(
      21,
      byMonth.get(nextStep).Discount__c.setScale(0),
      'Frequency step consult compounds'
    );
  }

  @isTest
  static void consultOnCreate_topUpHonorsActiveRule() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c, OrderId
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, null, 'Monthly');
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];
    // Seed only the first month so top-up creates later months.
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);

    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );

    oi = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        Access_Type__c,
        Termination_Reason__c,
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
    ];

    Test.startTest();
    Integer added = ContractService.syncOpenEndedMonthlyPaymentsAddOnly(
      new List<OrderItem>{ oi },
      today.addMonths(12),
      today
    );
    Test.stopTest();

    System.assert(added > 0, 'Top-up should insert new months');
    Map<Date, MonthlyPayment__c> byMonth = paymentsByMonth(oi.Id);
    Date nextStep = today.toStartOfMonth().addMonths(3);
    System.assert(
      byMonth.containsKey(nextStep),
      'Top-up should reach next step'
    );
    System.assertEquals(0, byMonth.get(nextStep).User_Price_Adjustment__c);
    System.assertEquals(
      21,
      byMonth.get(nextStep).Discount__c.setScale(0),
      'Top-up consult compounds at frequency step'
    );
  }

  @isTest
  static void consultOnCreate_disabledRuleDoesNotApply() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(8), 'Monthly');
    delete [SELECT Id FROM MonthlyPayment__c WHERE OrderItem__c = :oi.Id];

    RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    RecurringPriceIncreaseService.disableRules(new List<Id>{ oi.Id }, false);

    oi = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        Access_Type__c,
        Contract__c,
        Contract__r.Location__c,
        Product2Id,
        OrderId,
        Order.Status,
        Order.OpportunityId,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.Previous_Order__c,
        Order.Replacement_Start_Date__c,
        Opportunity_Product__c,
        Period_In_Months__c,
        Product2.Type__c,
        Original_Order_Product__c,
        Change_Action_Type__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];

    Test.startTest();
    ContractService.generateMonthlyPaymentsRelatedToOrderItems(
      new Map<Id, OrderItem>{ oi.Id => oi }
    );
    Test.stopTest();

    List<MonthlyPayment__c> mps = [
      SELECT Discount__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
    ];
    System.assert(!mps.isEmpty(), 'Expected generated payments');
    for (MonthlyPayment__c mp : mps) {
      System.assertEquals(0, mp.User_Price_Adjustment__c);
      System.assertEquals(
        0,
        mp.Discount__c == null ? 0 : mp.Discount__c,
        'Disabled rule must not consult-on-create'
      );
    }
  }

  @isTest
  static void copyFromOpportunityProducts_closedWon_copiesAllRuleFields() {
    bypassHeavyAutomation();
    OpportunityLineItem oli = [
      SELECT Id
      FROM OpportunityLineItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    update new OpportunityLineItem(
      Id = oli.Id,
      Recurring_Price_Increase_Enabled__c = true,
      Recurring_Increase_Frequency_Months__c = 3,
      Recurring_Increase_Start_Date__c = today,
      Recurring_Increase_Type__c = RecurringPriceIncreaseService.TYPE_PERCENT,
      Recurring_Increase_Percent__c = 10,
      Recurring_Increase_Amount__c = null,
      Current_Effective_Price__c = 1100
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
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = today,
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
      Access_Type__c = 'Monthly',
      ServiceDate = today,
      EndDate = today.addMonths(12)
    );
    insert oi;

    Test.startTest();
    RecurringPriceIncreaseService.copyFromOpportunityProducts(
      new List<OrderItem>{ oi }
    );
    Test.stopTest();

    OrderItem copied = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Frequency_Months__c,
        Recurring_Increase_Start_Date__c,
        Recurring_Increase_Type__c,
        Recurring_Increase_Percent__c,
        Recurring_Increase_Amount__c,
        Current_Effective_Price__c,
        EndDate
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, copied.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(3, copied.Recurring_Increase_Frequency_Months__c);
    System.assertEquals(today, copied.Recurring_Increase_Start_Date__c);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_PERCENT,
      copied.Recurring_Increase_Type__c
    );
    System.assertEquals(10, copied.Recurring_Increase_Percent__c);
    System.assertEquals(null, copied.Recurring_Increase_Amount__c);
    System.assertEquals(1100, copied.Current_Effective_Price__c);
    System.assertEquals(
      today.addMonths(12),
      copied.EndDate,
      'Copy must not change end date'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Iteration__c WHERE Order_Product__c = :oi.Id],
      'Must not create Iterations'
    );
  }

  @isTest
  static void copyFromOriginalOrderProducts_draftClone_copiesAllRuleFields() {
    bypassHeavyAutomation();
    OrderItem activeOi = [
      SELECT Id, OrderId, PricebookEntryId, EndDate, ServiceDate, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    update new OrderItem(
      Id = activeOi.Id,
      Recurring_Price_Increase_Enabled__c = true,
      Recurring_Increase_Frequency_Months__c = 6,
      Recurring_Increase_Start_Date__c = today,
      Recurring_Increase_Type__c = RecurringPriceIncreaseService.TYPE_VALUE,
      Recurring_Increase_Percent__c = null,
      Recurring_Increase_Amount__c = 100,
      Current_Effective_Price__c = 1200
    );

    Order activeOrd = [
      SELECT Id, AccountId, Pricebook2Id, Location__c, EffectiveDate, EndDate
      FROM Order
      WHERE Id = :activeOi.OrderId
    ];
    Order draftOrd = new Order(
      AccountId = activeOrd.AccountId,
      Status = 'Draft',
      EffectiveDate = activeOrd.EffectiveDate,
      Pricebook2Id = activeOrd.Pricebook2Id,
      Location__c = activeOrd.Location__c,
      EndDate = activeOrd.EndDate,
      Previous_Order__c = activeOrd.Id
    );
    insert draftOrd;
    OrderItem draftOi = new OrderItem(
      OrderId = draftOrd.Id,
      PricebookEntryId = activeOi.PricebookEntryId,
      Quantity = 1,
      UnitPrice = 1000,
      Access_Type__c = activeOi.Access_Type__c,
      ServiceDate = activeOi.ServiceDate,
      EndDate = activeOi.EndDate,
      Original_Order_Product__c = activeOi.Id,
      Change_Type__c = 'No Change'
    );
    insert draftOi;

    Test.startTest();
    RecurringPriceIncreaseService.copyFromOriginalOrderProducts(
      new List<OrderItem>{ draftOi }
    );
    Test.stopTest();

    OrderItem copied = [
      SELECT
        Recurring_Price_Increase_Enabled__c,
        Recurring_Increase_Frequency_Months__c,
        Recurring_Increase_Start_Date__c,
        Recurring_Increase_Type__c,
        Recurring_Increase_Percent__c,
        Recurring_Increase_Amount__c,
        Current_Effective_Price__c,
        EndDate
      FROM OrderItem
      WHERE Id = :draftOi.Id
    ];
    System.assertEquals(true, copied.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(6, copied.Recurring_Increase_Frequency_Months__c);
    System.assertEquals(today, copied.Recurring_Increase_Start_Date__c);
    System.assertEquals(
      RecurringPriceIncreaseService.TYPE_VALUE,
      copied.Recurring_Increase_Type__c
    );
    System.assertEquals(null, copied.Recurring_Increase_Percent__c);
    System.assertEquals(100, copied.Recurring_Increase_Amount__c);
    System.assertEquals(1200, copied.Current_Effective_Price__c);
    System.assertEquals(activeOi.EndDate, copied.EndDate);
  }

  @isTest
  static void ensureDraftOrder_autoRenewSkipFlag_stillCopiesRuleFields() {
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
    Date today = Date.today();
    Date endBefore = activeOi.EndDate;
    update new OrderItem(
      Id = activeOi.Id,
      Recurring_Price_Increase_Enabled__c = true,
      Recurring_Increase_Frequency_Months__c = 3,
      Recurring_Increase_Start_Date__c = today,
      Recurring_Increase_Type__c = RecurringPriceIncreaseService.TYPE_PERCENT,
      Recurring_Increase_Percent__c = 5,
      Current_Effective_Price__c = 1050
    );

    Boolean prevSkip = PackageBuilderService.skipIterationCopyOnDraftClone;
    PackageBuilderService.skipIterationCopyOnDraftClone = true;
    try {
      Test.startTest();
      PackageBuilderService.DraftOrderResult cloned = PackageBuilderService.ensureDraftOrder(
        contr.Id
      );
      Test.stopTest();

      System.assertNotEquals(null, cloned.draftOrder);
      System.assert(
        cloned.itemIdMapping != null &&
        cloned.itemIdMapping.containsKey(activeOi.Id),
        'Expected active to draft mapping'
      );
      Id draftId = cloned.itemIdMapping.get(activeOi.Id);
      OrderItem draftOi = [
        SELECT
          Recurring_Price_Increase_Enabled__c,
          Recurring_Increase_Frequency_Months__c,
          Recurring_Increase_Start_Date__c,
          Recurring_Increase_Type__c,
          Recurring_Increase_Percent__c,
          Current_Effective_Price__c,
          EndDate
        FROM OrderItem
        WHERE Id = :draftId
      ];
      System.assertEquals(true, draftOi.Recurring_Price_Increase_Enabled__c);
      System.assertEquals(3, draftOi.Recurring_Increase_Frequency_Months__c);
      System.assertEquals(today, draftOi.Recurring_Increase_Start_Date__c);
      System.assertEquals(
        RecurringPriceIncreaseService.TYPE_PERCENT,
        draftOi.Recurring_Increase_Type__c
      );
      System.assertEquals(5, draftOi.Recurring_Increase_Percent__c);
      System.assertEquals(1050, draftOi.Current_Effective_Price__c);
      System.assertEquals(
        endBefore,
        draftOi.EndDate,
        'Auto-renew draft clone must not change end date via rule copy'
      );
    } finally {
      PackageBuilderService.skipIterationCopyOnDraftClone = prevSkip;
    }
  }

  @isTest
  static void copyMethods_nullAndEmpty_noOp() {
    RecurringPriceIncreaseService.copyFromOpportunityProducts(null);
    RecurringPriceIncreaseService.copyFromOpportunityProducts(
      new List<OrderItem>()
    );
    RecurringPriceIncreaseService.copyFromOriginalOrderProducts(null);
    RecurringPriceIncreaseService.copyFromOriginalOrderProducts(
      new List<OrderItem>()
    );
  }

  @isTest
  static void isRecurringStepMonth_alignsWithFrequency() {
    Date start = Date.newInstance(2026, 4, 15);
    System.assertEquals(
      true,
      RecurringPriceIncreaseService.isRecurringStepMonth(
        Date.newInstance(2026, 4, 1),
        start,
        3
      )
    );
    System.assertEquals(
      false,
      RecurringPriceIncreaseService.isRecurringStepMonth(
        Date.newInstance(2026, 5, 1),
        start,
        3
      )
    );
    System.assertEquals(
      true,
      RecurringPriceIncreaseService.isRecurringStepMonth(
        Date.newInstance(2026, 7, 1),
        start,
        3
      )
    );
    System.assertEquals(
      false,
      RecurringPriceIncreaseService.isRecurringStepMonth(
        Date.newInstance(2026, 3, 1),
        start,
        3
      )
    );
  }

  @isTest
  static void overlapPreview_math_iterationThenRecurringFromLatest() {
    // Pure math seam: list 1000 → +10% iteration → +3% recurring → user -5%.
    Decimal listPrice = 1000;
    Decimal afterIteration = RecurringPriceIncreaseService.applyIterationIncrease(
      IterationService.TYPE_PERCENT,
      10,
      null,
      null,
      listPrice
    );
    System.assertEquals(1100, afterIteration);
    Decimal afterRecurring = RecurringPriceIncreaseService.applyOneRecurringStep(
      afterIteration,
      RecurringPriceIncreaseService.TYPE_PERCENT,
      3,
      null
    );
    System.assertEquals(1133, afterRecurring);
    Decimal afterUser = (afterRecurring *
      (1 + RecurringPriceIncreaseService.toFraction(-0.05)))
      .setScale(2);
    System.assertEquals(1076.35, afterUser);

    Decimal afterIterFixed = RecurringPriceIncreaseService.applyIterationIncrease(
      IterationService.TYPE_VALUE,
      null,
      50,
      null,
      1100
    );
    System.assertEquals(1150, afterIterFixed);
    System.assertEquals(
      1250,
      RecurringPriceIncreaseService.applyOneRecurringStep(
        afterIterFixed,
        RecurringPriceIncreaseService.TYPE_VALUE,
        null,
        100
      )
    );
  }

  @isTest
  static void previewIterationOverlap_detectsSharedStepMonth() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(18), 'Monthly');
    Date overlapMonth = today.toStartOfMonth().addMonths(3);

    insert new Iteration__c(
      Order_Product__c = oi.Id,
      Period_Start_Date__c = overlapMonth,
      Period_End_Date__c = overlapMonth.addMonths(12).addDays(-1),
      Status__c = IterationService.STATUS_ORIGINAL,
      Increase_Type__c = IterationService.TYPE_PERCENT,
      Increase_Percent__c = 10,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30
    );
    // Completed iterations must not count as overlap
    insert new Iteration__c(
      Order_Product__c = oi.Id,
      Period_Start_Date__c = today.toStartOfMonth(),
      Status__c = IterationService.STATUS_COMPLETED,
      Increase_Type__c = IterationService.TYPE_PERCENT,
      Increase_Percent__c = 50,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30
    );

    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(3, today, 3);

    Test.startTest();
    RecurringPriceIncreaseService.OverlapPreviewResult preview = RecurringPriceIncreaseService.previewIterationOverlap(
      new List<Id>{ oi.Id },
      draft
    );
    Test.stopTest();

    System.assertEquals(true, preview.hasOverlap);
    System.assertEquals(1, preview.rows.size());
    RecurringPriceIncreaseService.OverlapPreviewRow row = preview.rows[0];
    System.assertEquals(oi.Id, row.lineId);
    System.assertEquals(overlapMonth, row.overlapMonth);
    // Before step 2: commercial is still step-1 (1000 * 1.03)
    System.assertEquals(1030, row.listPrice);
    System.assertEquals(1133, row.afterIteration);
    System.assertEquals(1166.99, row.afterRecurring);
    System.assertEquals(row.afterRecurring, row.afterUser);
    System.assertEquals(row.afterUser, row.finalPrice);
  }

  @isTest
  static void saveRules_overlapRequiresConfirm_thenSucceeds() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(18), 'Monthly');
    Date overlapMonth = today.toStartOfMonth();

    insert new Iteration__c(
      Order_Product__c = oi.Id,
      Period_Start_Date__c = overlapMonth,
      Status__c = IterationService.STATUS_ORIGINAL,
      Increase_Type__c = IterationService.TYPE_PERCENT,
      Increase_Percent__c = 10,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30
    );

    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(3, today, 3);

    Boolean blocked = false;
    try {
      RecurringPriceIncreaseService.saveRules(
        new List<Id>{ oi.Id },
        draft,
        false,
        false
      );
    } catch (AuraHandledException e) {
      blocked = true;
      System.assert(
        e.getMessage()
          .contains(RecurringPriceIncreaseService.CONFIRM_ITERATION_OVERLAP) ||
        e.getMessage().contains('Script-thrown exception'),
        'Expected confirm overlap exception, got: ' + e.getMessage()
      );
    }
    System.assertEquals(true, blocked, 'Save without confirm must be blocked');

    RecurringPriceIncreaseService.OverlapPreviewResult preview = RecurringPriceIncreaseService.previewIterationOverlap(
      new List<Id>{ oi.Id },
      draft
    );
    System.assertEquals(true, preview.hasOverlap);
    System.assertEquals(1000, preview.rows[0].listPrice);
    System.assertEquals(1100, preview.rows[0].afterIteration);
    System.assertEquals(1133, preview.rows[0].afterRecurring);

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      draft,
      false,
      true
    );
    Test.stopTest();

    System.assertEquals(1, res.updatedLines);
    OrderItem stamped = [
      SELECT Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, stamped.Recurring_Price_Increase_Enabled__c);
  }

  @isTest
  static void saveRules_noOverlap_savesWithoutConfirm() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(18), 'Monthly');
    // Iteration period start is off the 3-month staircase (today+1)
    insert new Iteration__c(
      Order_Product__c = oi.Id,
      Period_Start_Date__c = today.toStartOfMonth().addMonths(1),
      Status__c = IterationService.STATUS_ORIGINAL,
      Increase_Type__c = IterationService.TYPE_PERCENT,
      Increase_Percent__c = 10,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30
    );

    RecurringPriceIncreaseService.OverlapPreviewResult preview = RecurringPriceIncreaseService.previewIterationOverlap(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 3)
    );
    System.assertEquals(false, preview.hasOverlap);

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 3),
      false
    );
    Test.stopTest();
    System.assertEquals(1, res.updatedLines);
  }

  @isTest
  static void saveRuleFields_doesNotEnableOrProject() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c, Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(12),
      oi.Access_Type__c
    );
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    Map<Date, MonthlyPayment__c> before = paymentsByMonth(oi.Id);
    Decimal beforeDiscount = before.values()[0].Discount__c;

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    Test.stopTest();

    System.assertEquals(0, res.updatedPayments);
    oi = [
      SELECT Recurring_Price_Increase_Enabled__c, Recurring_Increase_Percent__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(false, oi.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(10, oi.Recurring_Increase_Percent__c);
    Map<Date, MonthlyPayment__c> after = paymentsByMonth(oi.Id);
    System.assertEquals(beforeDiscount, after.values()[0].Discount__c);
  }

  @isTest
  static void enableRules_enablesWithoutProjecting() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c, Recurring_Price_Increase_Enabled__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(12),
      oi.Access_Type__c
    );
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    Map<Date, MonthlyPayment__c> before = paymentsByMonth(oi.Id);
    Decimal beforeDiscount = before.values()[0].Discount__c;

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.enableRules(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 10),
      false
    );
    Test.stopTest();

    System.assertEquals(0, res.updatedPayments);
    oi = [
      SELECT Recurring_Price_Increase_Enabled__c, Recurring_Increase_Percent__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, oi.Recurring_Price_Increase_Enabled__c);
    System.assertEquals(10, oi.Recurring_Increase_Percent__c);
    Map<Date, MonthlyPayment__c> after = paymentsByMonth(oi.Id);
    System.assertEquals(beforeDiscount, after.values()[0].Discount__c);
  }

  @isTest
  static void enableAndApply_reprojectsUnchangedRule() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id, Access_Type__c
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(
      oi.Id,
      today,
      today.addMonths(12),
      oi.Access_Type__c
    );
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    RecurringPriceIncreaseService.RuleDraft draft = percentDraft(3, today, 10);
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    MonthlyPayment__c mp = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id
      LIMIT 1
    ];
    mp.Discount__c = 50;
    update mp;

    Test.startTest();
    RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    RecurringPriceIncreaseService.SaveResult applyAgain = RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      draft,
      false
    );
    Test.stopTest();

    System.assert(applyAgain.updatedPayments >= 1);
    mp = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    // 50% Final (1500) then +10% recurring => 1650 => Discount 65.
    System.assertEquals(
      65,
      mp.Discount__c.setScale(0),
      'Re-apply must step off current start-month Final'
    );
  }

  @isTest
  static void discountForMonthlyPaymentStorage_subOnePercentUsesFraction() {
    Decimal stored = RecurringPriceIncreaseService.discountForMonthlyPaymentStorage(
      2000,
      2018.18
    );
    System.assert(
      Math.abs(stored) < 1,
      'Sub-1% adjustments must store as fraction, not percent points'
    );
    Decimal payable = 2000 * (1 + stored);
    System.assertEquals(
      2018.18,
      payable.setScale(2),
      'Stored discount must derive correct payable'
    );
  }

  @isTest
  static void enableAndApply_fixedValueStepsFromLineTotalCurrentFinal() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    update new OrderItem(Id = oi.Id, UnitPrice = 400, Quantity = 5);
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(14), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1, 3 }, 0);

    Test.startTest();
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      valueDraft(2, today, 100),
      false
    );
    Test.stopTest();

    MonthlyPayment__c firstStepMp = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id AND MonthIndex__c = 1
      LIMIT 1
    ];
    MonthlyPayment__c secondStepMp = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id AND MonthIndex__c = 3
      LIMIT 1
    ];
    // Line total 2000, +100 => 2100 (5%), second step 2200 (10%).
    System.assertEquals(
      5,
      firstStepMp.Discount__c.setScale(0),
      'First step month should add 100 to current line-total Final'
    );
    System.assertEquals(
      10,
      secondStepMp.Discount__c.setScale(0),
      'Second step month must use percent points, not sub-1% fraction misread'
    );
  }

  @isTest
  static void enableAndApply_ruleChangeStepsFromCurrentFinalNotReverse() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    update new OrderItem(Id = oi.Id, UnitPrice = 1000, Quantity = 1);
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(14), 'Monthly');
    insertMonthsByIndex(oi.Id, new List<Integer>{ 1 }, 0);
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      percentDraft(2, today, 10),
      false
    );
    MonthlyPayment__c mp = [
      SELECT Id, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id AND MonthIndex__c = 1
      LIMIT 1
    ];
    System.assertEquals(
      10,
      mp.Discount__c.setScale(0),
      'Percent rule should apply +10% on list 1000'
    );

    Test.startTest();
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ oi.Id },
      valueDraft(2, today, 100),
      false
    );
    Test.stopTest();

    mp = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :mp.Id
    ];
    // 1100 current Final + 100 => 1200 on list 1000 => 20% (not reverse to 1000 + 100 = 10%).
    System.assertEquals(
      20,
      mp.Discount__c.setScale(0),
      'Rule change must step from current Final, not reverse prior rule'
    );
  }

  @isTest
  static void saveRuleFields_skipsOverlapCheck() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Monthly'
      LIMIT 1
    ];
    Date today = Date.today();
    prepareOrderItemServiceWindow(oi.Id, today, today.addMonths(18), 'Monthly');
    insert new Iteration__c(
      Order_Product__c = oi.Id,
      Period_Start_Date__c = today.toStartOfMonth(),
      Status__c = IterationService.STATUS_ORIGINAL,
      Increase_Type__c = IterationService.TYPE_PERCENT,
      Increase_Percent__c = 10,
      Duration_Months__c = 12,
      Advance_Notice_Days__c = 30
    );

    Test.startTest();
    RecurringPriceIncreaseService.SaveResult res = RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ oi.Id },
      percentDraft(3, today, 3),
      false
    );
    Test.stopTest();
    System.assertEquals(1, res.updatedLines);
    System.assertEquals(0, res.updatedPayments);
  }

  @isTest
  static void stackRecurringAfterRenewalPricing_stepsAfterRenewAnchor() {
    bypassHeavyAutomation();
    OrderItem oi = [
      SELECT Id
      FROM OrderItem
      WHERE Access_Type__c = 'Periodic'
      LIMIT 1
    ];
    Date serviceStart = Date.today().toStartOfMonth();
    prepareOrderItemServiceWindow(
      oi.Id,
      serviceStart,
      serviceStart.addMonths(12),
      'Periodic'
    );
    Date recurringStart = serviceStart;
    update new OrderItem(
      Id = oi.Id,
      Quantity = 2,
      UnitPrice = 100,
      Recurring_Price_Increase_Enabled__c = true,
      Recurring_Increase_Frequency_Months__c = 2,
      Recurring_Increase_Start_Date__c = recurringStart,
      Recurring_Increase_Type__c = RecurringPriceIncreaseService.TYPE_VALUE,
      Recurring_Increase_Amount__c = 100
    );

    List<MonthlyPayment__c> seeded = insertMonthsByIndex(
      oi.Id,
      new List<Integer>{ 2, 3, 4 },
      0
    );
    Date renewMonth = mpMonth(seeded[0]);
    Date stepMonth = mpMonth(seeded[1]);
    Date flatMonth = mpMonth(seeded[2]);

    Map<Id, Decimal> targets = new Map<Id, Decimal>{ oi.Id => 923 };
    Map<Id, Date> renewalStarts = new Map<Id, Date>{ oi.Id => renewMonth };

    Test.startTest();
    Integer updated = RecurringPriceIncreaseService.stackRecurringAfterRenewalPricing(
      targets,
      renewalStarts
    );
    Test.stopTest();

    System.assertEquals(3, updated);
    Map<Date, Decimal> fapByMonth = new Map<Date, Decimal>();
    for (MonthlyPayment__c mp : [
      SELECT Start_date__c, Stat_Date_Trigger__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :oi.Id AND MonthIndex__c IN (2, 3, 4)
    ]) {
      fapByMonth.put(mpMonth(mp), mp.Final_Adjusted_Price__c);
    }
    System.assertEquals(923, fapByMonth.get(renewMonth));
    System.assertEquals(
      1023,
      fapByMonth.get(stepMonth),
      'Recurring step month after renew should stack +100'
    );
    System.assertEquals(
      1023,
      fapByMonth.get(flatMonth),
      'Flat month between steps holds prior Final'
    );
  }
}
