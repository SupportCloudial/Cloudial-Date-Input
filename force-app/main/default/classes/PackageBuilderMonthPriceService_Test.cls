@isTest(IsParallel=false)
private class PackageBuilderMonthPriceService_Test {
  @testSetup
  static void setup() {
    bypassHeavyAutomation();
    String areaValue;
    String cityValue = 'Petah Tikva';
    try {
      List<Schema.PicklistEntry> areas = Locations__c.Area__c.getDescribe()
        .getPicklistValues();
      if (!areas.isEmpty()) {
        areaValue = areas[0].getValue();
      }
    } catch (Exception ignored) {
    }
    try {
      List<Schema.PicklistEntry> cities = Locations__c.City__c.getDescribe()
        .getPicklistValues();
      if (!cities.isEmpty()) {
        cityValue = cities[0].getValue();
      }
    } catch (Exception ignored) {
    }
    Locations__c location = new Locations__c(
      Name = 'Month Price Test Location',
      City__c = cityValue,
      Site_Name__c = 'Month Price Site',
      Address__c = 'Test Address',
      Area__c = areaValue
    );
    insert location;
    Product2 product = new Product2(
      Name = 'Month Price Test Product',
      IsActive = true,
      Location__c = location.Id
    );
    insert product;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = product.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;
    Account account = new Account(Name = 'Month Price Test Account');
    insert account;
    Contract contract = new Contract(
      AccountId = account.Id,
      Status = 'Draft',
      StartDate = Date.today().addYears(-1),
      EndDate = Date.today().addYears(2)
    );
    insert contract;
    contract.Status = 'Activated';
    update contract;
    insert new Order(
      AccountId = account.Id,
      ContractId = contract.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Order_Start_Date__c = Date.today(),
      EndDate = Date.today().addYears(2),
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = location.Id
    );
  }

  private static String monthYearLabel(Date value) {
    List<String> months = new List<String>{
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    };
    return months[value.month() - 1] + ' ' + String.valueOf(value.year());
  }

  private static void bypassHeavyAutomation() {
    TriggerHandler.clearAllBypasses();
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    TriggerHandler.bypass('OrderTriggerHandler');
  }

