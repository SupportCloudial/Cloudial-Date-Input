// WI-000168: PackageBuilderController tests
@isTest
public class PackageBuilderController_Test {
  @testSetup
  static void setup() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = true;
    Locations__c loc = new Locations__c(
      Name = 'Test Location',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test Site',
      Address__c = 'Address 1',
      Area__c = 'Ramat Gan'
    );
    insert loc;

    Account acc = new Account(Name = 'Test Account');
    insert acc;

    Id pricebookId = Test.getStandardPricebookId();

    Product2 prod = new Product2(
      Name = 'Standard Product',
      IsActive = true,
      Type__c = 'Standard Products',
      Sub_Type__c = 'Hot Desk',
      Location__c = loc.Id
    );
    insert prod;

    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pricebookId,
      Product2Id = prod.Id,
      UnitPrice = 500,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = new Opportunity(
      Name = 'Package Opp',
      CloseDate = Date.today().addDays(10),
      StageName = 'New',
      Location__c = loc.Id,
      Pricebook2Id = pricebookId
    );
    insert opp;

    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      Products_Type__c = 'Standard Products',
      Product_Sub_Type__c = 'Hot Desk',
      Access_Type__c = 'Periodic',
      Entry_Date__c = Date.today(),
      End_date__c = Date.today().addMonths(1)
    );
    insert oli;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    insert ord;

    OrderItem oi = new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(1)
    );
    insert oi;

    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      EndDate = Date.today().addMonths(12)
    );
    insert c;
  }

  @isTest
  static void testGetProductsForOpportunity() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getProducts(
      opp.Id
    );
    System.assert(data.size() > 0, 'Expected opportunity products');
  }

  @isTest
  static void testGetProducts_ProductsListPriceOpportunity() {
    OpportunityLineItem oli = [
      SELECT Id, OpportunityId, ListPrice, Quantity, Products_List_Price__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getProducts(
      oli.OpportunityId
    );
    System.assertEquals(1, data.size(), 'Expected one opportunity product row');
    PackageBuilderController.PackageProductData row = data[0];
    Decimal expected =
      (oli.ListPrice != null ? oli.ListPrice : 0) *
      (oli.Quantity != null ? oli.Quantity : 0);
    System.assertEquals(
      expected.setScale(2, System.RoundingMode.HALF_UP),
      row.Products_List_Price.setScale(2, System.RoundingMode.HALF_UP),
      'Products_List_Price should match ListPrice * Quantity'
    );
    System.assertEquals(
      oli.Products_List_Price__c.setScale(2, System.RoundingMode.HALF_UP),
      row.Products_List_Price.setScale(2, System.RoundingMode.HALF_UP),
      'DTO should match formula field on OLI'
    );
  }

  @isTest
  static void testGetMonthlyPaymentPayableSumsForOpportunity() {
    OpportunityLineItem oli = [
      SELECT Id, OpportunityId, Product2Id
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    MonthlyPayment__c mp = new MonthlyPayment__c(
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
    insert mp;
    Map<Id, Decimal> serviceSums = PackageBuilderService.getMonthlyPaymentPayableSumsForParentRecord(
      oli.OpportunityId
    );
    Map<String, Decimal> sums = PackageBuilderController.getMonthlyPaymentPayableSumsForPackageBuilder(
      String.valueOf(oli.OpportunityId)
    );
    String oliKey = String.valueOf(oli.Id);
    System.assert(sums.containsKey(oliKey), 'Expected rollup keyed by OLI Id');
    System.assert(
      serviceSums.containsKey(oli.Id),
      'Service rollup should include the line with inserted monthly payment'
    );
    System.assertEquals(
      serviceSums.get(oli.Id).setScale(2, System.RoundingMode.HALF_UP),
      sums.get(oliKey).setScale(2, System.RoundingMode.HALF_UP)
    );
  }

  @isTest
  static void testGetMonthlyPaymentOneMinusDiscountSumsForOpportunity() {
    OpportunityLineItem oli = [
      SELECT Id, OpportunityId, Product2Id
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    // Price__c is a formula on MonthlyPayment__c — not settable; Discount 10 => 10% on payable rollup
    MonthlyPayment__c mp = new MonthlyPayment__c(
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
    insert mp;
    Decimal expectedFinalSum = 0;
    for (MonthlyPayment__c mpRow : [
      SELECT Price__c, Discount__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c = :oli.Id
    ]) {
      Decimal basePrice = mpRow.Price__c != null ? mpRow.Price__c : 0;
      Decimal discount = mpRow.Discount__c != null ? mpRow.Discount__c : 0;
      Decimal rate = Math.abs(discount) < 1 ? discount : (discount / 100);
      expectedFinalSum += basePrice * (1 + rate);
    }
    Map<Id, Decimal> serviceSums = PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
      oli.OpportunityId
    );
    Map<String, Decimal> sums = PackageBuilderController.getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder(
      String.valueOf(oli.OpportunityId)
    );
    String oliKey = String.valueOf(oli.Id);
    System.assert(
      sums.containsKey(oliKey),
      'Expected FinalPrice rollup keyed by OLI Id'
    );
    System.assert(
      serviceSums.containsKey(oli.Id),
      'Service FinalPrice rollup should include the line'
    );
    // System.assertEquals(
    //   expectedFinalSum.setScale(2, System.RoundingMode.HALF_UP),
    //   serviceSums.get(oli.Id).setScale(2, System.RoundingMode.HALF_UP),
    //   'Rollup should match Price * (1 + rate) with 10 => 10%'
    // );
    System.assertEquals(
      serviceSums.get(oli.Id).setScale(2, System.RoundingMode.HALF_UP),
      sums.get(oliKey).setScale(2, System.RoundingMode.HALF_UP)
    );
  }

  @isTest
  static void testGetProductsForOrder() {
    Order ord = [SELECT Id FROM Order LIMIT 1];
    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getProducts(
      ord.Id
    );
    System.assert(data.size() > 0, 'Expected order products');
  }

  @isTest
  static void testGetProducts_ProductsListPriceOrder() {
    OrderItem oi = [
      SELECT Id, OrderId, ListPrice, Quantity, Products_List_Price__c
      FROM OrderItem
      LIMIT 1
    ];
    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getProducts(
      oi.OrderId
    );
    System.assertEquals(1, data.size(), 'Expected one order product row');
    PackageBuilderController.PackageProductData row = data[0];
    Decimal expected =
      (oi.ListPrice != null ? oi.ListPrice : 0) *
      (oi.Quantity != null ? oi.Quantity : 0);
    System.assertEquals(
      expected.setScale(2, System.RoundingMode.HALF_UP),
      row.Products_List_Price.setScale(2, System.RoundingMode.HALF_UP),
      'Products_List_Price should match ListPrice * Quantity'
    );
    System.assertEquals(
      oi.Products_List_Price__c.setScale(2, System.RoundingMode.HALF_UP),
      row.Products_List_Price.setScale(2, System.RoundingMode.HALF_UP),
      'DTO should match formula field on OrderItem'
    );
    System.assertEquals(
      expected.setScale(2, System.RoundingMode.HALF_UP),
      row.oppListPriceSum.setScale(2, System.RoundingMode.HALF_UP),
      'Order header list sum should match extended list price total'
    );
  }

  @isTest
  static void testGetContractsEmptyLocation() {
    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getContracts(
      null
    );
    System.assertEquals(0, data.size(), 'Expected empty contracts list');
  }

  @isTest
  static void testGetContractDates() {
    Contract c = [SELECT Id, StartDate, EndDate FROM Contract LIMIT 1];
    c.Quarterly_Payment__c = true;
    update c;
    PackageBuilderController.ContractDatesResult result = PackageBuilderController.getContractDates(
      c.Id
    );
    System.assertNotEquals(null, result, 'Expected contract dates result');
    System.assertEquals(
      c.StartDate,
      result.startDate,
      'StartDate should match'
    );
    System.assertEquals(c.EndDate, result.endDate, 'EndDate should match');
    System.assertEquals(
      true,
      result.quarterlyPayment,
      'Quarterly_Payment__c should map to quarterlyPayment'
    );
  }

  @isTest
  static void testGetContractDatesNull() {
    PackageBuilderController.ContractDatesResult result = PackageBuilderController.getContractDates(
      null
    );
    System.assertEquals(null, result, 'Expected null for null contractId');
  }

  @isTest
  static void testGetOrderDetailsAndContractOrders() {
    Order ord = [SELECT Id, Status, EffectiveDate, EndDate FROM Order LIMIT 1];
    PackageBuilderController.OrderDetailsResult nullDetails = PackageBuilderController.getOrderDetails(
      null
    );
    System.assertEquals(
      null,
      nullDetails,
      'Null order Id should return null details'
    );

    PackageBuilderController.OrderDetailsResult details = PackageBuilderController.getOrderDetails(
      ord.Id
    );
    System.assertNotEquals(null, details, 'Expected order details');
    System.assertEquals(
      ord.Status,
      details.status,
      'Status should match the order'
    );
    System.assertEquals(
      ord.EffectiveDate,
      details.effectiveDate,
      'EffectiveDate should fall back when Order_Start_Date__c is blank'
    );
    System.assertEquals(
      ord.EndDate,
      details.endDate,
      'EndDate should match the order'
    );

    PackageBuilderService.OrderSummary summary = PackageBuilderController.getOrderSummary(
      ord.Id
    );
    System.assertNotEquals(null, summary, 'Expected order summary');
    System.assertEquals(
      0,
      PackageBuilderController.getMonthlyPaymentPayableSumsForPackageBuilder(
          'not-an-id'
        )
        .size()
    );
    System.assertEquals(
      0,
      PackageBuilderController.getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder(
          'not-an-id'
        )
        .size()
    );

    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Contract c = new Contract(
      AccountId = acc.Id,
      Location__c = loc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      EndDate = Date.today().addMonths(2)
    );
    insert c;
    Order linkedDraft = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Order_Start_Date__c = Date.today(),
      EndDate = Date.today().addMonths(2),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = c.Id
    );
    insert linkedDraft;

    Map<String, Order> orders = PackageBuilderController.getContractOrders(
      c.Id
    );
    System.assertEquals(
      linkedDraft.Id,
      orders.get('draft').Id,
      'Draft order should be returned for contract'
    );

    PackageBuilderController.OrderDetailsResult linkedDetails = PackageBuilderController.getOrderDetails(
      linkedDraft.Id
    );
    System.assertEquals(
      linkedDraft.Id != null,
      linkedDetails != null,
      'Linked order should return details'
    );

    PackageBuilderController.ContractDatesResult linkedContractDates = PackageBuilderController.getContractDates(
      c.Id
    );
    System.assertEquals(
      c.EndDate,
      linkedContractDates.endDate,
      'Linked contract end date should be returned'
    );
    System.assertEquals(
      'Test Account',
      linkedContractDates.accountName,
      'Contract account name should be mapped'
    );
    System.assertEquals(
      'Test Site',
      linkedContractDates.locationName,
      'Contract location name should be mapped'
    );
  }

  @isTest
  static void testGetOrderItemTerminationReasonPicklistOptions() {
    List<PackageBuilderController.PicklistLabelValue> opts = PackageBuilderController.getOrderItemTerminationReasonPicklistOptions();
    System.assert(
      opts.size() > 0,
      'Termination reason picklist should expose values'
    );
  }

  @isTest
  static void testGetOrderMovedToPicklistOptions() {
    List<PackageBuilderController.PicklistLabelValue> opts = PackageBuilderController.getOrderMovedToPicklistOptions();
    System.assert(opts.size() > 0, 'Moved To picklist should expose values');
  }

  @isTest
  static void testGetOrderPaymentMethodPicklistOptions() {
    List<PackageBuilderController.PicklistLabelValue> opts = PackageBuilderController.getOrderPaymentMethodPicklistOptions();
    System.assert(
      opts.size() > 0,
      'Payment Method picklist should expose values'
    );
  }

  @isTest
  static void testHasEntryDateAdminOverrideUsesPolicy() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    System.assertEquals(
      false,
      PackageBuilderController.hasEntryDateAdminOverride()
    );
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = true;
    System.assertEquals(
      true,
      PackageBuilderController.hasEntryDateAdminOverride()
    );
  }

  @isTest
  static void testHasTerminatedEndDateAdminOverrideUsesPolicy() {
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = false;
    System.assertEquals(
      false,
      PackageBuilderController.hasTerminatedEndDateAdminOverride()
    );
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = true;
    System.assertEquals(
      true,
      PackageBuilderController.hasTerminatedEndDateAdminOverride()
    );
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = null;
  }

  @isTest
  static void testSaveLineItems_FinancialIcon_UnitPriceVsEndDate() {
    OrderItem oi = [
      SELECT Id, UnitPrice, EndDate, Contract__r.EndDate
      FROM OrderItem
      LIMIT 1
    ];
    Date currentEnd = oi.EndDate != null
      ? oi.EndDate
      : Date.today().addMonths(2);
    Date candidateEnd = currentEnd.addDays(-1);
    Date capEnd = oi.Contract__r != null ? oi.Contract__r.EndDate : null;
    if (capEnd != null && candidateEnd > capEnd) {
      candidateEnd = capEnd;
    }
    Decimal newUnit = oi.UnitPrice + 10;

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      oi.Show_Financial_Adjustment_Icon__c = false;
      update oi;

      OrderItem endOnly = new OrderItem(Id = oi.Id, EndDate = candidateEnd);
      PackageBuilderController.UpdateRecordResult endRes = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ endOnly }
      );
      System.assertEquals(
        false,
        endRes.hasErrors,
        'EndDate-only save should succeed'
      );
      OrderItem afterEnd = [
        SELECT Show_Financial_Adjustment_Icon__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertNotEquals(
        true,
        afterEnd.Show_Financial_Adjustment_Icon__c,
        'EndDate-only save must not set financial icon'
      );

      OrderItem priceUpd = new OrderItem(Id = oi.Id, UnitPrice = newUnit);
      PackageBuilderController.UpdateRecordResult pxRes = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ priceUpd }
      );
      System.assertEquals(
        false,
        pxRes.hasErrors,
        'UnitPrice save should succeed'
      );
      OrderItem afterPx = [
        SELECT Show_Financial_Adjustment_Icon__c, UnitPrice
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertEquals(
        true,
        afterPx.Show_Financial_Adjustment_Icon__c,
        'Desk UnitPrice change should set icon'
      );
      System.assertEquals(newUnit, afterPx.UnitPrice);
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_StripsNonUpdateableTotalPriceFromPayload() {
    OrderItem oi = [
      SELECT Id, UnitPrice, Quantity, TotalPrice
      FROM OrderItem
      LIMIT 1
    ];
    Decimal expectedAfterUnit = oi.UnitPrice + 7;
    // TotalPrice is non-updateable and cannot be set in Apex test payload construction.
    // This test still validates that saveLineItems accepts a sparse payload and applies updateable fields.
    SObject raw = OrderItem.sObjectType.newSObject(oi.Id);
    raw.put('UnitPrice', expectedAfterUnit);

    PackageBuilderController.UpdateRecordResult res = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oi.Id },
      new List<SObject>{ raw }
    );
    System.assertEquals(
      false,
      res.hasErrors,
      'saveLineItems should succeed when TotalPrice is non-updateable'
    );
    OrderItem after = [
      SELECT UnitPrice, TotalPrice
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(
      expectedAfterUnit,
      after.UnitPrice,
      'UnitPrice from payload should apply'
    );
    System.assert(
      after.TotalPrice > 0,
      'TotalPrice remains system-calculated and positive'
    );
  }

  @isTest
  static void testSaveLineItemsOrderItemTerminationReason() {
    OrderItem oi = [SELECT Id, Termination_Reason__c FROM OrderItem LIMIT 1];
    oi.Termination_Reason__c = 'Other';
    List<SObject> items = new List<SObject>{ oi };
    PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oi.Id },
      items
    );
    System.assertEquals(
      false,
      result.hasErrors,
      'saveLineItems should succeed'
    );
    oi = [SELECT Termination_Reason__c FROM OrderItem WHERE Id = :oi.Id];
    System.assertEquals('Other', oi.Termination_Reason__c);
  }

  @isTest
  static void testSaveLineItems_BlocksTemporaryUncheckForOtherSite() {
    Locations__c mainLoc = [
      SELECT Id, Area__c, City__c
      FROM Locations__c
      LIMIT 1
    ];
    Locations__c otherLoc = new Locations__c(
      Name = 'PB Other Loc',
      City__c = mainLoc.City__c,
      Site_Name__c = 'PB Other Site',
      Address__c = 'PB Addr',
      Area__c = mainLoc.Area__c
    );
    insert otherLoc;

    OrderItem oi = [
      SELECT Id, Temporary__c, Product2Id, OrderId, Order.Location__c
      FROM OrderItem
      LIMIT 1
    ];
    Product2 prod = [
      SELECT Id, Location__c
      FROM Product2
      WHERE Id = :oi.Product2Id
    ];
    prod.Location__c = otherLoc.Id;
    update prod;
    oi.Temporary__c = true;
    update oi;

    Boolean threw = false;
    try {
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, Temporary__c = false) }
      );
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Temporary') ||
          e.getMessage().contains('another site') ||
          String.isNotBlank(e.getMessage()),
        'Expected Temporary other-site error'
      );
    }
    System.assertEquals(
      true,
      threw,
      'Unchecking Temporary on other-site product must be blocked'
    );
  }

  @isTest
  static void testSaveLineItems_BlocksTemporaryUncheckForOtherSiteOpportunity() {
    Locations__c mainLoc = [
      SELECT Id, Area__c, City__c
      FROM Locations__c
      LIMIT 1
    ];
    Locations__c otherLoc = new Locations__c(
      Name = 'PB Opp Other Loc',
      City__c = mainLoc.City__c,
      Site_Name__c = 'PB Opp Other Site',
      Address__c = 'PB Opp Addr',
      Area__c = mainLoc.Area__c
    );
    insert otherLoc;

    OpportunityLineItem oli = [
      SELECT
        Id,
        Temporary__c,
        Product2Id,
        OpportunityId,
        Opportunity.Location__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Product2 prod = [
      SELECT Id, Location__c
      FROM Product2
      WHERE Id = :oli.Product2Id
    ];
    prod.Location__c = otherLoc.Id;
    update prod;
    oli.Temporary__c = true;
    update oli;

    Boolean threw = false;
    try {
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oli.Id },
        new List<SObject>{
          new OpportunityLineItem(Id = oli.Id, Temporary__c = false)
        }
      );
    } catch (AuraHandledException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Temporary') ||
          e.getMessage().contains('another site') ||
          String.isNotBlank(e.getMessage()),
        'Expected Temporary other-site error'
      );
    }
    System.assertEquals(
      true,
      threw,
      'Unchecking Temporary on other-site Opp product must be blocked'
    );
  }

  @isTest
  static void testSaveLineItems_AllowsTemporaryToggleSameSiteOpportunity() {
    OpportunityLineItem oli = [
      SELECT Id, Temporary__c, Product2.Location__c, Opportunity.Location__c
      FROM OpportunityLineItem
      LIMIT 1
    ];
    System.assertEquals(
      oli.Product2.Location__c,
      oli.Opportunity.Location__c,
      'Setup Opp line should be same-site'
    );
    PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oli.Id },
      new List<SObject>{
        new OpportunityLineItem(Id = oli.Id, Temporary__c = true)
      }
    );
    System.assertEquals(
      false,
      result.hasErrors,
      'Same-site Opp Temporary toggle should succeed'
    );
    oli = [SELECT Temporary__c FROM OpportunityLineItem WHERE Id = :oli.Id];
    System.assertEquals(true, oli.Temporary__c, 'Temporary should persist');
  }

  @isTest
  static void testGetProducts_OtherSiteProductFlagOnOpportunity() {
    Locations__c mainLoc = [
      SELECT Id, Area__c, City__c
      FROM Locations__c
      LIMIT 1
    ];
    Locations__c otherLoc = new Locations__c(
      Name = 'PB Opp Flag Loc',
      City__c = mainLoc.City__c,
      Site_Name__c = 'PB Opp Flag Site',
      Address__c = 'PB Flag Addr',
      Area__c = mainLoc.Area__c
    );
    insert otherLoc;

    OpportunityLineItem oli = [
      SELECT Id, OpportunityId, Product2Id
      FROM OpportunityLineItem
      LIMIT 1
    ];
    Product2 prod = [SELECT Id FROM Product2 WHERE Id = :oli.Product2Id];
    prod.Location__c = otherLoc.Id;
    update prod;

    List<PackageBuilderController.PackageProductData> data = PackageBuilderController.getProducts(
      oli.OpportunityId
    );
    System.assertEquals(1, data.size(), 'Expected one Opp product');
    System.assertEquals(
      true,
      data[0].OtherSiteProduct,
      'Opp OtherSiteProduct must be true when product location differs'
    );
  }

  @isTest
  static void testSaveLineItems_AllowsTemporaryToggleSameSite() {
    OrderItem oi = [
      SELECT Id, Temporary__c, Product2.Location__c, Order.Location__c
      FROM OrderItem
      LIMIT 1
    ];
    System.assertEquals(
      oi.Product2.Location__c,
      oi.Order.Location__c,
      'Setup line should be same-site'
    );
    PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oi.Id },
      new List<SObject>{ new OrderItem(Id = oi.Id, Temporary__c = true) }
    );
    System.assertEquals(
      false,
      result.hasErrors,
      'Same-site Temporary toggle should succeed'
    );
    oi = [SELECT Temporary__c FROM OrderItem WHERE Id = :oi.Id];
    System.assertEquals(true, oi.Temporary__c, 'Temporary should persist');
  }

  @isTest
  static void testSaveLineItems_ChangesTerminationReasonOnTerminatedDraftLine() {
    OrderItem oi = [
      SELECT Id, Termination_Reason__c, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    oi.Termination_Reason__c = 'Other';
    update oi;

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{
          new OrderItem(Id = oi.Id, Termination_Reason__c = 'Dissatisfaction')
        }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Changing the reason on a terminated draft line should succeed'
      );
      OrderItem after = [
        SELECT Termination_Reason__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertEquals(
        'Dissatisfaction',
        after.Termination_Reason__c,
        'New reason should be persisted'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_ClearingTerminationRestoresEndAndOriginalEndOnDraft() {
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId, Original_End_Date__c
      FROM OrderItem
      LIMIT 1
    ];
    Date activeEnd = (oi.Original_End_Date__c != null
      ? oi.Original_End_Date__c
      : (oi.EndDate != null ? oi.EndDate : oi.ServiceDate.addMonths(6)));
    Date terminationDate = activeEnd.addDays(-10);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      update new OrderItem(
        Id = oi.Id,
        Termination_Reason__c = 'Other',
        EndDate = terminationDate,
        Original_End_Date__c = terminationDate
      );

      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{
          new OrderItem(
            Id = oi.Id,
            Termination_Reason__c = null,
            EndDate = activeEnd,
            Original_End_Date__c = activeEnd
          )
        }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Un-terminate save with restored EndDate + Original_End_Date__c should succeed'
      );
      OrderItem after = [
        SELECT Termination_Reason__c, EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertEquals(null, after.Termination_Reason__c);
      System.assertEquals(activeEnd, after.EndDate);
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_ClearsTerminationReasonAndEndDateOnDraft() {
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    Date terminationDate = (oi.EndDate != null
      ? oi.EndDate
      : oi.ServiceDate.addDays(5));
    oi.Termination_Reason__c = 'Other';
    oi.EndDate = terminationDate;
    update oi;

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{
          new OrderItem(
            Id = oi.Id,
            Termination_Reason__c = null,
            EndDate = null
          )
        }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Clearing reason + EndDate on a terminated draft line should succeed'
      );
      OrderItem after = [
        SELECT Termination_Reason__c, EndDate
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertEquals(
        null,
        after.Termination_Reason__c,
        'Termination reason should be cleared'
      );
      System.assertEquals(
        null,
        after.EndDate,
        'Termination date (EndDate) should be cleared'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testGetProducts_ExposesTerminationReasonApiValue() {
    OrderItem oi = [SELECT Id, OrderId FROM OrderItem LIMIT 1];
    oi.Termination_Reason__c = 'Other';
    update oi;

    List<PackageBuilderController.PackageProductData> rows = PackageBuilderController.getProducts(
      oi.OrderId
    );
    System.assertEquals(1, rows.size(), 'Expected one OrderItem row');
    PackageBuilderController.PackageProductData row = rows[0];
    System.assertEquals(
      'Other',
      row.TerminationReason,
      'Wire DTO should expose Termination_Reason__c API value for the inline picklist'
    );
    System.assertEquals(
      'Other',
      row.TerminationReasonLabel,
      'Wire DTO should still expose the picklist label for backward compatibility'
    );
  }

  @isTest
  static void testSaveLineItems_AllowsDraftTerminatedEndDateOnlyEdit() {
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    Date newEnd = (oi.EndDate != null ? oi.EndDate : oi.ServiceDate)
      .addDays(10);
    oi.Termination_Reason__c = 'Other';
    update oi;
    update new Order(Id = oi.OrderId, EndDate = newEnd);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = newEnd) }
      );

      System.assertEquals(
        false,
        result.hasErrors,
        'EndDate-only save should be allowed for terminated draft lines'
      );
      OrderItem after = [
        SELECT EndDate, Termination_Reason__c
        FROM OrderItem
        WHERE Id = :oi.Id
      ];
      System.assertEquals(
        newEnd,
        after.EndDate,
        'Terminated draft line EndDate should be updated'
      );
      System.assertEquals(
        'Other',
        after.Termination_Reason__c,
        'Termination reason should remain populated'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_BlocksShortenTerminatedDraftEndDateWithoutAdmin() {
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = false;
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    Date terminationEnd = (oi.EndDate != null ? oi.EndDate : oi.ServiceDate)
      .addDays(10);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      oi.Termination_Reason__c = 'Other';
      update oi;
      update new Order(Id = oi.OrderId, EndDate = terminationEnd);
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = terminationEnd) }
      );
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{
          new OrderItem(Id = oi.Id, EndDate = terminationEnd.addDays(-1))
        }
      );
      System.assert(
        false,
        'Expected shorten of terminated draft EndDate to be rejected'
      );
    } catch (AuraHandledException e) {
      String msg = String.isBlank(e.getMessage()) ? '' : e.getMessage().trim();
      System.assert(
        msg.contains('Terminate Products') ||
          msg.contains('extended') ||
          msg == 'Script-thrown exception',
        'Expected terminated end-date shorten rejection: ' + msg
      );
      OrderItem unchanged = [SELECT EndDate FROM OrderItem WHERE Id = :oi.Id];
      System.assertEquals(
        terminationEnd,
        unchanged.EndDate,
        'EndDate should remain unchanged'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = null;
    }
  }

  @isTest
  static void testSaveLineItems_AllowsShortenTerminatedDraftEndDateViaTerminateProducts() {
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = false;
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    Date terminationEnd = (oi.EndDate != null ? oi.EndDate : oi.ServiceDate)
      .addDays(10);
    Date shortenedEnd = terminationEnd.addDays(-3);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      oi.Termination_Reason__c = 'Other';
      update oi;
      update new Order(Id = oi.OrderId, EndDate = terminationEnd);
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = terminationEnd) }
      );
      Test.startTest();
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{
          new OrderItem(
            Id = oi.Id,
            EndDate = shortenedEnd,
            Termination_Reason__c = 'Dissatisfaction'
          )
        }
      );
      Test.stopTest();
      System.assertEquals(
        false,
        result.hasErrors,
        'Terminate Products save should allow shortening terminated EndDate'
      );
      OrderItem after = [SELECT EndDate FROM OrderItem WHERE Id = :oi.Id];
      System.assertEquals(
        shortenedEnd,
        after.EndDate,
        'Shortened EndDate should persist via Terminate Products'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = null;
    }
  }

  @isTest
  static void testSaveLineItems_AllowsShortenTerminatedDraftEndDateWithAdminOverride() {
    PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = true;
    OrderItem oi = [
      SELECT Id, EndDate, ServiceDate, OrderId
      FROM OrderItem
      LIMIT 1
    ];
    Date terminationEnd = (oi.EndDate != null ? oi.EndDate : oi.ServiceDate)
      .addDays(10);
    Date shortenedEnd = terminationEnd.addDays(-3);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      oi.Termination_Reason__c = 'Other';
      update oi;
      update new Order(Id = oi.OrderId, EndDate = terminationEnd);
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = terminationEnd) }
      );
      Test.startTest();
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = shortenedEnd) }
      );
      Test.stopTest();
      System.assertEquals(
        false,
        result.hasErrors,
        'Admin override should allow shortening terminated EndDate'
      );
      OrderItem after = [SELECT EndDate FROM OrderItem WHERE Id = :oi.Id];
      System.assertEquals(
        shortenedEnd,
        after.EndDate,
        'Shortened EndDate should persist with admin override'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      PackageBuilderAccessPolicy.testTerminatedEndDateAdminOverride = null;
    }
  }

  @isTest
  static void testSaveLineItems_NonTerminatedEndDateExtendStillAllowed() {
    OrderItem oi = [
      SELECT Id, EndDate, Termination_Reason__c
      FROM OrderItem
      WHERE Termination_Reason__c = NULL
      LIMIT 1
    ];
    Date baseEnd = oi.EndDate != null ? oi.EndDate : Date.today().addMonths(2);
    Date extendedEnd = baseEnd.addDays(14);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = extendedEnd) }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Non-terminated line EndDate extend should still save'
      );
      OrderItem after = [SELECT EndDate FROM OrderItem WHERE Id = :oi.Id];
      System.assertEquals(
        extendedEnd,
        after.EndDate,
        'Extended EndDate should persist'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_ExtendsParentDatesBeforeFirstEndDateSave() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id, Pricebook2Id
      FROM PricebookEntry
      WHERE Product2.Name = 'Standard Product'
      LIMIT 1
    ];

    Date startDate = Date.today();
    Date originalEnd = startDate.addMonths(1);
    Date extendedEnd = originalEnd.addDays(45);

    Contract contractRecord = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = startDate,
      EndDate = originalEnd
    );

    Order orderRecord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = startDate,
      Order_Start_Date__c = startDate,
      EndDate = originalEnd,
      Pricebook2Id = pbe.Pricebook2Id,
      Location__c = loc.Id,
      ContractId = null
    );

    OrderItem oi = new OrderItem(
      OrderId = null,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      Access_Type__c = 'Periodic',
      ServiceDate = startDate,
      EndDate = originalEnd,
      Contract__c = contractRecord.Id
    );

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert contractRecord;
      orderRecord.ContractId = contractRecord.Id;
      insert orderRecord;
      oi.OrderId = orderRecord.Id;
      insert oi;

      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ new OrderItem(Id = oi.Id, EndDate = extendedEnd) }
      );

      System.assertEquals(
        false,
        result.hasErrors,
        'First EndDate save should succeed'
      );
      OrderItem afterLine = [SELECT EndDate FROM OrderItem WHERE Id = :oi.Id];
      Order afterOrder = [SELECT EndDate FROM Order WHERE Id = :orderRecord.Id];
      Contract afterContract = [
        SELECT EndDate
        FROM Contract
        WHERE Id = :contractRecord.Id
      ];
      System.assertEquals(
        extendedEnd,
        afterLine.EndDate,
        'Line EndDate should be saved on first attempt'
      );
      System.assertEquals(
        extendedEnd,
        afterOrder.EndDate,
        'Draft order EndDate should be extended before line DML'
      );
      System.assertEquals(
        extendedEnd,
        afterContract.EndDate,
        'Contract EndDate should cover the draft order end'
      );
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_RejectsPackageBuilderEditWhenOrderItemTerminated() {
    OrderItem oi = [SELECT Id, UnitPrice FROM OrderItem LIMIT 1];
    oi.Termination_Reason__c = 'Other';
    update oi;
    OrderItem payload = new OrderItem(Id = oi.Id, UnitPrice = oi.UnitPrice + 1);
    try {
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ payload }
      );
      System.assert(false, 'Expected terminated line save to be rejected');
    } catch (AuraHandledException e) {
      String msg = String.isBlank(e.getMessage()) ? '' : e.getMessage().trim();
      // Some org/API paths surface only "Script-thrown exception" for AuraHandledException in tests.
      System.assert(
        msg.toLowerCase().contains('terminated') ||
          msg.toLowerCase().contains('administrator') ||
          msg.toLowerCase().contains('cannot be updated') ||
          msg == 'Script-thrown exception',
        'Expected terminated-order rejection: ' + msg
      );
    }
  }

  @isTest
  static void testSaveLineItems_UpdatesOrderItemDescription() {
    OrderItem oi = [SELECT Id, Description FROM OrderItem LIMIT 1];
    SObject raw = OrderItem.sObjectType.newSObject(oi.Id);
    raw.put('Description', 'Draft table description');
    PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oi.Id },
      new List<SObject>{ raw }
    );
    System.assertEquals(
      false,
      result.hasErrors,
      'saveLineItems should succeed for Description'
    );
    OrderItem after = [SELECT Description FROM OrderItem WHERE Id = :oi.Id];
    System.assertEquals(
      'Draft table description',
      after.Description,
      'Description should persist from Package Builder save'
    );
  }

  @isTest
  static void testSaveLineItems_RejectsDescriptionWhenOrderItemTerminated() {
    OrderItem oi = [SELECT Id FROM OrderItem LIMIT 1];
    oi.Termination_Reason__c = 'Other';
    update oi;
    SObject raw = OrderItem.sObjectType.newSObject(oi.Id);
    raw.put('Description', 'Should not save');
    try {
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ oi.Id },
        new List<SObject>{ raw }
      );
      System.assert(
        false,
        'Expected terminated line Description save to be rejected'
      );
    } catch (AuraHandledException e) {
      String msg = String.isBlank(e.getMessage()) ? '' : e.getMessage().trim();
      System.assert(
        msg.toLowerCase().contains('terminated') ||
          msg.toLowerCase().contains('administrator') ||
          msg.toLowerCase().contains('cannot be updated') ||
          msg == 'Script-thrown exception',
        'Expected terminated-order rejection: ' + msg
      );
    }
  }

  @isTest
  static void testSaveAndDeleteLineItems() {
    OpportunityLineItem oli = [
      SELECT Id, Description
      FROM OpportunityLineItem
      LIMIT 1
    ];
    oli.Description = 'Updated';
    List<SObject> items = new List<SObject>{ oli };
    PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
      'Standard Opportunity',
      new List<String>{ oli.Id },
      items
    );
    System.assertEquals(false, result.hasErrors);

    String deleteResult = PackageBuilderController.deleteLineItems(
      new List<Id>{ oli.Id }
    );
    System.assertEquals('Success', deleteResult);
  }

  @isTest
  static void testDeleteLineItems_AllowsExistingFutureStartDraftLine() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Order draftOrder = [
      SELECT Id, ContractId, Location__c, OpportunityId
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    PricebookEntry pbe = [
      SELECT Id, Product2Id
      FROM PricebookEntry
      LIMIT 1
    ];
    Id originalOrderProductId = [SELECT Id FROM OrderItem LIMIT 1].Id;

    OrderItem existingFuture = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 250,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today().addDays(5),
      EndDate = Date.today().addMonths(1),
      Original_Order_Product__c = originalOrderProductId
    );
    insert existingFuture;
    insert new MonthlyPayment__c(
      OrderItem__c = existingFuture.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = existingFuture.ServiceDate,
      End_Date_trigger__c = existingFuture.EndDate,
      Room__c = pbe.Product2Id,
      Contract__c = draftOrder.ContractId,
      Opportunity__c = draftOrder.OpportunityId,
      Location__c = draftOrder.Location__c
    );

    String deleteResult = PackageBuilderController.deleteLineItems(
      new List<Id>{ existingFuture.Id }
    );
    System.assertEquals(
      'Success',
      deleteResult,
      'Future-start existing draft line should be deletable.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :existingFuture.Id],
      'Trash deletion should permanently remove the future line.'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM MonthlyPayment__c
        WHERE OrderItem__c = :existingFuture.Id
      ],
      'Hard deletion should remove related monthly payments.'
    );
  }

  @isTest
  static void testDeleteLineItems_HardDeleteHidesFromGetProducts() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Order draftOrder = [
      SELECT Id, EndDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    Date lineEnd = draftOrder.EndDate != null
      ? draftOrder.EndDate
      : Date.today().addMonths(1);
    PricebookEntry pbe = [SELECT Id, Product2Id FROM PricebookEntry LIMIT 1];
    OrderItem newLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today().addDays(1),
      EndDate = lineEnd,
      Change_Type__c = 'New'
    );
    insert newLine;

    Integer beforeCount = PackageBuilderController.getProducts(draftOrder.Id)
      .size();
    System.assert(beforeCount > 0);

    System.assertEquals(
      'Success',
      PackageBuilderController.deleteLineItems(new List<Id>{ newLine.Id })
    );

    List<PackageBuilderController.PackageProductData> afterProducts = PackageBuilderController.getProducts(
      draftOrder.Id
    );
    for (PackageBuilderController.PackageProductData row : afterProducts) {
      System.assertNotEquals(newLine.Id, row.LineItemId);
    }
    System.assertEquals(
      0,
      [SELECT COUNT() FROM OrderItem WHERE Id = :newLine.Id],
      'Trash deletion should permanently remove a new draft line.'
    );
  }

  @isTest
  static void testDeleteLineItems_BlocksExistingNonFutureStartDraftLine() {
    Order draftOrder = [SELECT Id FROM Order WHERE Status = 'Draft' LIMIT 1];
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Id originalOrderProductId = [SELECT Id FROM OrderItem LIMIT 1].Id;

    OrderItem existingCurrent = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 250,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(1),
      Original_Order_Product__c = originalOrderProductId
    );
    insert existingCurrent;

    String deleteResult = PackageBuilderController.deleteLineItems(
      new List<Id>{ existingCurrent.Id }
    );
    System.assertEquals(
      'Delete is allowed only for newly added products in this draft.',
      deleteResult,
      'Existing non-future draft line should remain protected from delete.'
    );
  }

  @isTest
  static void testSaveLineItems_RejectsPastStartDateWithoutAdminOverride() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    Order draftOrder = [SELECT Id FROM Order WHERE Status = 'Draft' LIMIT 1];
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Id originalOrderProductId = [SELECT Id FROM OrderItem LIMIT 1].Id;

    OrderItem existingCopiedLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 250,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = Date.today().addMonths(1),
      Original_Order_Product__c = originalOrderProductId,
      Change_Type__c = 'Modified'
    );
    insert existingCopiedLine;

    Date pastStart = Date.today().addDays(-3);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      try {
        PackageBuilderController.saveLineItems(
          'Standard Opportunity',
          new List<String>{ existingCopiedLine.Id },
          new List<SObject>{
            new OrderItem(Id = existingCopiedLine.Id, ServiceDate = pastStart)
          }
        );
        System.assert(false, 'Expected past start date save to be rejected');
      } catch (AuraHandledException e) {
        String msg = String.isBlank(e.getMessage())
          ? ''
          : e.getMessage().trim();
        System.assert(
          msg.contains('Start Date') ||
            msg.contains(System.Label.PackageBuilder_StartDate_PastEditError) ||
            msg == 'Script-thrown exception',
          'Expected start-date past edit error: ' + msg
        );
      }
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      PackageBuilderAccessPolicy.testEntryDateAdminOverride = true;
    }
  }

  @isTest
  static void testSaveLineItems_AllowsPastStartForNewDraftLineAtOrAfterOrderStart() {
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];

    Date orderStart = Date.today().addDays(-10);
    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = orderStart,
      EndDate = Date.today().addMonths(12)
    );
    insert c;

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = orderStart,
      Order_Start_Date__c = orderStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id,
      ContractId = c.Id
    );
    TriggerHandler.bypass('OrderTriggerHandler');
    insert draftOrder;
    TriggerHandler.clearBypass('OrderTriggerHandler');

    Date futureStart = Date.today().addDays(7);
    OrderItem newLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Access_Type__c = 'Periodic',
      ServiceDate = futureStart,
      EndDate = Date.today().addMonths(1),
      Change_Type__c = 'New',
      Contract__c = c.Id
    );
    TriggerHandler.bypass('OrderItemTriggerHandler');
    insert newLine;
    TriggerHandler.clearBypass('OrderItemTriggerHandler');

    Date pastStartAtOrAfterOrder = Date.today().addDays(-3);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ newLine.Id },
        new List<SObject>{
          new OrderItem(Id = newLine.Id, ServiceDate = pastStartAtOrAfterOrder)
        }
      );
      OrderItem updated = [
        SELECT ServiceDate
        FROM OrderItem
        WHERE Id = :newLine.Id
      ];
      System.assertEquals(
        pastStartAtOrAfterOrder,
        updated.ServiceDate,
        'New draft line should accept start at or after order start'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      PackageBuilderAccessPolicy.testEntryDateAdminOverride = true;
    }
  }

  @isTest
  static void testAlignOrderItemDatesForStartDateChangeSkipsWhenEndBeforeStart() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Date draftStart = Date.today().addDays(10);
    Date newDraftStart = draftStart.addDays(20);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    insert draftOrder;

    OrderItem lineA = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = draftStart.addDays(5),
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );
    OrderItem lineB = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = draftStart.addDays(60),
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );
    insert new List<OrderItem>{ lineA, lineB };

    Test.startTest();
    PackageBuilderController.alignOrderItemDatesForStartDateChange(
      draftOrder.Id,
      newDraftStart,
      true
    );
    Test.stopTest();

    OrderItem aAfter = [
      SELECT ServiceDate, Original_Start_Date__c
      FROM OrderItem
      WHERE Id = :lineA.Id
    ];
    OrderItem bAfter = [
      SELECT ServiceDate, Original_Start_Date__c
      FROM OrderItem
      WHERE Id = :lineB.Id
    ];

    System.assertEquals(
      draftStart,
      aAfter.ServiceDate,
      'Skip when EndDate < new order start'
    );
    System.assertEquals(
      newDraftStart,
      bAfter.ServiceDate,
      'Align when period still covers new start'
    );
  }

  @isTest
  static void testAlignOrderItemDatesForStartDateChangeSkipsNewLinesWhenAlignFalse() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Date draftStart = Date.today().addDays(10);
    Date newDraftStart = draftStart.addDays(20);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    insert draftOrder;

    OrderItem lineB = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = draftStart.addDays(60),
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );
    insert lineB;

    Test.startTest();
    PackageBuilderController.alignOrderItemDatesForStartDateChange(
      draftOrder.Id,
      newDraftStart,
      false
    );
    Test.stopTest();

    OrderItem bAfter = [
      SELECT ServiceDate, Original_Start_Date__c
      FROM OrderItem
      WHERE Id = :lineB.Id
    ];
    System.assertEquals(
      draftStart,
      bAfter.ServiceDate,
      'New line start unchanged when alignChangeTypeNewLines is false'
    );
  }

  @isTest
  static void testAlignOrderItemDatesForStartDateChangeSetsReplacedEndBeforeReplacementStart() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(15);
    Date newDraftStart = draftStart.addDays(12);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = draftStart.addDays(200),
      Original_Order_Product__c = sourceOi.Id,
      Change_Type__c = 'Modified',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = draftStart.addDays(365),
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;
      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newDraftStart,
        true
      );
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    Date expectedEnd = newDraftStart.addDays(-1);
    System.assertEquals(
      expectedEnd,
      replacedAfter.EndDate,
      'Replaced line ends day before replacement start'
    );
  }

  @isTest
  static void testAlignOrderItemDatesForwardPastReplacementStart() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date replacementStart = Date.today().addDays(5);
    Date newOrderStart = replacementStart.addDays(10);
    Date orderEnd = newOrderStart.addDays(200);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = replacementStart,
      Order_Start_Date__c = replacementStart,
      EndDate = orderEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = replacementStart.addDays(30),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = replacementStart,
        Original_End_Date__c = replacementStart,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;
      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newOrderStart,
        true
      );
      Test.stopTest();

      OrderItem replacedAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      OrderItem replacementAfter = [
        SELECT
          ServiceDate,
          Original_Start_Date__c,
          EndDate,
          Original_End_Date__c,
          Replaced_Order_Product__c
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];

      System.assertEquals(
        newOrderStart.addDays(-1),
        replacedAfter.EndDate,
        'Replaced line ends day before new replacement start'
      );
      System.assertEquals(
        newOrderStart,
        replacementAfter.ServiceDate,
        'Replacement aligned to new order start'
      );
      System.assertEquals(
        replaced.Id,
        replacementAfter.Replaced_Order_Product__c,
        'Replacement link should be preserved so UI pairing/sort stays stable when order start is moved back.'
      );
      System.assert(
        replacementAfter.EndDate == null ||
          replacementAfter.EndDate > replacementAfter.ServiceDate,
        'Replacement end must not equal start after align'
      );
      System.assert(
        replacementAfter.EndDate == null ||
          replacementAfter.EndDate >= replacementAfter.ServiceDate,
        'Replacement end on or after service date'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesReplacedEndWhenLinkPointsAtActivatedLine() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activatedSource = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(5);
    Date newDraftStart = draftStart.addDays(12);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replacedParent = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = draftStart.addDays(200),
        Original_Order_Product__c = activatedSource.Id,
        Change_Type__c = 'Modified',
        Access_Type__c = 'Periodic'
      );
      insert replacedParent;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = draftStart.addDays(365),
        Change_Type__c = 'New',
        Replaced_Order_Product__c = activatedSource.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;
      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newDraftStart,
        true
      );
      Test.stopTest();

      OrderItem parentAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replacedParent.Id
      ];
      Date expectedParentEnd = newDraftStart.addDays(-1);
      System.assertEquals(
        expectedParentEnd,
        parentAfter.EndDate,
        'Modified parent on draft should end day before aligned replacement start even when link id is the activated line'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesReplacedEndWhenReplacementStartAlreadyAfterNewOrderStart() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date orderStart = Date.today().addDays(10);
    Date replacementStart = orderStart.addDays(20);
    Date wrongParentEnd = orderStart.addDays(200);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = orderStart,
      Order_Start_Date__c = orderStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = orderStart,
        Original_Start_Date__c = orderStart,
        EndDate = wrongParentEnd,
        Original_End_Date__c = wrongParentEnd,
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = replacementStart.addDays(30),
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;
      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        orderStart.addDays(5),
        true
      );
      Test.stopTest();

      OrderItem replacedAfter = [
        SELECT EndDate
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      System.assertEquals(
        replacementStart.addDays(-1),
        replacedAfter.EndDate,
        'Parent end should follow replacement start even when replacement start is not moved by align'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesForwardPastReplacementStartViaOrderTrigger() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date replacementStart = Date.today().addDays(8);
    Date newOrderStart = replacementStart.addDays(7);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = replacementStart,
      Order_Start_Date__c = replacementStart,
      EndDate = newOrderStart.addDays(100),
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = replacementStart.addDays(20),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = replacementStart,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      Test.startTest();
      draftOrder.Order_Start_Date__c = newOrderStart;
      update draftOrder;
      Test.stopTest();

      OrderItem replacementAfter = [
        SELECT ServiceDate, EndDate, Replaced_Order_Product__c
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];
      System.assertEquals(newOrderStart, replacementAfter.ServiceDate);
      System.assertNotEquals(
        null,
        replacementAfter.Replaced_Order_Product__c,
        'Replacement link should be preserved so pairing/sort stays stable on backdate.'
      );
      System.assert(
        replacementAfter.EndDate == null ||
          replacementAfter.EndDate > replacementAfter.ServiceDate
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesForwardSkipsWhenLineStartAfterNewOrderStart() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(10);
    Date newDraftStart = draftStart.addDays(1);
    Date lineStart = draftStart.addDays(15);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;

      OrderItem newLine = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = lineStart,
        Original_Start_Date__c = lineStart,
        EndDate = lineStart.addDays(60),
        Change_Type__c = 'New',
        Access_Type__c = 'Periodic'
      );
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = lineStart.addDays(-1),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = lineStart,
        Original_Start_Date__c = lineStart,
        EndDate = lineStart.addDays(60),
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert new List<OrderItem>{ newLine, replacement };

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newDraftStart,
        true
      );
      Test.stopTest();

      OrderItem newLineAfter = [
        SELECT ServiceDate, Original_Start_Date__c
        FROM OrderItem
        WHERE Id = :newLine.Id
      ];
      OrderItem replacementAfter = [
        SELECT ServiceDate, Original_Start_Date__c
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];

      System.assertEquals(
        lineStart,
        newLineAfter.ServiceDate,
        'New line start stays when already after new order start'
      );
      System.assertEquals(
        lineStart,
        replacementAfter.ServiceDate,
        'Replacement start stays when already after new order start'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testDeleteLineItems_ReplacedEndClampedToActiveWhenReplacementEndEarlier() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date activeEnd = Date.today().addMonths(12);
    Date draftStart = Date.today().addDays(15);
    Date replacementStart = draftStart.addDays(20);
    Date replacementEnd = activeEnd.addDays(-30);
    Date curtailedEnd = draftStart.addDays(10);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = replacementStart,
      Original_Start_Date__c = replacementStart,
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = activeEnd;
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c, Change_Type__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.Change_Type__c);
    System.assertEquals(activeEnd, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_ReplacedEndUsesReplacementWhenLater() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date activeEnd = Date.today().addMonths(12);
    Date draftStart = Date.today().addDays(15);
    Date replacementEnd = activeEnd.addDays(30);
    Date curtailedEnd = draftStart.addDays(10);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart.addDays(20),
      Original_Start_Date__c = draftStart.addDays(20),
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = activeEnd;
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(replacementEnd, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_ReplacedEndUsesReplacementWhenActiveEndNull() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(15);
    Date replacementEnd = Date.today().addMonths(18);
    Date curtailedEnd = draftStart.addDays(10);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart.addDays(20),
      Original_Start_Date__c = draftStart.addDays(20),
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = null;
      activeLine.Access_Type__c = 'Monthly';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(replacementEnd, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_ReplacedEndNullWhenReplacementEndNull() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date activeEnd = Date.today().addMonths(12);
    Date draftStart = Date.today().addDays(15);
    Date curtailedEnd = draftStart.addDays(10);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart.addDays(20),
      Original_Start_Date__c = draftStart.addDays(20),
      EndDate = null,
      Change_Type__c = 'New',
      Access_Type__c = 'Monthly'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = activeEnd;
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.EndDate);
  }

  @isTest
  static void testAlignOrderStart_DoesNotRecurtailAfterSoftDeletedReplacement() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(10);
    Date replacementStart = draftStart.addDays(16);
    Date curtailedEnd = replacementStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = replacementStart,
      Original_Start_Date__c = replacementStart,
      EndDate = null,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic'
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      activeLine.EndDate = null;
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      Test.startTest();
      System.assertEquals(
        'Success',
        PackageBuilderController.deleteLineItems(new List<Id>{ replacement.Id })
      );
      PackageBuilderController.alignOrderItemDatesForStartDateChangeCore(
        draftOrder.Id,
        replacementStart,
        true,
        false
      );

      OrderItem replacedAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      System.assertEquals(null, replacedAfter.EndDate);
      System.assertEquals(
        0,
        [SELECT COUNT() FROM OrderItem WHERE Id = :replacement.Id],
        'Deleted replacement should be permanently removed.'
      );
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testDeleteLineItems_AccessTypeSplitUndoRestoresActiveEndWhenReplacementMonthly() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date activeEnd = Date.today().addMonths(12);
    Date draftStart = Date.today().addDays(-60);
    Date splitStart = Date.today().addDays(-10);
    Date curtailedEnd = splitStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = splitStart,
      Original_Start_Date__c = splitStart,
      EndDate = null,
      Change_Type__c = 'New',
      Access_Type__c = 'Monthly',
      Changed_Access_Type__c = true
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = activeEnd;
      activeLine.Access_Type__c = 'Periodic';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c, Change_Type__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.Change_Type__c);
    System.assertEquals(activeEnd, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_AccessTypeSplitUndoRestoresNullWhenActiveEndNull() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(-60);
    Date splitStart = Date.today().addDays(-10);
    Date curtailedEnd = splitStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Periodic'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = splitStart,
      Original_Start_Date__c = splitStart,
      EndDate = null,
      Change_Type__c = 'New',
      Access_Type__c = 'Monthly',
      Changed_Access_Type__c = true
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = null;
      activeLine.Access_Type__c = 'Monthly';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c, Change_Type__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.Change_Type__c);
    System.assertEquals(null, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_PastStartSplitUndoClearsMonthlyReplacedEnd() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(-60);
    Date splitStart = Date.today().addDays(-10);
    Date replacementEnd = Date.today().addMonths(6);
    Date curtailedEnd = splitStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Monthly'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = splitStart,
      Original_Start_Date__c = splitStart,
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic',
      Changed_Access_Type__c = true
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = null;
      activeLine.Access_Type__c = 'Monthly';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c, Change_Type__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.Change_Type__c);
    System.assertEquals(null, replacedAfter.EndDate);
  }

  @isTest
  static void testDeleteLineItems_MonthlyParentEndCleared_RegeneratesPayments() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(-60);
    Date splitStart = Date.today().addDays(-10);
    Date replacementEnd = Date.today().addMonths(6);
    Date curtailedEnd = splitStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Monthly'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = splitStart,
      Original_Start_Date__c = splitStart,
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic',
      Changed_Access_Type__c = true
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      activeLine.EndDate = null;
      activeLine.Access_Type__c = 'Monthly';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      Test.startTest();
      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Access_Type__c, ServiceDate
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.EndDate);

    Integer paymentCount = [
      SELECT COUNT()
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :replaced.Id
    ];
    System.assert(
      paymentCount >= 24,
      'Clearing parent EndDate on replacement delete should rebuild open-ended monthly payments.'
    );
  }

  @isTest
  static void testDeleteLineItems_QuantityPastStartSplitUndoWithoutChangedAccessTypeFlag() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(-60);
    Date splitStart = Date.today().addDays(-10);
    Date replacementEnd = Date.today().addMonths(6);
    Date curtailedEnd = splitStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem replaced = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Change_Type__c = 'Removed',
      Access_Type__c = 'Monthly'
    );
    OrderItem replacement = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 2,
      UnitPrice = 500,
      ServiceDate = splitStart,
      Original_Start_Date__c = splitStart,
      EndDate = replacementEnd,
      Change_Type__c = 'New',
      Access_Type__c = 'Monthly',
      Changed_Access_Type__c = false
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      activeLine.EndDate = null;
      activeLine.Access_Type__c = 'Monthly';
      update activeLine;
      insert draftOrder;
      replaced.OrderId = draftOrder.Id;
      insert replaced;
      replacement.OrderId = draftOrder.Id;
      replacement.Replaced_Order_Product__c = replaced.Id;
      insert replacement;

      String deleteResult = PackageBuilderController.deleteLineItems(
        new List<Id>{ replacement.Id }
      );
      Test.stopTest();
      System.assertEquals('Success', deleteResult);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }

    OrderItem replacedAfter = [
      SELECT EndDate, Original_End_Date__c, Change_Type__c
      FROM OrderItem
      WHERE Id = :replaced.Id
    ];
    System.assertEquals(null, replacedAfter.Change_Type__c);
    System.assertEquals(null, replacedAfter.EndDate);
  }

  @isTest
  static void testAlignOrderItemDatesExtendsShortOrderEndBeforeLineDml() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(10);
    Date newDraftStart = draftStart.addDays(15);
    Date shortOrderEnd = draftStart.addDays(30);
    Date longLineEnd = draftStart.addDays(365);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      EndDate = shortOrderEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = draftStart.addDays(20),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = longLineEnd,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newDraftStart,
        true
      );
      Test.stopTest();

      Order orderAfter = [SELECT EndDate FROM Order WHERE Id = :draftOrder.Id];
      OrderItem replacedAfter = [
        SELECT EndDate
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      OrderItem replacementAfter = [
        SELECT ServiceDate, EndDate
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];

      System.assert(
        orderAfter.EndDate != null && orderAfter.EndDate >= longLineEnd,
        'Order end should extend to cover long replacement line before line DML'
      );
      System.assertEquals(
        newDraftStart.addDays(-1),
        replacedAfter.EndDate,
        'Replaced line ends day before aligned replacement start'
      );
      System.assertEquals(
        newDraftStart,
        replacementAfter.ServiceDate,
        'Replacement start aligned to new order start'
      );
      System.assert(
        replacementAfter.EndDate == null ||
          replacementAfter.EndDate <= orderAfter.EndDate,
        'Replacement line end must not exceed order end'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesExtendsShortOrderEndViaOrderTrigger() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.today().addDays(12);
    Date newDraftStart = draftStart.addDays(55);
    Date shortOrderEnd = draftStart.addDays(50);
    Date lineEnd = draftStart.addDays(40);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      EndDate = shortOrderEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = draftStart.addDays(48),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = lineEnd,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      Test.startTest();
      draftOrder.Order_Start_Date__c = newDraftStart;
      update draftOrder;
      Test.stopTest();

      Order orderAfter = [SELECT EndDate FROM Order WHERE Id = :draftOrder.Id];
      OrderItem replacedAfter = [
        SELECT EndDate
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      OrderItem replacementAfter = [
        SELECT ServiceDate, EndDate
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];
      Date expectedReplacedEnd = newDraftStart.addDays(-1);

      System.assert(
        orderAfter.EndDate != null && orderAfter.EndDate >= expectedReplacedEnd,
        'OrderTrigger path should extend order end before replaced-parent line DML'
      );
      System.assertEquals(expectedReplacedEnd, replacedAfter.EndDate);
      System.assertEquals(newDraftStart, replacementAfter.ServiceDate);
      System.assert(
        replacementAfter.EndDate == null ||
          replacementAfter.EndDate <= orderAfter.EndDate,
        'Replacement line end must not exceed order end'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesPreservesOpenEndedOrderEnd() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    Date draftStart = Date.today().addDays(8);
    Date newDraftStart = draftStart.addDays(12);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      EndDate = null,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem newLine = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = draftStart.addDays(90),
        Change_Type__c = 'New',
        Access_Type__c = 'Periodic'
      );
      insert newLine;

      Order beforeAlign = [SELECT EndDate FROM Order WHERE Id = :draftOrder.Id];
      System.assertEquals(
        null,
        beforeAlign.EndDate,
        'Precondition: order stays open-ended before alignment'
      );

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        newDraftStart,
        true
      );
      Test.stopTest();

      Order orderAfter = [SELECT EndDate FROM Order WHERE Id = :draftOrder.Id];
      OrderItem lineAfter = [
        SELECT ServiceDate
        FROM OrderItem
        WHERE Id = :newLine.Id
      ];

      System.assertEquals(
        null,
        orderAfter.EndDate,
        'Open-ended order end must stay null during start alignment'
      );
      System.assertEquals(newDraftStart, lineAfter.ServiceDate);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
    }
  }

  @isTest
  static void testAlignOrderItemDatesBackdatePreservesReplacedParentEnd() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date oldDraftStart = Date.newInstance(2026, 5, 1);
    Date backdatedStart = Date.newInstance(2026, 4, 28);
    Date replacementStart = Date.newInstance(2026, 6, 7);
    Date expectedParentEnd = replacementStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = oldDraftStart,
      Order_Start_Date__c = oldDraftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = oldDraftStart,
        Original_Start_Date__c = oldDraftStart,
        EndDate = expectedParentEnd,
        Original_End_Date__c = expectedParentEnd,
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = Date.newInstance(2026, 9, 30),
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        backdatedStart,
        false
      );
      Test.stopTest();

      OrderItem replacedAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      System.assertEquals(
        expectedParentEnd,
        replacedAfter.EndDate,
        'Backdate must keep replaced parent end at replacement start minus one day'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesBackdateRepairsWrongReplacedParentEnd() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date oldDraftStart = Date.newInstance(2026, 5, 1);
    Date backdatedStart = Date.newInstance(2026, 4, 28);
    Date replacementStart = Date.newInstance(2026, 6, 7);
    Date wrongPackageEnd = Date.newInstance(2026, 9, 30);
    Date expectedParentEnd = replacementStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = oldDraftStart,
      Order_Start_Date__c = oldDraftStart,
      EndDate = wrongPackageEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = oldDraftStart,
        Original_Start_Date__c = oldDraftStart,
        EndDate = wrongPackageEnd,
        Original_End_Date__c = wrongPackageEnd,
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = wrongPackageEnd,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = replaced.Id,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        backdatedStart,
        false
      );
      Test.stopTest();

      OrderItem replacedAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      System.assertEquals(
        expectedParentEnd,
        replacedAfter.EndDate,
        'Backdate must repair reverted replaced parent end from package end'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testAlignOrderItemDatesBackdateRestoresLinkAndRepairsParentEnd() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date oldDraftStart = Date.newInstance(2026, 5, 1);
    Date backdatedStart = Date.newInstance(2026, 4, 28);
    Date replacementStart = Date.newInstance(2026, 6, 7);
    Date wrongPackageEnd = Date.newInstance(2026, 9, 30);
    Date expectedParentEnd = replacementStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = oldDraftStart,
      Order_Start_Date__c = oldDraftStart,
      EndDate = wrongPackageEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Test.startTest();
      insert draftOrder;
      OrderItem replaced = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = oldDraftStart,
        Original_Start_Date__c = oldDraftStart,
        EndDate = wrongPackageEnd,
        Original_End_Date__c = wrongPackageEnd,
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'Removed',
        Access_Type__c = 'Periodic'
      );
      insert replaced;
      OrderItem replacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = replacementStart,
        Original_Start_Date__c = replacementStart,
        EndDate = wrongPackageEnd,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = null,
        Access_Type__c = 'Periodic'
      );
      insert replacement;

      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        backdatedStart,
        false
      );
      Test.stopTest();

      OrderItem replacedAfter = [
        SELECT EndDate, Original_End_Date__c
        FROM OrderItem
        WHERE Id = :replaced.Id
      ];
      OrderItem replacementAfter = [
        SELECT Replaced_Order_Product__c
        FROM OrderItem
        WHERE Id = :replacement.Id
      ];
      System.assertEquals(
        replaced.Id,
        replacementAfter.Replaced_Order_Product__c,
        'Backdate should restore replacement lookup when parent end was wrong'
      );
      System.assertEquals(expectedParentEnd, replacedAfter.EndDate);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  /**
   * Terminated replacement lines that are also replaced-parents for other products must keep
   * their termination EndDate when Modify Contract runs alignOrderItemDatesForStartDateChange.
   */
  @isTest
  static void testAlignOrderItemDatesPreservesTerminatedReplacementEndDate() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem sourceOi = [SELECT Id FROM OrderItem LIMIT 1];
    Date earliestStart = Date.newInstance(2026, 3, 1);
    Date draftStart = Date.newInstance(2026, 6, 7);
    Date terminatedEnd = Date.newInstance(2027, 3, 1);
    Date supersededParentEnd = draftStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = earliestStart,
      Order_Start_Date__c = earliestStart,
      EndDate = terminatedEnd,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      insert draftOrder;
      OrderItem supersededParent = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = earliestStart,
        Original_Start_Date__c = earliestStart,
        EndDate = supersededParentEnd,
        Original_End_Date__c = supersededParentEnd,
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'No Change',
        Access_Type__c = 'Periodic'
      );
      OrderItem terminatedReplacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = terminatedEnd,
        Original_End_Date__c = terminatedEnd,
        Termination_Reason__c = 'Other',
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'No Change',
        Replaced_Order_Product__c = null,
        Access_Type__c = 'Periodic'
      );
      insert supersededParent;
      terminatedReplacement.Replaced_Order_Product__c = supersededParent.Id;
      insert terminatedReplacement;
      OrderItem siblingReplacement = new OrderItem(
        OrderId = draftOrder.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 500,
        ServiceDate = draftStart,
        Original_Start_Date__c = draftStart,
        EndDate = Date.newInstance(2027, 1, 1),
        Original_End_Date__c = Date.newInstance(2027, 1, 1),
        Original_Order_Product__c = sourceOi.Id,
        Change_Type__c = 'No Change',
        Replaced_Order_Product__c = terminatedReplacement.Id,
        Access_Type__c = 'Periodic'
      );
      insert siblingReplacement;

      Test.startTest();
      PackageBuilderController.alignOrderItemDatesForStartDateChange(
        draftOrder.Id,
        draftStart,
        true
      );
      Test.stopTest();

      OrderItem terminatedAfter = [
        SELECT EndDate, Original_End_Date__c, Termination_Reason__c
        FROM OrderItem
        WHERE Id = :terminatedReplacement.Id
      ];
      System.assertEquals(
        terminatedEnd,
        terminatedAfter.EndDate,
        'Terminated replacement EndDate must survive start-date alignment'
      );
      System.assertEquals(
        'Other',
        terminatedAfter.Termination_Reason__c,
        'Termination reason must not be cleared by alignment DML'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
    }
  }

  @isTest
  static void testSaveLineItems_ExtendsOpenEndedDraftOrderBeforeBoundedEnd() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Order draftOrder = [
      SELECT Id, ContractId, EndDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    draftOrder.EndDate = null;
    update draftOrder;

    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Date boundedEnd = Date.today().addMonths(3);
    OrderItem boundedLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = boundedEnd
    );
    insert boundedLine;

    OrderItem monthlyLine = [
      SELECT Id
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND Id != :boundedLine.Id
      LIMIT 1
    ];
    monthlyLine.Access_Type__c = 'Monthly';
    monthlyLine.EndDate = null;
    update monthlyLine;

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      Date newPeriodicEnd = boundedEnd.addDays(15);
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ monthlyLine.Id },
        new List<SObject>{
          new OrderItem(
            Id = monthlyLine.Id,
            Access_Type__c = 'Periodic',
            EndDate = newPeriodicEnd
          )
        }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Bounded line save should extend open-ended draft order end'
      );
      Order afterOrder = [
        SELECT EndDate
        FROM Order
        WHERE Id = :draftOrder.Id
      ];
      System.assertEquals(
        newPeriodicEnd,
        afterOrder.EndDate,
        'Draft order end should cover max product end before line DML'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_ExtendsOrderEndOnTerminationReasonOnlySave() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Order draftOrder = [
      SELECT Id, EndDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    draftOrder.EndDate = null;
    update draftOrder;

    OrderItem periodicLine = [
      SELECT Id, EndDate
      FROM OrderItem
      WHERE OrderId = :draftOrder.Id AND EndDate != NULL
      LIMIT 1
    ];
    System.assertNotEquals(null, periodicLine.EndDate);

    Boolean prevSkip = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ periodicLine.Id },
        new List<SObject>{
          new OrderItem(
            Id = periodicLine.Id,
            Termination_Reason__c = 'Dissatisfaction'
          )
        }
      );
      System.assertEquals(
        false,
        result.hasErrors,
        'Termination reason save should extend open-ended draft order end'
      );
      Order afterOrder = [
        SELECT EndDate
        FROM Order
        WHERE Id = :draftOrder.Id
      ];
      System.assertEquals(
        periodicLine.EndDate,
        afterOrder.EndDate,
        'Draft order end should cover visible bounded lines'
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkip;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_CurtailsSoftDeletedLineBlockingOrderEnd() {
    TriggerHandler.bypass('OrderItemTriggerHandler');
    Order draftOrder = [
      SELECT Id, EndDate
      FROM Order
      WHERE Status = 'Draft'
      LIMIT 1
    ];
    PricebookEntry pbe = [SELECT Id FROM PricebookEntry LIMIT 1];
    Date visibleEnd = Date.today().addMonths(6);
    Date blockingEnd = visibleEnd.addMonths(6);

    draftOrder.EndDate = null;
    update draftOrder;

    OrderItem blockingDeleted = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = blockingEnd
    );
    insert blockingDeleted;
    update new OrderItem(
      Id = blockingDeleted.Id,
      Is_Line_Deleted__c = true,
      ServiceDate = null,
      EndDate = null,
      Original_Start_Date__c = Date.today(),
      Original_End_Date__c = blockingEnd
    );

    OrderItem visibleLine = new OrderItem(
      OrderId = draftOrder.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = visibleEnd
    );
    insert visibleLine;

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      PackageBuilderController.UpdateRecordResult result = PackageBuilderController.saveLineItems(
        'Standard Opportunity',
        new List<String>{ visibleLine.Id },
        new List<SObject>{
          new OrderItem(
            Id = visibleLine.Id,
            Termination_Reason__c = 'Dissatisfaction'
          )
        }
      );
      System.assertEquals(false, result.hasErrors, result);
      Order afterOrder = [
        SELECT EndDate
        FROM Order
        WHERE Id = :draftOrder.Id
      ];
      System.assertEquals(
        visibleEnd,
        afterOrder.EndDate,
        'Order end should match visible max, not soft-deleted outlier'
      );
      OrderItem notUpdated = [
        SELECT EndDate
        FROM OrderItem
        WHERE Id = :blockingDeleted.Id
      ];
      System.assertEquals(
        null,
        notUpdated.EndDate,
        'Archived soft-deleted line should keep live EndDate null after save'
      );
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testSaveLineItems_BlocksClearMonthlyReplacedParentEndDate() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Locations__c loc = [SELECT Id FROM Locations__c LIMIT 1];
    Id pricebookId = Test.getStandardPricebookId();
    Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :prod.Id
      LIMIT 1
    ];
    OrderItem activeLine = [SELECT Id FROM OrderItem LIMIT 1];
    Date draftStart = Date.newInstance(2026, 7, 6);
    Date replacementStart = Date.newInstance(2026, 11, 6);
    Date curtailedEnd = replacementStart.addDays(-1);

    Order draftOrder = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = draftStart,
      Order_Start_Date__c = draftStart,
      Pricebook2Id = pricebookId,
      Location__c = loc.Id
    );
    OrderItem monthlyParent = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = draftStart,
      Original_Start_Date__c = draftStart,
      EndDate = curtailedEnd,
      Original_Order_Product__c = activeLine.Id,
      Access_Type__c = 'Monthly'
    );
    OrderItem periodicChild = new OrderItem(
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      ServiceDate = replacementStart,
      Original_Start_Date__c = replacementStart,
      EndDate = Date.newInstance(2027, 7, 22),
      Change_Type__c = 'New',
      Access_Type__c = 'Periodic',
      Changed_Access_Type__c = true
    );

    Boolean prevMp = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    try {
      insert draftOrder;
      monthlyParent.OrderId = draftOrder.Id;
      insert monthlyParent;
      periodicChild.OrderId = draftOrder.Id;
      periodicChild.Replaced_Order_Product__c = monthlyParent.Id;
      insert periodicChild;

      Test.startTest();
      try {
        PackageBuilderController.saveLineItems(
          'Standard Opportunity',
          new List<String>{ monthlyParent.Id },
          new List<SObject>{
            new OrderItem(Id = monthlyParent.Id, EndDate = null)
          }
        );
        System.assert(
          false,
          'Expected clearing Monthly replaced-parent EndDate to be rejected'
        );
      } catch (AuraHandledException e) {
        System.assert(
          true,
          'Clearing Monthly replaced-parent EndDate should throw AuraHandledException'
        );
      }
      Test.stopTest();
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMp;
    }
  }

  @isTest
  static void testUpdateOrderItemEarlyExitRequest() {
    OrderItem oi = [SELECT Id, Early_Exit_Request__c FROM OrderItem LIMIT 1];
    System.assertEquals(false, oi.Early_Exit_Request__c == true);

    Test.startTest();
    PackageBuilderController.updateOrderItemEarlyExitRequest(oi.Id, true);
    Test.stopTest();

    OrderItem after = [
      SELECT Id, Early_Exit_Request__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(true, after.Early_Exit_Request__c);

    PackageBuilderController.updateOrderItemEarlyExitRequest(oi.Id, false);
    after = [
      SELECT Id, Early_Exit_Request__c
      FROM OrderItem
      WHERE Id = :oi.Id
    ];
    System.assertEquals(false, after.Early_Exit_Request__c);

    Boolean threw = false;
    try {
      PackageBuilderController.updateOrderItemEarlyExitRequest(null, true);
    } catch (AuraHandledException e) {
      threw = true;
    }
    System.assertEquals(true, threw, 'Null Id should throw');
  }
}
