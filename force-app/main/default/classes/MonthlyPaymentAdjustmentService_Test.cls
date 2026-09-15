@isTest
private class MonthlyPaymentAdjustmentService_Test {
  @isTest
  static void legacyPercentageSaveBuildsTypedSetRequest() {
    Id paymentId = fakePaymentId('1');
    MonthlyPayment__c updateRecord = new MonthlyPayment__c(
      Id = paymentId,
      Discount__c = 12.5
    );

    List<MonthlyPaymentAdjustmentService.AdjustmentRequest> requests = MonthlyPaymentAdjustmentService.requestsFromPaymentUpdates(
      new List<MonthlyPayment__c>{ updateRecord }
    );

    Assert.areEqual(1, requests.size());
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = requests[0];
    Assert.areEqual(paymentId, request.paymentId);
    Assert.areEqual(
      MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE,
      request.inputType
    );
    Assert.areEqual(12.5, request.inputValue);
    Assert.areEqual(MonthlyPaymentAdjustmentService.ACTION_SET, request.action);
    Assert.isNotNull(request.currentStateExpectation);
    Assert.areEqual(updateRecord, request.paymentUpdate);
  }

  @isTest
  static void legacyExactFinalSaveRemainsOutsidePercentageAdjustment() {
    Id paymentId = fakePaymentId('2');
    MonthlyPayment__c updateRecord = new MonthlyPayment__c(
      Id = paymentId,
      Discount__c = 10,
      Final_Adjusted_Price__c = 1100
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest request = MonthlyPaymentAdjustmentService.requestsFromPaymentUpdates(
      new List<MonthlyPayment__c>{ updateRecord }
    )[0];

    Assert.areEqual(
      MonthlyPaymentAdjustmentService.INPUT_FINAL,
      request.inputType
    );
    Assert.areEqual(1100, request.inputValue);
    Assert.areEqual(MonthlyPaymentAdjustmentService.ACTION_SET, request.action);
  }

  @isTest
  static void usageBasedNullFinalRemainsAValidDirectFinalRequest() {
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = MonthlyPaymentAdjustmentService.requestsFromPaymentUpdates(
      new List<MonthlyPayment__c>{
        new MonthlyPayment__c(Id = fakePaymentId('6'), ListPrice__c = null)
      }
    )[0];

    Assert.areEqual(
      MonthlyPaymentAdjustmentService.INPUT_FINAL,
      request.inputType
    );
    Assert.isNull(request.inputValue);
    Assert.areEqual(MonthlyPaymentAdjustmentService.ACTION_SET, request.action);
  }

  @isTest
  static void contractCarriesExpectationActionAndCalculatedOutcome() {
    MonthlyPaymentAdjustmentService.CurrentStateExpectation expectation = new MonthlyPaymentAdjustmentService.CurrentStateExpectation();
    expectation.discount = 5;
    expectation.finalPrice = 1050;
    expectation.lastModifiedDate = Datetime.newInstance(2026, 9, 1, 12, 0, 0);

    MonthlyPaymentAdjustmentService.AdjustmentRequest request = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    request.paymentId = fakePaymentId('3');
    request.inputType = MonthlyPaymentAdjustmentService.INPUT_AMOUNT;
    request.inputValue = 100;
    request.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    request.currentStateExpectation = expectation;

    MonthlyPaymentAdjustmentService.CalculatedOutcome outcome = new MonthlyPaymentAdjustmentService.CalculatedOutcome();
    outcome.originalPrice = 1000;
    outcome.existingAdjustment = 50;
    outcome.priceBefore = 1050;
    outcome.resultingAdjustment = 100;
    outcome.finalPriceAfter = 1100;

    MonthlyPaymentAdjustmentService.AdjustmentResult result = new MonthlyPaymentAdjustmentService.AdjustmentResult();
    result.paymentId = request.paymentId;
    result.inputType = request.inputType;
    result.inputValue = request.inputValue;
    result.action = request.action;
    result.calculatedOutcome = outcome;

    Assert.areEqual(5, request.currentStateExpectation.discount);
    Assert.areEqual(1050, request.currentStateExpectation.finalPrice);
    Assert.areEqual(
      MonthlyPaymentAdjustmentService.ACTION_REPLACE,
      result.action
    );
    Assert.areEqual(1000, result.calculatedOutcome.originalPrice);
    Assert.areEqual(1050, result.calculatedOutcome.priceBefore);
    Assert.areEqual(1100, result.calculatedOutcome.finalPriceAfter);
  }

  @isTest
  static void packageBuilderEntryDelegatesBulkSaveToSharedService() {
    MonthlyPaymentAdjustmentService.applyInvocationCount = 0;
    List<MonthlyPayment__c> updates = new List<MonthlyPayment__c>{
      new MonthlyPayment__c(Id = fakePaymentId('4'), Discount__c = 5),
      new MonthlyPayment__c(Id = fakePaymentId('5'), Discount__c = 10)
    };

    try {
      PackageBuilderService.updateDiscount(updates);
      Assert.fail('Fake payment identities should not persist.');
    } catch (AuraHandledException expected) {
      Assert.areEqual(1, MonthlyPaymentAdjustmentService.applyInvocationCount);
    }
  }

  @isTest
  static void firstPercentageSetPersistsPaymentAndCompleteHistory() {
    MonthlyPayment__c payment = createOpportunityPayment();

    Test.startTest();
    List<MonthlyPaymentAdjustmentService.AdjustmentResult> results = MonthlyPaymentAdjustmentService.apply(
      new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
        percentageSetRequest(payment.Id, 10)
      }
    );
    Test.stopTest();

    MonthlyPayment__c savedPayment = [
      SELECT
        Price__c,
        Discount__c,
        Final_Adjusted_Price__c,
        User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Monthly_Payment_Adjustment_History__c history = [
      SELECT
        Monthly_Payment__c,
        Adjustment_Type__c,
        Action__c,
        Original_Price__c,
        Existing_Adjustment__c,
        Entered_Adjustment__c,
        Resulting_Adjustment__c,
        Price_Before__c,
        Price_After__c,
        CreatedById,
        CreatedDate
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];

    Assert.areEqual(1, results.size());
    Assert.areEqual(10, savedPayment.Discount__c);
    Assert.areEqual(1100, savedPayment.Final_Adjusted_Price__c);
    Assert.areEqual(
      0,
      savedPayment.User_Price_Adjustment__c,
      'Task 2 bookkeeping must remain unchanged when no recurring rule applies.'
    );
    Assert.areEqual(payment.Id, history.Monthly_Payment__c);
    Assert.areEqual('Percentage', history.Adjustment_Type__c);
    Assert.areEqual('Set', history.Action__c);
    Assert.areEqual(1000, history.Original_Price__c);
    Assert.areEqual(0, history.Existing_Adjustment__c);
    Assert.areEqual(10, history.Entered_Adjustment__c);
    Assert.areEqual(10, history.Resulting_Adjustment__c);
    Assert.areEqual(1000, history.Price_Before__c);
    Assert.areEqual(1100, history.Price_After__c);
    Assert.areEqual(UserInfo.getUserId(), history.CreatedById);
    Assert.isNotNull(history.CreatedDate);
  }

  @isTest
  static void zeroOnCleanPaymentIsNoOpWithoutHistory() {
    MonthlyPayment__c payment = createOpportunityPayment();
    MonthlyPayment__c beforeSave = [
      SELECT Discount__c, Final_Adjusted_Price__c, LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];

    Test.startTest();
    List<MonthlyPaymentAdjustmentService.AdjustmentResult> results = MonthlyPaymentAdjustmentService.apply(
      new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
        percentageSetRequest(payment.Id, 0)
      }
    );
    Test.stopTest();

    MonthlyPayment__c savedPayment = [
      SELECT Discount__c, Final_Adjusted_Price__c, LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Assert.areEqual(1, results.size());
    Assert.areEqual(beforeSave.Discount__c, savedPayment.Discount__c);
    Assert.areEqual(
      beforeSave.Final_Adjusted_Price__c,
      savedPayment.Final_Adjusted_Price__c
    );
    Assert.areEqual(beforeSave.LastModifiedDate, savedPayment.LastModifiedDate);
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void failedSetRollsBackPaymentAndHistory() {
    MonthlyPayment__c payment = createOpportunityPayment();
    MonthlyPaymentAdjustmentService.AdjustmentRequest missingPaymentRequest = percentageSetRequest(
      fakePaymentId('9'),
      20
    );
    Boolean threw = false;

    Test.startTest();
    try {
      MonthlyPaymentAdjustmentService.apply(
        new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
          percentageSetRequest(payment.Id, 10),
          missingPaymentRequest
        }
      );
    } catch (Exception expected) {
      threw = true;
    }
    Test.stopTest();

    Assert.isTrue(
      threw,
      'The invalid payment identity must fail the operation.'
    );
    Assert.areEqual(
      0,
      [
        SELECT Discount__c
        FROM MonthlyPayment__c
        WHERE Id = :payment.Id
      ]
      .Discount__c
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void splitMonthSetRecordsWeightedEffectiveResult() {
    MonthlyPayment__c payment = createSplitOrderPayment();

    Test.startTest();
    MonthlyPaymentAdjustmentService.apply(
      new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
        percentageSetRequest(payment.Id, 10)
      }
    );
    Test.stopTest();

    Decimal expectedWeighted = (10.0 *
      16 /
      30)
      .setScale(6, System.RoundingMode.HALF_UP);
    MonthlyPayment__c savedPayment = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Monthly_Payment_Adjustment_History__c history = [
      SELECT Entered_Adjustment__c, Resulting_Adjustment__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];
    Assert.areEqual(expectedWeighted, savedPayment.Discount__c);
    Assert.areEqual(10, history.Entered_Adjustment__c);
    Assert.areEqual(expectedWeighted, history.Resulting_Adjustment__c);
  }

  @isTest
  static void splitMonthLegacyEntryKeepsVisibleEnteredPercentageInHistory() {
    MonthlyPayment__c payment = createSplitOrderPayment();
    Decimal visibleEnteredPercentage = 10;
    Decimal reverseWeightedTransport = (visibleEnteredPercentage *
      30 /
      16)
      .setScale(6, System.RoundingMode.HALF_UP);

    Test.startTest();
    PackageBuilderService.updateDiscountWithEnteredPercentages(
      new List<MonthlyPayment__c>{
        new MonthlyPayment__c(
          Id = payment.Id,
          Discount__c = reverseWeightedTransport
        )
      },
      new Map<Id, Decimal>{ payment.Id => visibleEnteredPercentage }
    );
    Test.stopTest();

    MonthlyPayment__c savedPayment = [
      SELECT Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Monthly_Payment_Adjustment_History__c history = [
      SELECT Entered_Adjustment__c, Resulting_Adjustment__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];
    Assert.areEqual(
      visibleEnteredPercentage,
      savedPayment.Discount__c,
      'Reverse-weighted transport must preserve existing split pricing.'
    );
    Assert.areEqual(
      visibleEnteredPercentage,
      history.Entered_Adjustment__c,
      'History must retain the user-visible percentage, not transport math.'
    );
    Assert.areEqual(visibleEnteredPercentage, history.Resulting_Adjustment__c);
  }

  @isTest
  static void adjustedPreviewRejectsAuthoritativeZeroEffectiveDiscount() {
    MonthlyPayment__c payment = createOpportunityPayment();
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );

    Boolean rejected = false;
    try {
      MonthlyPaymentAdjustmentService.previewIndividualPercentage(request);
    } catch (AuraHandledException expected) {
      rejected = true;
    }

    Assert.isTrue(
      rejected,
      'A clean row must stay on the direct first-time Set flow.'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void previewAndApplyReplacePercentageUseOriginalPrice() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );

    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
      request
    );
    request.currentStateExpectation = preview.currentStateExpectation;
    MonthlyPaymentAdjustmentService.AdjustmentResult applied = MonthlyPaymentAdjustmentService.applyIndividualPercentage(
      request
    );

    Assert.areEqual(1000, preview.calculatedOutcome.originalPrice);
    Assert.areEqual(5, preview.calculatedOutcome.existingAdjustment);
    Assert.areEqual(1050, preview.calculatedOutcome.priceBefore);
    Assert.areEqual(10, preview.calculatedOutcome.resultingAdjustment);
    Assert.areEqual(1100, preview.calculatedOutcome.finalPriceAfter);
    Assert.areEqual(
      preview.calculatedOutcome.finalPriceAfter,
      applied.calculatedOutcome.finalPriceAfter,
      'Preview and apply must share the same calculation.'
    );
    Monthly_Payment_Adjustment_History__c history = [
      SELECT
        Action__c,
        Existing_Adjustment__c,
        Entered_Adjustment__c,
        Resulting_Adjustment__c,
        Price_Before__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];
    Assert.areEqual('Replace', history.Action__c);
    Assert.areEqual(5, history.Existing_Adjustment__c);
    Assert.areEqual(10, history.Entered_Adjustment__c);
    Assert.areEqual(10, history.Resulting_Adjustment__c);
    Assert.areEqual(1050, history.Price_Before__c);
    Assert.areEqual(1100, history.Price_After__c);
  }

  @isTest
  static void addPercentageCompoundsAndRecordsCumulativePercentage() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_ADD
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
      request
    );
    request.currentStateExpectation = preview.currentStateExpectation;

