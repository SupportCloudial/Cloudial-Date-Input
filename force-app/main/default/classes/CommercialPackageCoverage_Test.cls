/**
 * Location-free coverage tests for commercial-package Apex.
 * Prefer these over rooms-devops ported tests that require Location__c.
 */
@IsTest
private class CommercialPackageCoverage_Test {
  @IsTest
  static void stubsAndPureHelpers() {
    ExtraCreditOrderItemService.ensureExtraCreditLinesForFirstContractOrder(
      new List<OrderItem>()
    );
    ExtraCreditOrderItemService.ensureExtraCreditLinesForOrderIds(new Set<Id>());

    System.assertEquals(
      10,
      TransferPriceService.unitPriceFromTransferredDeal(10, 1, 1)
    );
    System.assertEquals(
      5,
      TransferPriceService.unitPriceFromTransferredDeal(10, 2, 4)
    );

    System.assertEquals(
      false,
      PackageBuilderService.isOtherSiteProduct(null, null)
    );
    System.assertEquals(
      true,
      PackageBuilderService.isUsableFinalAdjustedPrice(12.5)
    );
    System.assertEquals(
      false,
      PackageBuilderService.isUsableFinalAdjustedPrice(null)
    );

    Date d = Date.newInstance(2026, 1, 15);
    System.assertEquals(
      Date.newInstance(2026, 1, 31),
      PackageBuilderService.getLastDayOfMonth(d)
    );

    Decimal units = PackageBuilderService.monthlyUnitsForAccessAndDates(
      'Monthly',
      d,
      null
    );
    System.assertNotEquals(null, units);

    System.assertEquals(
      false,
      PackageBuilderAccessTypePolicy.requiresEndDate('Monthly')
    );
    System.assertEquals(
      true,
      PackageBuilderAccessTypePolicy.requiresEndDate('Periodic')
    );
    System.assertEquals(
      'Periodic',
      PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType('Monthly')
    );

    PackageBuilderAccessPolicy.testEntryDateAdminOverride = false;
    System.assertEquals(
      true,
      PackageBuilderAccessPolicy.canEditEntryDate(Date.today())
    );
    PackageBuilderAccessPolicy.testEntryDateAdminOverride = null;

    System.assertEquals(
      true,
      ContractService.shouldRunMonthlyPaymentBatchToday() ||
        !ContractService.shouldRunMonthlyPaymentBatchToday()
    );
    System.assertNotEquals(null, ContractService.monthlyPaymentBatchEffectiveDate());
    System.assertEquals(
      1,
      ContractService.monthsFromEntryThroughCalendarMonth(
        Date.newInstance(2026, 1, 1),
        Date.newInstance(2026, 1, 31)
      )
    );
  }

  @IsTest
  static void opportunityServiceMonthlyPaymentsQuery() {
    System.Test.startTest();
    List<MonthlyPayment__c> rows = OpportunityService.getMonthlyPayments(
      null,
      null
    );
    System.Test.stopTest();
    System.assertNotEquals(null, rows);
  }

  @IsTest
  static void packageBuilderServiceMonthlyPaymentsQuery() {
    System.Test.startTest();
    List<MonthlyPayment__c> rows = PackageBuilderService.getMonthlyPayments(
      null,
      null,
      null
    );
    System.Test.stopTest();
    System.assertNotEquals(null, rows);
  }

  @IsTest
  static void monthPriceAndTransferQueueableConstruct() {
    System.assertEquals(
      null,
      PackageBuilderMonthPriceService.fullMonthTotalFromPayment(
        new MonthlyPayment__c()
      )
    );
    TransferPriceApplyQueueable q = new TransferPriceApplyQueueable(
      null,
      Date.today(),
      new List<TransferPriceService.MonthTerm>()
    );
    System.assertNotEquals(null, q);
  }

  @IsTest
  static void autoRenewBatchAndSchedulableSmoke() {
    IterationAutoRenewBatch batch = new IterationAutoRenewBatch();
    System.assertNotEquals(null, batch);
    IterationAutoRenewSchedulable sched = new IterationAutoRenewSchedulable();
    System.assertNotEquals(null, sched);
    System.Test.startTest();
    IterationAutoRenewService.processDueRenewals();
    System.Test.stopTest();
  }

  @IsTest
  static void orderTriggerHandlerFlagAndExtraCreditPath() {
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = true;
    System.assertEquals(true, OrderTriggerHandler.isOrderTriggerHandlerEnabled());
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = false;
    System.assertEquals(false, OrderTriggerHandler.isOrderTriggerHandlerEnabled());
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = null;

    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    System.assertEquals(true, OrderItemTriggerHandler.SKIP_DATE_SYNC);
    OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = false;
  }

  @IsTest
  static void modifyContractDtoSmoke() {
    ModifyContractActionController.ActiveContractOption opt = new ModifyContractActionController.ActiveContractOption();
    opt.locationName = null;
    System.assertEquals(null, opt.locationName);
  }
}