  private static OrderItem newOrderItem(Decimal quantity, Date endDate) {
    Order order = [SELECT Id, ContractId FROM Order LIMIT 1];
    Id standardPricebookId = Test.getStandardPricebookId();
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Pricebook2Id = :standardPricebookId
      LIMIT 1
    ];
    OrderItem item = new OrderItem(
      OrderId = order.Id,
      PricebookEntryId = pbe.Id,
      Contract__c = order.ContractId,
      Quantity = quantity,
      UnitPrice = 100,
      ServiceDate = Date.today(),
      EndDate = endDate
    );
    insert item;
    return item;
  }

  /** Build an in-memory MP so formula fields are under test control. */
  private static MonthlyPayment__c memoryPayment(
    Id orderItemId,
    Date startDate,
    Date endDate,
    Decimal finalPrice
  ) {
    return memoryPayment(
      orderItemId,
      startDate,
      endDate,
      finalPrice,
      null,
      null
    );
  }

  private static MonthlyPayment__c memoryPayment(
    Id orderItemId,
    Date startDate,
    Date endDate,
    Decimal finalPrice,
    Decimal monthlyUnits,
    String accessType
  ) {
    Map<String, Object> payload = new Map<String, Object>{
      'OrderItem__c' => orderItemId,
      'Start_date__c' => String.valueOf(startDate),
      'End_date__c' => String.valueOf(endDate),
      'Stat_Date_Trigger__c' => String.valueOf(startDate),
      'End_Date_trigger__c' => String.valueOf(endDate),
      'FinalPrice__c' => finalPrice
    };
    if (monthlyUnits != null) {
      payload.put('Monthly_Units__c', monthlyUnits);
    }
    if (String.isNotBlank(accessType)) {
      payload.put('Access_Type__c', accessType);
    }
    return (MonthlyPayment__c) JSON.deserialize(
      JSON.serialize(payload),
      MonthlyPayment__c.class
    );
  }

  private static MonthlyPayment__c insertPayment(
    Id orderItemId,
    Date startDate,
    Date endDate,
    Decimal discount
  ) {
    insert new MonthlyPayment__c(
      OrderItem__c = orderItemId,
      Stat_Date_Trigger__c = startDate,
      End_Date_trigger__c = endDate,
      Discount__c = discount
    );
    return [
      SELECT
        Id,
        OrderItem__c,
        FinalPrice__c,
        Monthly_Units__c,
        Access_Type__c,
        Start_date__c,
        End_date__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :orderItemId
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
  }

  @isTest
  static void usesSameMonthPaymentWhenTargetPrecedesPaymentStart() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.newInstance(2027, 6, 30));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 6, 5),
      Date.newInstance(2027, 6, 30),
      120
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 6, 2),
        false
      )
      .get(item.Id);
    Assert.areEqual(120, result.totalPrice);
    Assert.areEqual(Date.newInstance(2027, 6, 5), result.sourceStartDate);
    Assert.isFalse(result.usedFallback);
  }

  @isTest
  static void usesLastPaymentFallbackForEndedProduct() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addMonths(1));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2025, 1, 1),
      Date.newInstance(2025, 1, 31),
      110
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => Date.today().addDays(-1) },
        Date.newInstance(2027, 4, 1),
        false
      )
      .get(item.Id);
    Assert.isTrue(result.usedFallback, 'expected last-MP fallback');
    Assert.isTrue(
      result.infoTooltip.contains('Product ended'),
      result.infoTooltip
    );
    Assert.areEqual(110, result.totalPrice);
  }

  @isTest
  static void usesGapFallbackTooltipWhenProductNotEnded() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addYears(1));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2025, 1, 1),
      Date.newInstance(2025, 1, 31),
      110
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 4, 1),
        false
      )
      .get(item.Id);
    Assert.isTrue(result.usedFallback, 'expected last-MP fallback');
    Assert.isTrue(
      result.infoTooltip.contains('No payment for'),
      result.infoTooltip
    );
    Assert.isTrue(
      result.infoTooltip.contains('showing last payment'),
      result.infoTooltip
    );
    Assert.areEqual(110, result.totalPrice);
  }

  @isTest
  static void treatsFutureOnlyPaymentsAsMissing() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addYears(1));
    MonthlyPayment__c futurePayment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 12, 1),
      Date.newInstance(2027, 12, 31),
      199.99
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ futurePayment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2026, 8, 17),
        true
      )
      .get(item.Id);
    Assert.isTrue(result.missing);
    Assert.isFalse(result.usedFallback);
    Assert.areEqual(null, result.totalPrice);
    Assert.areEqual(null, result.unitPrice);
    Assert.areEqual('No payments found for Aug 2026.', result.infoTooltip);
  }

  @isTest
  static void lastPaymentFallbackIgnoresFuturePayments() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addYears(1));
    MonthlyPayment__c pastPayment = memoryPayment(
      item.Id,
      Date.newInstance(2025, 1, 1),
      Date.newInstance(2025, 1, 31),
      110
    );
    MonthlyPayment__c futurePayment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 12, 1),
      Date.newInstance(2027, 12, 31),
      199.99
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ pastPayment, futurePayment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2026, 8, 17),
        true
      )
      .get(item.Id);
    Assert.isTrue(result.usedFallback);
    Assert.isFalse(result.missing);
    Assert.areEqual(110, result.totalPrice);
    Assert.areEqual(Date.newInstance(2025, 1, 1), result.sourceStartDate);
    Assert.isTrue(
      result.infoTooltip.contains('showing last payment'),
      result.infoTooltip
    );
  }

  @isTest
  static void marksLineMissingWhenNoPaymentsExist() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addMonths(1));
    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>(),
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.today(),
        false
      )
      .get(item.Id);
    Assert.isTrue(result.missing);
    Assert.areEqual(null, result.totalPrice);
    Assert.areEqual(null, result.unitPrice);
    Date today = Date.today();
    Assert.areEqual(
      'No payments found for ' + monthYearLabel(today) + '.',
      result.infoTooltip
    );
  }

  @isTest
  static void missingTooltipFollowsTargetMonth() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addMonths(1));
    Map<Id, Decimal> qty = new Map<Id, Decimal>{ item.Id => 1 };
    Map<Id, Date> ends = new Map<Id, Date>{ item.Id => item.EndDate };
    PackageBuilderMonthPriceService.LinePriceResult august = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>(),
        qty,
        ends,
        Date.newInstance(2026, 8, 18),
        false
      )
      .get(item.Id);
    PackageBuilderMonthPriceService.LinePriceResult september = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>(),
        qty,
        ends,
        Date.newInstance(2026, 9, 1),
        false
      )
      .get(item.Id);
    Assert.areEqual('No payments found for Aug 2026.', august.infoTooltip);
    Assert.areEqual('No payments found for Sep 2026.', september.infoTooltip);
  }

  @isTest
  static void derivesUnitPriceFromQuantity() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(2, Date.today().addMonths(1));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.today(),
      Date.today().addMonths(1),
      200
    );
    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 2 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.today(),
        false
      )
      .get(item.Id);
    Assert.areEqual(100, result.unitPrice);
  }

  @isTest
  static void leavesUnitPriceBlankWhenQuantityInvalid() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addMonths(1));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.today(),
      Date.today().addMonths(1),
      120
    );
    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 0 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.today(),
        false
      )
      .get(item.Id);
    Assert.areEqual(120, result.totalPrice);
    Assert.areEqual(null, result.unitPrice);
  }

  @isTest
  static void supportsDraftStartAndActivatedTodayTargets() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addMonths(3));
    MonthlyPayment__c currentPayment = memoryPayment(
      item.Id,
      Date.today(),
      Date.today().addMonths(1).addDays(-1),
      110
    );
    MonthlyPayment__c draftPayment = memoryPayment(
      item.Id,
      Date.today().addMonths(1),
      Date.today().addMonths(2).addDays(-1),
      220
    );

    PackageBuilderMonthPriceService.LinePriceResult draftResult = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ currentPayment, draftPayment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.today().addMonths(1),
        false
      )
      .get(item.Id);
    PackageBuilderMonthPriceService.LinePriceResult activatedResult = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ currentPayment, draftPayment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.today(),
        true
      )
      .get(item.Id);
    Assert.areEqual(220, draftResult.totalPrice);
    Assert.areEqual(110, activatedResult.totalPrice);
  }

  @isTest
  static void resolveForOrderItemsProjectsDraftStartMonth() {
    bypassHeavyAutomation();
    Order order = [
      SELECT Id, Status, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    order.Order_Start_Date__c = Date.newInstance(2027, 5, 15);
    update order;
    OrderItem item = newOrderItem(2, Date.newInstance(2027, 12, 31));
    insertPayment(
      item.Id,
      Date.newInstance(2027, 5, 1),
      Date.newInstance(2027, 5, 31),
      0.5
    );

    Test.startTest();
    Map<Id, PackageBuilderMonthPriceService.LinePriceResult> results = PackageBuilderMonthPriceService.resolveForOrderItems(
      new List<OrderItem>{
        [
          SELECT Id, OrderId, Quantity, EndDate, UnitPrice
          FROM OrderItem
          WHERE Id = :item.Id
        ]
      }
    );
    List<PackageBuilderController.PackageProductData> products = PackageBuilderController.getProducts(
      order.Id
    );
    Test.stopTest();

    PackageBuilderMonthPriceService.LinePriceResult result = results.get(
      item.Id
    );
    Assert.isNotNull(result);
    Assert.isFalse(result.missing);
    Assert.isNotNull(result.totalPrice);
    Assert.areEqual((result.totalPrice / 2).setScale(2), result.unitPrice);

    Boolean found = false;
    for (PackageBuilderController.PackageProductData row : products) {
      if (row.LineItemId == String.valueOf(item.Id)) {
        found = true;
        Assert.areEqual(result.totalPrice, row.TotalPrice);
        Assert.areEqual(result.unitPrice, row.UnitPrice);
      }
    }
    Assert.isTrue(found, 'expected projected row from getProducts');
  }

  @isTest
  static void resolveForOrderItemsUsesTodayWhenActivated() {
    bypassHeavyAutomation();
    Order order = [
      SELECT Id, Status, Order_Start_Date__c
      FROM Order
      LIMIT 1
    ];
    order.Order_Start_Date__c = Date.today().addMonths(-2);
    update order;
    OrderItem item = newOrderItem(1, Date.today().addMonths(6));
    MonthlyPayment__c todayPayment = insertPayment(
      item.Id,
      Date.today().toStartOfMonth(),
      Date.today().toStartOfMonth().addMonths(1).addDays(-1),
      0.25
    );
    insertPayment(
      item.Id,
      Date.today().addMonths(-2).toStartOfMonth(),
      Date.today().addMonths(-2).toStartOfMonth().addMonths(1).addDays(-1),
      0
    );
    order.Status = 'Activated';
    update order;

    Test.startTest();
    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveForOrderItems(
        new List<OrderItem>{
          [
            SELECT Id, OrderId, Quantity, EndDate, UnitPrice
            FROM OrderItem
            WHERE Id = :item.Id
          ]
        }
      )
      .get(item.Id);
    Test.stopTest();

    Assert.areEqual(todayPayment.FinalPrice__c, result.totalPrice);
    Assert.isFalse(result.usedFallback);
  }

  @isTest
  static void scalesPartialMonthToFullUsingMonthlyUnits() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(2, Date.newInstance(2027, 6, 30));
    // Mid-month span: Final 500 covers half month → full-month Product's Price = 1000.
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 6, 16),
      Date.newInstance(2027, 6, 30),
      500,
      0.5,
      'Monthly'
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 2 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 6, 20),
        false
      )
      .get(item.Id);

    Assert.areEqual(1000, result.totalPrice);
    Assert.areEqual(500, result.unitPrice);
    Assert.isFalse(result.usedFallback);
    Assert.isFalse(result.missing);
  }

  @isTest
  static void snapsFullMonthPriceJustBelowNextInteger() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.newInstance(2027, 6, 30));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 6, 16),
      Date.newInstance(2027, 6, 30),
      3599.995,
      0.5,
      'Monthly'
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 6, 20),
        false
      )
      .get(item.Id);

    Assert.areEqual(7200, result.totalPrice);
    Assert.areEqual(7200, result.unitPrice);
  }

  @isTest
  static void recomputesMonthlyUnitsWhenFieldBlank() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.newInstance(2027, 6, 30));
    // Jun 16-30 = 15 days / 30 = 0.5 when Access Type is Monthly; Final 200 → 400.
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 6, 16),
      Date.newInstance(2027, 6, 30),
      200,
      null,
      'Monthly'
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 6, 20),
        false
      )
      .get(item.Id);

    Assert.areEqual(400, result.totalPrice);
    Assert.areEqual(400, result.unitPrice);
  }

  @isTest
  static void scalesLastPaymentFallbackWhenPartialMonth() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.today().addYears(1));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2025, 1, 16),
      Date.newInstance(2025, 1, 31),
      80,
      0.5,
      'Monthly'
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 4, 1),
        false
      )
      .get(item.Id);

    Assert.isTrue(result.usedFallback);
    Assert.areEqual(160, result.totalPrice);
    Assert.isTrue(
      result.infoTooltip.contains('No payment for'),
      result.infoTooltip
    );
  }

  @isTest
  static void leavesFullMonthPaymentUnscaled() {
    bypassHeavyAutomation();
    OrderItem item = newOrderItem(1, Date.newInstance(2027, 7, 31));
    MonthlyPayment__c payment = memoryPayment(
      item.Id,
      Date.newInstance(2027, 7, 1),
      Date.newInstance(2027, 7, 31),
      900,
      1,
      'Monthly'
    );

    PackageBuilderMonthPriceService.LinePriceResult result = PackageBuilderMonthPriceService.resolveFromPayments(
        new List<MonthlyPayment__c>{ payment },
        new Map<Id, Decimal>{ item.Id => 1 },
        new Map<Id, Date>{ item.Id => item.EndDate },
        Date.newInstance(2027, 7, 15),
        false
      )
      .get(item.Id);

    Assert.areEqual(900, result.totalPrice);
    Assert.isFalse(result.usedFallback);
  }
}