    MonthlyPaymentAdjustmentService.applyIndividualPercentage(request);

    MonthlyPayment__c saved = [
      SELECT Discount__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Monthly_Payment_Adjustment_History__c history = [
      SELECT
        Action__c,
        Entered_Adjustment__c,
        Resulting_Adjustment__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];
    Assert.areEqual(15.5, saved.Discount__c);
    Assert.areEqual(1155, saved.Final_Adjusted_Price__c);
    Assert.areEqual('Add', history.Action__c);
    Assert.areEqual(10, history.Entered_Adjustment__c);
    Assert.areEqual(15.5, history.Resulting_Adjustment__c);
    Assert.areEqual(1155, history.Price_After__c);
  }

  @isTest
  static void zeroAndNegativeAdjustedPercentageSemanticsArePreserved() {
    MonthlyPayment__c replacePayment = createOpportunityPayment();
    MonthlyPayment__c addPayment = createOpportunityPayment();
    update new List<MonthlyPayment__c>{
      new MonthlyPayment__c(
        Id = replacePayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      ),
      new MonthlyPayment__c(
        Id = addPayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      )
    };
    MonthlyPaymentAdjustmentService.AdjustmentRequest replaceRequest = adjustedPercentageRequest(
      replacePayment.Id,
      -10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    replaceRequest.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
        replaceRequest
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualPercentage(replaceRequest);

    MonthlyPaymentAdjustmentService.AdjustmentRequest addZeroRequest = adjustedPercentageRequest(
      addPayment.Id,
      0,
      MonthlyPaymentAdjustmentService.ACTION_ADD
    );
    addZeroRequest.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
        addZeroRequest
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualPercentage(addZeroRequest);

    Assert.areEqual(
      900,
      [
        SELECT Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id = :replacePayment.Id
      ]
      .Final_Adjusted_Price__c
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :addPayment.Id
      ],
      'Add zero must not write history.'
    );
  }

  @isTest
  static void replaceZeroResetsAndStalePreviewIsRejected() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      0,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    request.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
        request
      )
      .currentStateExpectation;
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 7,
      Final_Adjusted_Price__c = 1070
    );

    Boolean rejected = false;
    try {
      MonthlyPaymentAdjustmentService.applyIndividualPercentage(request);
    } catch (AuraHandledException expected) {
      rejected = true;
    }
    Assert.isTrue(rejected, 'A stale preview must be rejected.');
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );

    request.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
        request
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualPercentage(request);
    Monthly_Payment_Adjustment_History__c history = [
      SELECT Action__c, Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
    ];
    Assert.areEqual('Replace', history.Action__c);
    Assert.areEqual(1000, history.Price_After__c);
  }

  @isTest
  static void adjustedSplitOrderPreviewMatchesApply() {
    MonthlyPayment__c payment = createSplitOrderPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = payment.Price__c * 1.05
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
      request
    );
    request.currentStateExpectation = preview.currentStateExpectation;

    MonthlyPaymentAdjustmentService.AdjustmentResult applied = MonthlyPaymentAdjustmentService.applyIndividualPercentage(
      request
    );

    Assert.areEqual(
      preview.calculatedOutcome.finalPriceAfter,
      applied.calculatedOutcome.finalPriceAfter
    );
    Assert.areEqual(
      preview.calculatedOutcome.resultingAdjustment,
      applied.calculatedOutcome.resultingAdjustment
    );
    Assert.areEqual(
      payment.Price__c * 1.1,
      applied.calculatedOutcome.finalPriceAfter
    );
  }

  @isTest
  static void recurringAffectedOpportunityWarnsWithoutRestacking() {
    MonthlyPayment__c payment = createOpportunityPayment();
    MonthlyPayment__c withParent = [
      SELECT OpportunityLineItem__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    update new OpportunityLineItem(
      Id = withParent.OpportunityLineItem__c,
      Recurring_Price_Increase_Enabled__c = true,
      Recurring_Increase_Start_Date__c = Date.newInstance(2026, 10, 1),
      Recurring_Increase_Frequency_Months__c = 1,
      Recurring_Increase_Type__c = 'Increase_by_Percentage',
      Recurring_Increase_Percent__c = 5
    );
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
      request
    );
    request.currentStateExpectation = preview.currentStateExpectation;

    MonthlyPaymentAdjustmentService.applyIndividualPercentage(request);

    MonthlyPayment__c saved = [
      SELECT Discount__c, Final_Adjusted_Price__c, User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Assert.isTrue(preview.recurringPricingActive);
    Assert.areEqual(10, saved.Discount__c);
    Assert.areEqual(
      1100,
      saved.Final_Adjusted_Price__c,
      'Replace must not re-stack the active recurring increase.'
    );
    Assert.areEqual(
      10,
      saved.User_Price_Adjustment__c,
      'The existing Task 2 bookkeeping hook remains authoritative.'
    );
  }

  @isTest
  static void amountReplaceAndAddUseOriginalAndCurrentFinal() {
    MonthlyPayment__c replacePayment = createOpportunityPayment();
    MonthlyPayment__c addPayment = createOpportunityPayment();
    update new List<MonthlyPayment__c>{
      new MonthlyPayment__c(
        Id = replacePayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      ),
      new MonthlyPayment__c(
        Id = addPayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      )
    };

    MonthlyPaymentAdjustmentService.AdjustmentRequest replaceRequest = adjustedAmountRequest(
      replacePayment.Id,
      100,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult replacePreview = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
      replaceRequest
    );
    replaceRequest.currentStateExpectation = replacePreview.currentStateExpectation;
    MonthlyPaymentAdjustmentService.AdjustmentResult replaced = MonthlyPaymentAdjustmentService.applyIndividualAdjustment(
      replaceRequest
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest addRequest = adjustedAmountRequest(
      addPayment.Id,
      100,
      MonthlyPaymentAdjustmentService.ACTION_ADD
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult addPreview = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
      addRequest
    );
    addRequest.currentStateExpectation = addPreview.currentStateExpectation;
    MonthlyPaymentAdjustmentService.AdjustmentResult added = MonthlyPaymentAdjustmentService.applyIndividualAdjustment(
      addRequest
    );

    Assert.areEqual(50, replacePreview.calculatedOutcome.existingAdjustment);
    Assert.areEqual(100, replacePreview.calculatedOutcome.resultingAdjustment);
    Assert.areEqual(1100, replaced.calculatedOutcome.finalPriceAfter);
    Assert.areEqual(50, addPreview.calculatedOutcome.existingAdjustment);
    Assert.areEqual(150, addPreview.calculatedOutcome.resultingAdjustment);
    Assert.areEqual(1150, added.calculatedOutcome.finalPriceAfter);

    Map<Id, Monthly_Payment_Adjustment_History__c> historyByPayment = new Map<Id, Monthly_Payment_Adjustment_History__c>();
    for (Monthly_Payment_Adjustment_History__c history : [
      SELECT
        Monthly_Payment__c,
        Adjustment_Type__c,
        Action__c,
        Existing_Adjustment__c,
        Entered_Adjustment__c,
        Resulting_Adjustment__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE
        Monthly_Payment__c IN :new Set<Id>{ replacePayment.Id, addPayment.Id }
    ]) {
      historyByPayment.put(history.Monthly_Payment__c, history);
    }
    Assert.areEqual(
      'Amount',
      historyByPayment.get(replacePayment.Id).Adjustment_Type__c
    );
    Assert.areEqual(
      'Replace',
      historyByPayment.get(replacePayment.Id).Action__c
    );
    Assert.areEqual(
      100,
      historyByPayment.get(replacePayment.Id).Resulting_Adjustment__c
    );
    Assert.areEqual('Add', historyByPayment.get(addPayment.Id).Action__c);
    Assert.areEqual(
      150,
      historyByPayment.get(addPayment.Id).Resulting_Adjustment__c
    );
  }

  @isTest
  static void amountSetAndNegativeAmountWriteAmountHistory() {
    MonthlyPayment__c setPayment = createOpportunityPayment();
    MonthlyPayment__c negativePayment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = negativePayment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest setRequest = adjustedAmountRequest(
      setPayment.Id,
      100,
      MonthlyPaymentAdjustmentService.ACTION_SET
    );
    MonthlyPaymentAdjustmentService.applyIndividualAdjustment(setRequest);

    MonthlyPaymentAdjustmentService.AdjustmentRequest negativeRequest = adjustedAmountRequest(
      negativePayment.Id,
      -1200,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    negativeRequest.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
        negativeRequest
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualAdjustment(negativeRequest);

    Map<Id, MonthlyPayment__c> savedById = new Map<Id, MonthlyPayment__c>(
      [
        SELECT Id, Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id IN :new Set<Id>{ setPayment.Id, negativePayment.Id }
      ]
    );
    Assert.areEqual(1100, savedById.get(setPayment.Id).Final_Adjusted_Price__c);
    Assert.areEqual(
      -200,
      savedById.get(negativePayment.Id).Final_Adjusted_Price__c
    );
    List<Monthly_Payment_Adjustment_History__c> histories = [
      SELECT Adjustment_Type__c, Action__c, Entered_Adjustment__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE
        Monthly_Payment__c IN :new Set<Id>{ setPayment.Id, negativePayment.Id }
    ];
    Assert.areEqual(2, histories.size());
    for (Monthly_Payment_Adjustment_History__c history : histories) {
      Assert.areEqual('Amount', history.Adjustment_Type__c);
    }
  }

  @isTest
  static void amountAddZeroIsNoOpAndStaleAmountPreviewIsRejected() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest addZero = adjustedAmountRequest(
      payment.Id,
      0,
      MonthlyPaymentAdjustmentService.ACTION_ADD
    );
    addZero.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
        addZero
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualAdjustment(addZero);
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest stale = adjustedAmountRequest(
      payment.Id,
      25,
      MonthlyPaymentAdjustmentService.ACTION_ADD
    );
    stale.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
        stale
      )
      .currentStateExpectation;
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 7,
      Final_Adjusted_Price__c = 1070
    );
    Boolean rejected = false;
    try {
      MonthlyPaymentAdjustmentService.applyIndividualAdjustment(stale);
    } catch (AuraHandledException expected) {
      rejected = true;
    }
    Assert.isTrue(rejected, 'A stale amount preview must be rejected.');
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void amountSetZeroIsNoOpAndReplaceZeroResetsToOriginal() {
    MonthlyPayment__c cleanPayment = createOpportunityPayment();
    MonthlyPaymentAdjustmentService.applyIndividualAdjustment(
      adjustedAmountRequest(
        cleanPayment.Id,
        0,
        MonthlyPaymentAdjustmentService.ACTION_SET
      )
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :cleanPayment.Id
      ],
      'Amount Set zero must not create history.'
    );

    MonthlyPayment__c adjustedPayment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = adjustedPayment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPaymentAdjustmentService.AdjustmentRequest replaceZero = adjustedAmountRequest(
      adjustedPayment.Id,
      0,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    replaceZero.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
        replaceZero
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualAdjustment(replaceZero);

    Monthly_Payment_Adjustment_History__c history = [
      SELECT
        Adjustment_Type__c,
        Action__c,
        Existing_Adjustment__c,
        Entered_Adjustment__c,
        Resulting_Adjustment__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :adjustedPayment.Id
    ];
    Assert.areEqual('Amount', history.Adjustment_Type__c);
    Assert.areEqual('Replace', history.Action__c);
    Assert.areEqual(50, history.Existing_Adjustment__c);
    Assert.areEqual(0, history.Entered_Adjustment__c);
    Assert.areEqual(0, history.Resulting_Adjustment__c);
    Assert.areEqual(1000, history.Price_After__c);
  }

  @isTest
  static void directFinalSaveCreatesNoTaskThreeHistory() {
    MonthlyPayment__c payment = createOpportunityPayment();

    PackageBuilderService.updateDiscountWithEnteredPercentages(
      new List<MonthlyPayment__c>{
        new MonthlyPayment__c(Id = payment.Id, Final_Adjusted_Price__c = 1125)
      },
      new Map<Id, Decimal>()
    );

    Assert.areEqual(
      1125,
      [
        SELECT Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id = :payment.Id
      ]
      .Final_Adjusted_Price__c
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void amountPreviewWorksForOrderPayment() {
    MonthlyPayment__c payment = createSplitOrderPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = payment.Price__c * 1.05
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
      adjustedAmountRequest(
        payment.Id,
        75,
        MonthlyPaymentAdjustmentService.ACTION_REPLACE
      )
    );
    Assert.areEqual(
      payment.Price__c + 75,
      preview.calculatedOutcome.finalPriceAfter
    );
    Assert.areEqual(75, preview.calculatedOutcome.resultingAdjustment);
  }

  private static MonthlyPaymentAdjustmentService.AdjustmentRequest adjustedPercentageRequest(
    Id paymentId,
    Decimal inputValue,
    String action
  ) {
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    request.paymentId = paymentId;
    request.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    request.inputValue = inputValue;
    request.action = action;
    return request;
  }

  private static MonthlyPaymentAdjustmentService.AdjustmentRequest adjustedAmountRequest(
    Id paymentId,
    Decimal inputValue,
    String action
  ) {
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    request.paymentId = paymentId;
    request.inputType = MonthlyPaymentAdjustmentService.INPUT_AMOUNT;
    request.inputValue = inputValue;
    request.action = action;
    return request;
  }

  @isTest
  static void bulkMixedSetAndReplacePercentageIsAtomic() {
    MonthlyPayment__c cleanPayment = createOpportunityPayment();
    MonthlyPayment__c adjustedPayment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = adjustedPayment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    Map<Id, MonthlyPayment__c> loaded = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c,
          LastModifiedDate
        FROM MonthlyPayment__c
        WHERE Id IN :new Set<Id>{ cleanPayment.Id, adjustedPayment.Id }
      ]
    );

    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest bulkRequest = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    bulkRequest.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    bulkRequest.inputValue = 10;
    bulkRequest.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    bulkRequest.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(cleanPayment.Id, loaded.get(cleanPayment.Id)),
      bulkItem(adjustedPayment.Id, loaded.get(adjustedPayment.Id))
    };

    Test.startTest();
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(bulkRequest);
    Test.stopTest();

    Map<Id, MonthlyPayment__c> saved = new Map<Id, MonthlyPayment__c>(
      [
        SELECT Discount__c, Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id IN :new Set<Id>{ cleanPayment.Id, adjustedPayment.Id }
      ]
    );
    Map<Id, Monthly_Payment_Adjustment_History__c> historyByPayment = new Map<Id, Monthly_Payment_Adjustment_History__c>();
    for (Monthly_Payment_Adjustment_History__c history : [
      SELECT
        Monthly_Payment__c,
        Action__c,
        Entered_Adjustment__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE
        Monthly_Payment__c IN :new Set<Id>{
          cleanPayment.Id,
          adjustedPayment.Id
        }
    ]) {
      historyByPayment.put(history.Monthly_Payment__c, history);
    }

    Assert.areEqual(10, saved.get(cleanPayment.Id).Discount__c);
    Assert.areEqual(1100, saved.get(cleanPayment.Id).Final_Adjusted_Price__c);
    Assert.areEqual('Set', historyByPayment.get(cleanPayment.Id).Action__c);
    Assert.areEqual(10, saved.get(adjustedPayment.Id).Discount__c);
    Assert.areEqual(
      1100,
      saved.get(adjustedPayment.Id).Final_Adjusted_Price__c
    );
    Assert.areEqual(
      'Replace',
      historyByPayment.get(adjustedPayment.Id).Action__c
    );
    Assert.areEqual(2, historyByPayment.size());
  }

  @isTest
  static void bulkAddPercentageCompoundsEachMonthIndependently() {
    MonthlyPayment__c firstPayment = createOpportunityPayment();
    MonthlyPayment__c secondPayment = createOpportunityPayment();
    update new List<MonthlyPayment__c>{
      new MonthlyPayment__c(
        Id = firstPayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      ),
      new MonthlyPayment__c(
        Id = secondPayment.Id,
        Discount__c = 10,
        Final_Adjusted_Price__c = 1100
      )
    };
    Map<Id, MonthlyPayment__c> loaded = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c,
          LastModifiedDate
        FROM MonthlyPayment__c
        WHERE Id IN :new Set<Id>{ firstPayment.Id, secondPayment.Id }
      ]
    );
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest bulkRequest = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    bulkRequest.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    bulkRequest.inputValue = 10;
    bulkRequest.action = MonthlyPaymentAdjustmentService.ACTION_ADD;
    bulkRequest.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(firstPayment.Id, loaded.get(firstPayment.Id)),
      bulkItem(secondPayment.Id, loaded.get(secondPayment.Id))
    };

    Test.startTest();
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(bulkRequest);
    Test.stopTest();

    Map<Id, MonthlyPayment__c> saved = new Map<Id, MonthlyPayment__c>(
      [
        SELECT Discount__c, Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id IN :new Set<Id>{ firstPayment.Id, secondPayment.Id }
      ]
    );
    Assert.areEqual(15.5, saved.get(firstPayment.Id).Discount__c);
    Assert.areEqual(1155, saved.get(firstPayment.Id).Final_Adjusted_Price__c);
    Assert.areEqual(21, saved.get(secondPayment.Id).Discount__c);
    Assert.areEqual(1210, saved.get(secondPayment.Id).Final_Adjusted_Price__c);
  }

  @isTest
  static void bulkAmountReplaceAndAddWriteAmountHistory() {
    MonthlyPayment__c replacePayment = createOpportunityPayment();
    MonthlyPayment__c addPayment = createOpportunityPayment();
    update new List<MonthlyPayment__c>{
      new MonthlyPayment__c(
        Id = replacePayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      ),
      new MonthlyPayment__c(
        Id = addPayment.Id,
        Discount__c = 5,
        Final_Adjusted_Price__c = 1050
      )
    };
    Map<Id, MonthlyPayment__c> replaceLoaded = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c,
          LastModifiedDate
        FROM MonthlyPayment__c
        WHERE Id = :replacePayment.Id
      ]
    );
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest replaceBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    replaceBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_AMOUNT;
    replaceBulk.inputValue = 100;
    replaceBulk.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    replaceBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(replacePayment.Id, replaceLoaded.get(replacePayment.Id))
    };
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(replaceBulk);

    Map<Id, MonthlyPayment__c> addLoaded = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c,
          LastModifiedDate
        FROM MonthlyPayment__c
        WHERE Id = :addPayment.Id
      ]
    );
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest addBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    addBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_AMOUNT;
    addBulk.inputValue = 100;
    addBulk.action = MonthlyPaymentAdjustmentService.ACTION_ADD;
    addBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(addPayment.Id, addLoaded.get(addPayment.Id))
    };
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(addBulk);

    Map<Id, Monthly_Payment_Adjustment_History__c> historyByPayment = new Map<Id, Monthly_Payment_Adjustment_History__c>();
    for (Monthly_Payment_Adjustment_History__c history : [
      SELECT
        Monthly_Payment__c,
        Adjustment_Type__c,
        Action__c,
        Resulting_Adjustment__c,
        Price_After__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE
        Monthly_Payment__c IN :new Set<Id>{ replacePayment.Id, addPayment.Id }
    ]) {
      historyByPayment.put(history.Monthly_Payment__c, history);
    }
    Assert.areEqual(
      'Amount',
      historyByPayment.get(replacePayment.Id).Adjustment_Type__c
    );
    Assert.areEqual(
      'Replace',
      historyByPayment.get(replacePayment.Id).Action__c
    );
    Assert.areEqual(
      100,
      historyByPayment.get(replacePayment.Id).Resulting_Adjustment__c
    );
    Assert.areEqual('Add', historyByPayment.get(addPayment.Id).Action__c);
    Assert.areEqual(
      150,
      historyByPayment.get(addPayment.Id).Resulting_Adjustment__c
    );
    Assert.areEqual(
      1100,
      historyByPayment.get(replacePayment.Id).Price_After__c
    );
    Assert.areEqual(1150, historyByPayment.get(addPayment.Id).Price_After__c);
  }

  @isTest
  static void bulkAddZeroSkipsHistoryAndStaleRowRejectsAll() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPayment__c loaded = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c,
        LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest addZeroBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    addZeroBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    addZeroBulk.inputValue = 0;
    addZeroBulk.action = MonthlyPaymentAdjustmentService.ACTION_ADD;
    addZeroBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(payment.Id, loaded)
    };
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(addZeroBulk);
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );

    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest staleBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    staleBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    staleBulk.inputValue = 10;
    staleBulk.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    staleBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(payment.Id, loaded)
    };
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 7,
      Final_Adjusted_Price__c = 1070
    );
    Boolean rejected = false;
    try {
      MonthlyPaymentAdjustmentService.applyBulkAdjustment(staleBulk);
    } catch (AuraHandledException expected) {
      rejected = true;
    }
    Assert.isTrue(
      rejected,
      'A stale bulk row must reject the whole operation.'
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :payment.Id
      ]
    );
  }

  @isTest
  static void bulkStaleAuraMessageIsNotMaskedAsScriptThrown() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050
    );
    MonthlyPayment__c loaded = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c,
        LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest staleBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    staleBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    staleBulk.inputValue = 10;
    staleBulk.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    staleBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(payment.Id, loaded)
    };
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 7,
      Final_Adjusted_Price__c = 1070
    );

    String failureMessage;
    try {
      MonthlyPaymentAdjustmentService.applyBulkAdjustment(staleBulk);
    } catch (AuraHandledException expected) {
      failureMessage = expected.getMessage();
    }
    Assert.isNotNull(
      failureMessage,
      'Stale bulk must throw AuraHandledException.'
    );
    Assert.isFalse(
      failureMessage.contains('Script-thrown exception'),
      'Bulk catch must not mask AuraHandledException as Script-thrown exception.'
    );
    Assert.isFalse(
      failureMessage.startsWith('Nothing was saved.'),
      'Known AuraHandledException must be rethrown without the generic wrap prefix.'
    );
    Assert.isTrue(
      failureMessage.contains(
        System.Label.MonthlyPayment_Adjustment_BulkStaleError
      ) ||
      failureMessage == System.Label.MonthlyPayment_Adjustment_BulkStaleError,
      'Client-facing message must preserve the bulk stale label text.'
    );
  }

  @isTest
  static void bulkAcceptsUiRoundedFinalExpectation() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 2.999979,
      Final_Adjusted_Price__c = 0
    );
    MonthlyPayment__c loaded = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c,
        LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
    Decimal payable = PackageBuilderService.payableAmountForMonthlyPayment(
      loaded
    );
    Decimal uiRounded = payable.setScale(2, System.RoundingMode.HALF_UP);
    Assert.areNotEqual(
      payable,
      uiRounded,
      'Fixture must produce payable precision beyond UI 2dp FinalPrice.'
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest item = bulkItem(
      payment.Id,
      loaded
    );
    item.currentStateExpectation.finalPrice = uiRounded;

    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest bulkRequest = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    bulkRequest.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    bulkRequest.inputValue = 3;
    bulkRequest.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    bulkRequest.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      item
    };

    Test.startTest();
    MonthlyPaymentAdjustmentService.applyBulkAdjustment(bulkRequest);
    Test.stopTest();

    Assert.areEqual(
      3,
      [
        SELECT Discount__c
        FROM MonthlyPayment__c
        WHERE Id = :payment.Id
      ]
      .Discount__c
    );
  }

  @isTest
  static void bulkPersistFailureRollsBackEveryPaymentAndHistory() {
    MonthlyPayment__c validPayment = createOpportunityPayment();
    MonthlyPayment__c loaded = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c,
        LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :validPayment.Id
    ];
    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest bulkRequest = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    bulkRequest.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    bulkRequest.inputValue = 10;
    bulkRequest.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    bulkRequest.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(validPayment.Id, loaded),
      bulkItem(fakePaymentId('8'), loaded)
    };
    Boolean threw = false;
    Boolean auraHandled = false;
    try {
      MonthlyPaymentAdjustmentService.applyBulkAdjustment(bulkRequest);
    } catch (Exception caught) {
      threw = true;
      auraHandled = caught instanceof AuraHandledException;
    }
    Assert.isTrue(threw, 'Bulk apply must fail atomically.');
    Assert.isTrue(
      auraHandled,
      'Bulk failure must surface as AuraHandledException to the UI.'
    );
    Assert.areEqual(
      0,
      [
        SELECT Discount__c
        FROM MonthlyPayment__c
        WHERE Id = :validPayment.Id
      ]
      .Discount__c
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :validPayment.Id
      ]
    );
  }

  @isTest
  static void userPriceAdjustmentIsNotTaskThreeCalculationSource() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 5,
      Final_Adjusted_Price__c = 1050,
      User_Price_Adjustment__c = 99
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest request = adjustedPercentageRequest(
      payment.Id,
      10,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
      request
    );

    Assert.areEqual(
      5,
      preview.calculatedOutcome.existingAdjustment,
      'Task 3 must read effective Discount__c, not User_Price_Adjustment__c.'
    );
    Assert.areEqual(1050, preview.calculatedOutcome.priceBefore);
    Assert.areEqual(1100, preview.calculatedOutcome.finalPriceAfter);
  }

  @isTest
  static void rpiEnableAndApplyCreatesNoTaskThreeHistory() {
    OrderMonthlyContext context = createOrderMonthlyLine();
    Date today = Date.today();

    Test.startTest();
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ context.orderItemId },
      rpiPercentDraft(1, today, 10),
      false
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :context.paymentId
      ],
      'Task 2 recurring apply must not write Task 3 history.'
    );
  }

  @isTest
  static void taskThreeAdjustmentDoesNotBlockTaskTwoReapplyOrCreateHistory() {
    OrderMonthlyContext context = createOrderMonthlyLine();
    Date today = Date.today();
    RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ context.orderItemId },
      rpiPercentDraft(1, today, 10),
      false
    );

    MonthlyPaymentAdjustmentService.AdjustmentRequest replaceRequest = adjustedPercentageRequest(
      context.paymentId,
      20,
      MonthlyPaymentAdjustmentService.ACTION_REPLACE
    );
    replaceRequest.currentStateExpectation = MonthlyPaymentAdjustmentService.previewIndividualPercentage(
        replaceRequest
      )
      .currentStateExpectation;
    MonthlyPaymentAdjustmentService.applyIndividualPercentage(replaceRequest);

    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :context.paymentId
      ]
    );

    RecurringPriceIncreaseService.RuleDraft draft = rpiPercentDraft(
      1,
      today,
      10
    );

    Test.startTest();
    RecurringPriceIncreaseService.saveRuleFields(
      new List<Id>{ context.orderItemId },
      draft,
      false
    );
    RecurringPriceIncreaseService.SaveResult applyAgain = RecurringPriceIncreaseService.enableAndApplyRules(
      new List<Id>{ context.orderItemId },
      draft,
      false
    );
    Test.stopTest();

    Assert.isTrue(
      applyAgain.updatedLines >= 1,
      'Task 2 rule save/re-apply must remain available after a Task 3 adjustment.'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Monthly_Payment_Adjustment_History__c
        WHERE Monthly_Payment__c = :context.paymentId
      ],
      'Task 2 re-apply must not create Task 3 history rows.'
    );
    Assert.areEqual(
      1200,
      [
        SELECT Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE Id = :context.paymentId
      ]
      .Final_Adjusted_Price__c,
      'Task 3-adjusted Final remains until Task 2 rebuild changes it in org-specific date windows.'
    );
  }

  @isTest
  static void subOnePercentUsesPercentPointsForPreviewHistoryAndStale() {
    MonthlyPayment__c payment = createOpportunityPayment();
    update new MonthlyPayment__c(
      Id = payment.Id,
      Discount__c = 0.005,
      Final_Adjusted_Price__c = 1005
    );
    MonthlyPayment__c loaded = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c,
        LastModifiedDate
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];

    MonthlyPaymentAdjustmentService.AdjustmentRequest request = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    request.paymentId = payment.Id;
    request.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    request.inputValue = 10;
    request.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;

    MonthlyPaymentAdjustmentService.AdjustmentResult preview = MonthlyPaymentAdjustmentService.previewIndividualAdjustment(
      request
    );
    Assert.areEqual(
      0.5,
      preview.calculatedOutcome.existingAdjustment,
      'Sub-1% stored Discount must preview as percent points.'
    );
    Assert.areEqual(
      0.5,
      preview.currentStateExpectation.discount,
      'Stale expectation discount must use percent points.'
    );

    request.currentStateExpectation = preview.currentStateExpectation;
    MonthlyPaymentAdjustmentService.AdjustmentResult applied = MonthlyPaymentAdjustmentService.applyIndividualAdjustment(
      request
    );
    Assert.areEqual(10, applied.calculatedOutcome.resultingAdjustment);

    Monthly_Payment_Adjustment_History__c history = [
      SELECT Existing_Adjustment__c, Resulting_Adjustment__c
      FROM Monthly_Payment_Adjustment_History__c
      WHERE Monthly_Payment__c = :payment.Id
      LIMIT 1
    ];
    Assert.areEqual(0.5, history.Existing_Adjustment__c);
    Assert.areEqual(10, history.Resulting_Adjustment__c);

    MonthlyPaymentAdjustmentService.BulkAdjustmentRequest staleBulk = new MonthlyPaymentAdjustmentService.BulkAdjustmentRequest();
    staleBulk.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    staleBulk.inputValue = 12;
    staleBulk.action = MonthlyPaymentAdjustmentService.ACTION_REPLACE;
    staleBulk.items = new List<MonthlyPaymentAdjustmentService.AdjustmentRequest>{
      bulkItem(payment.Id, loaded)
    };
    Boolean rejected = false;
    try {
      MonthlyPaymentAdjustmentService.applyBulkAdjustment(staleBulk);
    } catch (AuraHandledException expected) {
      rejected = true;
    }
    Assert.isTrue(
      rejected,
      'Percent-point expectation for a changed sub-1% row must still detect staleness.'
    );
  }
  private static MonthlyPaymentAdjustmentService.AdjustmentRequest bulkItem(
    Id paymentId,
    MonthlyPayment__c payment
  ) {
    MonthlyPaymentAdjustmentService.AdjustmentRequest item = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    item.paymentId = paymentId;
    item.currentStateExpectation = new MonthlyPaymentAdjustmentService.CurrentStateExpectation();
    item.currentStateExpectation.discount = Math.abs(
        valueOrZero(payment.Discount__c)
      ) < 1
      ? valueOrZero(payment.Discount__c) * 100
      : valueOrZero(payment.Discount__c);
    item.currentStateExpectation.finalPrice = PackageBuilderService.payableAmountForMonthlyPayment(
      payment
    );
    item.currentStateExpectation.lastModifiedDate = payment.LastModifiedDate;
    return item;
  }

  private static Decimal valueOrZero(Decimal value) {
    return value == null ? 0 : value;
  }

  private static MonthlyPaymentAdjustmentService.AdjustmentRequest percentageSetRequest(
    Id paymentId,
    Decimal inputValue
  ) {
    MonthlyPaymentAdjustmentService.AdjustmentRequest request = new MonthlyPaymentAdjustmentService.AdjustmentRequest();
    request.paymentId = paymentId;
    request.inputType = MonthlyPaymentAdjustmentService.INPUT_PERCENTAGE;
    request.inputValue = inputValue;
    request.action = MonthlyPaymentAdjustmentService.ACTION_SET;
    request.currentStateExpectation = new MonthlyPaymentAdjustmentService.CurrentStateExpectation();
    return request;
  }

  private class OrderMonthlyContext {
    Id orderItemId;
    Id paymentId;
  }

  private static RecurringPriceIncreaseService.RuleDraft rpiPercentDraft(
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

  private static OrderMonthlyContext createOrderMonthlyLine() {
    TestData data = createBaseData();
    Account account = new Account(Name = 'RPI Coexistence Account');
    insert account;
    Contract contractRecord = new Contract(
      AccountId = account.Id,
      Status = 'Draft',
      StartDate = Date.today().toStartOfMonth(),
      EndDate = Date.today().addMonths(14)
    );
    insert contractRecord;
    Order orderRecord = new Order(
      AccountId = account.Id,
      Status = 'Draft',
      EffectiveDate = Date.today().toStartOfMonth(),
      Order_Start_Date__c = Date.today().toStartOfMonth(),
      EndDate = Date.today().addMonths(14),
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = data.location.Id,
      OpportunityId = data.opportunity.Id,
      ContractId = contractRecord.Id
    );
    insert orderRecord;
    OrderItem lineItem = new OrderItem(
      OrderId = orderRecord.Id,
      PricebookEntryId = data.pricebookEntry.Id,
      Access_Type__c = 'Monthly',
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.today().toStartOfMonth(),
      EndDate = Date.today().addMonths(14),
      Contract__c = contractRecord.Id
    );
    insert lineItem;
    prepareOrderItemServiceWindowForCoexistence(
      lineItem.Id,
      Date.today().toStartOfMonth(),
      Date.today().addMonths(14),
      'Monthly'
    );
    List<MonthlyPayment__c> payments = insertOrderMonthsByIndex(
      lineItem.Id,
      new List<Integer>{ 1 },
      0
    );
    OrderMonthlyContext context = new OrderMonthlyContext();
    context.orderItemId = lineItem.Id;
    context.paymentId = payments[0].Id;
    return context;
  }

  private static void prepareOrderItemServiceWindowForCoexistence(
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

  private static List<MonthlyPayment__c> insertOrderMonthsByIndex(
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
      SELECT Id, MonthIndex__c, Discount__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :orderItemId
      ORDER BY MonthIndex__c ASC
    ];
  }

  private static MonthlyPayment__c createOpportunityPayment() {
    TestData data = createBaseData();
    OpportunityLineItem lineItem = new OpportunityLineItem(
      OpportunityId = data.opportunity.Id,
      PricebookEntryId = data.pricebookEntry.Id,
      Access_Type__c = 'Periodic',
      Quantity = 1,
      TotalPrice = 1000,
      Entry_Date__c = Date.newInstance(2026, 10, 1),
      End_Date__c = Date.newInstance(2026, 10, 31)
    );
    insert lineItem;
    MonthlyPayment__c payment = new MonthlyPayment__c(
      OpportunityLineItem__c = lineItem.Id,
      Opportunity__c = data.opportunity.Id,
      Room__c = data.product.Id,
      Location__c = data.location.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.newInstance(2026, 10, 1),
      End_Date_trigger__c = Date.newInstance(2026, 10, 31)
    );
    insert payment;
    return [
      SELECT Id, Price__c, Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
  }

  private static MonthlyPayment__c createSplitOrderPayment() {
    TestData data = createBaseData();
    Account account = new Account(Name = 'Adjustment Test Account');
    insert account;
    Contract contractRecord = new Contract(
      AccountId = account.Id,
      Status = 'Draft',
      StartDate = Date.newInstance(2026, 4, 1),
      EndDate = Date.newInstance(2027, 4, 14)
    );
    insert contractRecord;
    Order orderRecord = new Order(
      AccountId = account.Id,
      Status = 'Draft',
      EffectiveDate = Date.newInstance(2026, 4, 1),
      Order_Start_Date__c = Date.newInstance(2026, 4, 1),
      EndDate = Date.newInstance(2027, 4, 14),
      Pricebook2Id = Test.getStandardPricebookId(),
      Location__c = data.location.Id,
      OpportunityId = data.opportunity.Id,
      ContractId = contractRecord.Id
    );
    insert orderRecord;
    OrderItem lineItem = new OrderItem(
      OrderId = orderRecord.Id,
      PricebookEntryId = data.pricebookEntry.Id,
      Access_Type__c = 'Periodic',
      Quantity = 1,
      UnitPrice = 1000,
      ServiceDate = Date.newInstance(2026, 4, 1),
      EndDate = Date.newInstance(2026, 4, 30),
      Contract__c = contractRecord.Id
    );
    insert lineItem;
    orderRecord.Order_Start_Date__c = Date.newInstance(2026, 4, 15);
    update orderRecord;
    MonthlyPayment__c payment = new MonthlyPayment__c(
      OrderItem__c = lineItem.Id,
      Room__c = data.product.Id,
      Location__c = data.location.Id,
      Opportunity__c = data.opportunity.Id,
      Contract__c = contractRecord.Id,
      MonthIndex__c = 1,
      Discount__c = 0,
      Stat_Date_Trigger__c = Date.newInstance(2026, 4, 1),
      End_Date_trigger__c = Date.newInstance(2026, 4, 30)
    );
    insert payment;
    return [
      SELECT Id, Price__c, Discount__c
      FROM MonthlyPayment__c
      WHERE Id = :payment.Id
    ];
  }

  private static TestData createBaseData() {
    bypassHeavyAutomation();
    TestData data = new TestData();
    data.location = new Locations__c(
      Name = 'Adjustment Test Location',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Adjustment Test Site',
      Address__c = '1 Test Street'
    );
    insert data.location;
    data.product = new Product2(
      Name = 'Adjustment Test Product',
      IsActive = true,
      Location__c = data.location.Id
    );
    insert data.product;
    data.pricebookEntry = new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = data.product.Id,
      UnitPrice = 1000,
      IsActive = true
    );
    insert data.pricebookEntry;
    data.opportunity = new Opportunity(
      Name = 'Adjustment Test Opportunity',
      CloseDate = Date.newInstance(2026, 12, 31),
      StageName = 'New',
      Location__c = data.location.Id,
      Pricebook2Id = Test.getStandardPricebookId()
    );
    insert data.opportunity;
    return data;
  }

  private static void bypassHeavyAutomation() {
    TriggerHandler.clearAllBypasses();
    TriggerHandler.bypass('OrderItemTriggerHandler');
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    TriggerHandler.bypass('OrderTriggerHandler');
    TriggerHandler.bypass('OpportunityTriggerHandler');
    OrderTriggerHandler.orderTriggerHandlerEnabledOverride = false;
    TriggerStopper.stopOppLine = true;
    TriggerStopper.stopOpp = true;
  }

  private class TestData {
    Locations__c location;
    Product2 product;
    PricebookEntry pricebookEntry;
    Opportunity opportunity;
  }

  private static Id fakePaymentId(String suffix) {
    String prefix = MonthlyPayment__c.SObjectType.getDescribe().getKeyPrefix();
    return (Id) (prefix + '00000000000' + suffix);
  }
}
