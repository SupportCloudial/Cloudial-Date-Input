/**
 * Typed domain seam for user-driven Monthly Payment adjustments.
 *
 * Owns server-authoritative Set/Replace/Add calculations and history.
 * Individual and bulk user adjustments share the same calculation path.
 */
public without sharing class MonthlyPaymentAdjustmentService {
  public static final String INPUT_PERCENTAGE = 'Percentage';
  public static final String INPUT_AMOUNT = 'Amount';
  public static final String INPUT_FINAL = 'Final';

  public static final String ACTION_SET = 'Set';
  public static final String ACTION_REPLACE = 'Replace';
  public static final String ACTION_ADD = 'Add';

  @TestVisible
  private static Integer applyInvocationCount = 0;

  public class CurrentStateExpectation {
    @AuraEnabled
    public Decimal discount { get; set; }
    @AuraEnabled
    public Decimal finalPrice { get; set; }
    @AuraEnabled
    public Datetime lastModifiedDate { get; set; }
  }

  public class AdjustmentRequest {
    @AuraEnabled
    public Id paymentId { get; set; }
    @AuraEnabled
    public String inputType { get; set; }
    @AuraEnabled
    public Decimal inputValue { get; set; }
    @AuraEnabled
    public String action { get; set; }
    @AuraEnabled
    public CurrentStateExpectation currentStateExpectation { get; set; }

    /*
     * Compatibility payload for the established Package Builder calculation
     * path. Keeping it inside the request preserves split-month weighting,
     * explicit Final handling, Usage Based null/zero semantics, and Task 2
     * bookkeeping while callers migrate to the typed fields above.
     */
    public MonthlyPayment__c paymentUpdate;
  }

  public class CalculatedOutcome {
    @AuraEnabled
    public Decimal originalPrice { get; set; }
    @AuraEnabled
    public Decimal existingAdjustment { get; set; }
    @AuraEnabled
    public Decimal priceBefore { get; set; }
    @AuraEnabled
    public Decimal resultingAdjustment { get; set; }
    @AuraEnabled
    public Decimal finalPriceAfter { get; set; }
  }

  public class BulkAdjustmentRequest {
    @AuraEnabled
    public String inputType { get; set; }
    @AuraEnabled
    public Decimal inputValue { get; set; }
    @AuraEnabled
    public String action { get; set; }
    @AuraEnabled
    public List<AdjustmentRequest> items { get; set; }
  }

  public class AdjustmentResult {
    @AuraEnabled
    public Id paymentId { get; set; }
    @AuraEnabled
    public String inputType { get; set; }
    @AuraEnabled
    public Decimal inputValue { get; set; }
    @AuraEnabled
    public String action { get; set; }
    @AuraEnabled
    public CalculatedOutcome calculatedOutcome { get; set; }
    @AuraEnabled
    public CurrentStateExpectation currentStateExpectation { get; set; }
    @AuraEnabled
    public Boolean recurringPricingActive { get; set; }
  }

  @AuraEnabled
  public static AdjustmentResult previewIndividualPercentage(
    AdjustmentRequest request
  ) {
    return previewIndividualAdjustment(request);
  }

  @AuraEnabled
  public static AdjustmentResult previewIndividualAdjustment(
    AdjustmentRequest request
  ) {
    validateAdjustedIndividualRequest(request);
    MonthlyPayment__c payment = loadOutcomeState(
        new Set<Id>{ request.paymentId }
      )
      .get(request.paymentId);
    if (payment == null) {
      throw new AuraHandledException('Monthly Payment no longer exists.');
    }
    assertExistingEffectiveAdjustment(payment);
    return calculateIndividualAdjustment(request, payment);
  }

  @AuraEnabled
  public static AdjustmentResult applyIndividualPercentage(
    AdjustmentRequest request
  ) {
    return applyIndividualAdjustment(request);
  }

  @AuraEnabled
  public static List<AdjustmentResult> applyBulkAdjustment(
    BulkAdjustmentRequest bulkRequest
  ) {
    validateBulkApplyRequest(bulkRequest);
    Map<Id, AdjustmentRequest> itemByPaymentId = new Map<Id, AdjustmentRequest>();
    for (AdjustmentRequest item : bulkRequest.items) {
      itemByPaymentId.put(item.paymentId, item);
    }

    Savepoint adjustmentSavepoint = Database.setSavepoint();
    try {
      Map<Id, MonthlyPayment__c> beforeById = loadOutcomeState(
        itemByPaymentId.keySet()
      );

      List<MonthlyPayment__c> updates = new List<MonthlyPayment__c>();
      List<AdjustmentRequest> appliedRequests = new List<AdjustmentRequest>();
      List<CalculatedOutcome> appliedOutcomes = new List<CalculatedOutcome>();
      for (AdjustmentRequest item : bulkRequest.items) {
        MonthlyPayment__c beforePayment = beforeById.get(item.paymentId);
        if (beforePayment == null) {
          throw new AuraHandledException('Monthly Payment no longer exists.');
        }
        if (item.currentStateExpectation == null) {
          throw new AuraHandledException(bulkStaleMessage());
        }
        assertBulkCurrentState(item.currentStateExpectation, beforePayment);

        AdjustmentRequest calcRequest = bulkCalculationRequest(
          item.paymentId,
          bulkRequest,
          beforePayment
        );
        if (isBulkNoOp(calcRequest, beforePayment)) {
          continue;
        }
        AdjustmentResult preview = calculateIndividualAdjustment(
          calcRequest,
          beforePayment
        );
        updates.add(
          adjustmentUpdateForOutcome(beforePayment, preview.calculatedOutcome)
        );
        appliedRequests.add(calcRequest);
        appliedOutcomes.add(preview.calculatedOutcome);
      }

      if (!updates.isEmpty()) {
        PackageBuilderService.persistUserAdjustmentUpdates(updates);
      }
      Map<Id, MonthlyPayment__c> afterById = loadOutcomeState(
        itemByPaymentId.keySet()
      );

      List<AdjustmentResult> results = new List<AdjustmentResult>();
      List<Monthly_Payment_Adjustment_History__c> histories = new List<Monthly_Payment_Adjustment_History__c>();
      for (Integer index = 0; index < appliedRequests.size(); index++) {
        AdjustmentRequest calcRequest = appliedRequests[index];
        MonthlyPayment__c beforePayment = beforeById.get(calcRequest.paymentId);
        MonthlyPayment__c afterPayment = afterById.get(calcRequest.paymentId);
        AdjustmentResult result = resultFor(
          calcRequest,
          beforePayment,
          afterPayment
        );
        results.add(result);
        histories.add(
          buildAdjustmentHistory(calcRequest, appliedOutcomes[index])
        );
      }
      if (!histories.isEmpty()) {
        insert histories;
      }
      return results;
    } catch (Exception operationFailure) {
      Database.rollback(adjustmentSavepoint);
      if (operationFailure instanceof AuraHandledException) {
        throw operationFailure;
      }
      throw userFacingException(
        'Nothing was saved. ' + operationFailure.getMessage()
      );
    }
  }

  @AuraEnabled
  public static AdjustmentResult applyIndividualAdjustment(
    AdjustmentRequest request
  ) {
    validateIndividualApplyRequest(request);
    Boolean isSet = request.action == ACTION_SET;
    if (!isSet && request.currentStateExpectation == null) {
      throw new AuraHandledException(
        'Refresh the Monthly Payments and preview this change again.'
      );
    }
    MonthlyPayment__c beforePayment = loadOutcomeState(
        new Set<Id>{ request.paymentId }
      )
      .get(request.paymentId);
    if (beforePayment == null) {
      throw new AuraHandledException('Monthly Payment no longer exists.');
    }
    if (isSet) {
      assertNoExistingEffectiveAdjustment(beforePayment);
    } else {
      assertCurrentState(request.currentStateExpectation, beforePayment);
      assertExistingEffectiveAdjustment(beforePayment);
    }
    AdjustmentResult preview = calculateIndividualAdjustment(
      request,
      beforePayment
    );
    if (
      valueOrZero(request.inputValue) == 0 &&
      (request.action == ACTION_ADD ||
      request.action == ACTION_SET)
    ) {
      return preview;
    }

    MonthlyPayment__c updateRecord = adjustmentUpdateForOutcome(
      beforePayment,
      preview.calculatedOutcome
    );
    Savepoint adjustmentSavepoint = Database.setSavepoint();
    try {
      PackageBuilderService.persistUserAdjustmentUpdates(
        new List<MonthlyPayment__c>{ updateRecord }
      );
      MonthlyPayment__c afterPayment = loadOutcomeState(
          new Set<Id>{ request.paymentId }
        )
        .get(request.paymentId);
      AdjustmentResult applied = resultFor(
        request,
        beforePayment,
        afterPayment
      );
      applied.recurringPricingActive = preview.recurringPricingActive;
      insert buildAdjustmentHistory(request, applied.calculatedOutcome);
      return applied;
    } catch (Exception operationFailure) {
      Database.rollback(adjustmentSavepoint);
      throw operationFailure;
    }
  }

  /**
   * Adapter used by the existing Package Builder individual and bulk save
   * entry point. No pricing is recalculated here.
   */
  public static List<AdjustmentRequest> requestsFromPaymentUpdates(
    List<MonthlyPayment__c> payments
  ) {
    return requestsFromPaymentUpdates(payments, new Map<Id, Decimal>());
  }

  public static List<AdjustmentRequest> requestsFromPaymentUpdates(
    List<MonthlyPayment__c> payments,
    Map<Id, Decimal> enteredPercentageByPaymentId
  ) {
    List<AdjustmentRequest> requests = new List<AdjustmentRequest>();
    if (payments == null) {
      return requests;
    }
    for (MonthlyPayment__c payment : payments) {
      if (payment == null) {
        continue;
      }
      AdjustmentRequest request = new AdjustmentRequest();
      request.paymentId = payment.Id;
      request.action = ACTION_SET;
      request.currentStateExpectation = new CurrentStateExpectation();
      request.paymentUpdate = payment;

      if (
        PackageBuilderService.isUsableFinalAdjustedPrice(
          payment.Final_Adjusted_Price__c
        )
      ) {
        request.inputType = INPUT_FINAL;
        request.inputValue = payment.Final_Adjusted_Price__c;
      } else if (payment.Discount__c != null) {
        request.inputType = INPUT_PERCENTAGE;
        request.inputValue = enteredPercentageByPaymentId != null &&
          enteredPercentageByPaymentId.containsKey(payment.Id)
          ? enteredPercentageByPaymentId.get(payment.Id)
          : payment.Discount__c;
      } else {
        // Usage Based direct Final updates may intentionally carry null to
        // clear a price; the legacy SObject payload does not retain enough
        // field-presence metadata to distinguish that from another null-only
        // patch, so keep both on the established direct-Final path.
        request.inputType = INPUT_FINAL;
        request.inputValue = payment.ListPrice__c;
      }
      requests.add(request);
    }
    return requests;
  }

  /**
   * Applies user adjustments atomically through the established persistence
   * adapter and returns the typed outcome for each payment.
   */
  public static List<AdjustmentResult> apply(List<AdjustmentRequest> requests) {
    applyInvocationCount++;
    if (requests == null || requests.isEmpty()) {
      return new List<AdjustmentResult>();
    }

    Map<Id, AdjustmentRequest> requestByPaymentId = new Map<Id, AdjustmentRequest>();
    for (AdjustmentRequest request : requests) {
      validateRequest(request);
      requestByPaymentId.put(request.paymentId, request);
    }

    Map<Id, MonthlyPayment__c> beforeById = loadOutcomeState(
      requestByPaymentId.keySet()
    );
    List<MonthlyPayment__c> updates = new List<MonthlyPayment__c>();
    Set<Id> noOpPaymentIds = new Set<Id>();
    for (AdjustmentRequest request : requests) {
      MonthlyPayment__c beforePayment = beforeById.get(request.paymentId);
      if (isCleanPercentageZeroSet(request, beforePayment)) {
        noOpPaymentIds.add(request.paymentId);
        continue;
      }
      MonthlyPayment__c updateRecord = request.paymentUpdate;
      if (updateRecord == null) {
        updateRecord = paymentUpdateFromTypedRequest(request);
      }
      updates.add(updateRecord);
    }

    Savepoint adjustmentSavepoint = Database.setSavepoint();
    try {
      if (!updates.isEmpty()) {
        PackageBuilderService.persistUserAdjustmentUpdates(updates);
      }
      Map<Id, MonthlyPayment__c> afterById = loadOutcomeState(
        requestByPaymentId.keySet()
      );

      List<AdjustmentResult> results = new List<AdjustmentResult>();
      List<Monthly_Payment_Adjustment_History__c> histories = new List<Monthly_Payment_Adjustment_History__c>();
      for (AdjustmentRequest request : requests) {
        MonthlyPayment__c beforePayment = beforeById.get(request.paymentId);
        MonthlyPayment__c afterPayment = afterById.get(request.paymentId);
        AdjustmentResult result = new AdjustmentResult();
        result.paymentId = request.paymentId;
        result.inputType = request.inputType;
        result.inputValue = request.inputValue;
        result.action = request.action;
        result.calculatedOutcome = buildOutcome(
          beforePayment,
          afterPayment,
          request.inputType
        );
        results.add(result);

        if (
          !noOpPaymentIds.contains(request.paymentId) &&
          isFirstPercentageSet(request, beforePayment)
        ) {
          histories.add(
            buildAdjustmentHistory(request, result.calculatedOutcome)
          );
        }
      }
      if (!histories.isEmpty()) {
        insert histories;
      }
      return results;
    } catch (Exception operationFailure) {
      Database.rollback(adjustmentSavepoint);
      throw operationFailure;
    }
  }

  private static Boolean isCleanPercentageZeroSet(
    AdjustmentRequest request,
    MonthlyPayment__c beforePayment
  ) {
    return isFirstPercentageSet(request, beforePayment) &&
      request.inputValue == 0;
  }

  private static Boolean isFirstPercentageSet(
    AdjustmentRequest request,
    MonthlyPayment__c beforePayment
  ) {
    return request.inputType == INPUT_PERCENTAGE &&
      request.action == ACTION_SET &&
      beforePayment != null &&
      (beforePayment.Discount__c == null ||
      beforePayment.Discount__c == 0);
  }

  private static Monthly_Payment_Adjustment_History__c buildAdjustmentHistory(
    AdjustmentRequest request,
    CalculatedOutcome outcome
  ) {
    return new Monthly_Payment_Adjustment_History__c(
      Monthly_Payment__c = request.paymentId,
      Adjustment_Type__c = request.inputType,
      Action__c = request.action,
      Original_Price__c = valueOrZero(outcome.originalPrice),
      Existing_Adjustment__c = valueOrZero(outcome.existingAdjustment),
      Entered_Adjustment__c = request.inputValue,
      Resulting_Adjustment__c = valueOrZero(outcome.resultingAdjustment),
      Price_Before__c = valueOrZero(outcome.priceBefore),
      Price_After__c = valueOrZero(outcome.finalPriceAfter)
    );
  }

  /**
   * Discount__c may be stored as a fraction when |percent points| < 1.
   * Task 3 expectations, preview, and history use percent points.
   */
  private static Decimal discountAsPercentPoints(Decimal stored) {
    Decimal value = valueOrZero(stored);
    return Math.abs(value) < 1 ? value * 100 : value;
  }
  private static Decimal valueOrZero(Decimal value) {
    return value == null ? 0 : value;
  }

  private static void validateAdjustedIndividualRequest(
    AdjustmentRequest request
  ) {
    validateRequest(request);
    if (
      (request.inputType != INPUT_PERCENTAGE &&
      request.inputType != INPUT_AMOUNT) ||
      (request.action != ACTION_REPLACE &&
      request.action != ACTION_ADD)
    ) {
      throw new AuraHandledException(
        'Individual preview supports percentage or amount Replace/Add only.'
      );
    }
  }

  private static void validateBulkApplyRequest(
    BulkAdjustmentRequest bulkRequest
  ) {
    if (bulkRequest == null || bulkRequest.items == null) {
      throw new IllegalArgumentException(
        'Bulk adjustment requires at least one Monthly Payment.'
      );
    }
    if (bulkRequest.items.isEmpty()) {
      throw new IllegalArgumentException(
        'Bulk adjustment requires at least one Monthly Payment.'
      );
    }
    if (
      bulkRequest.inputType != INPUT_PERCENTAGE &&
      bulkRequest.inputType != INPUT_AMOUNT
    ) {
      throw new IllegalArgumentException(
        'Bulk adjustment supports percentage or amount only.'
      );
    }
    if (
      bulkRequest.action != ACTION_REPLACE &&
      bulkRequest.action != ACTION_ADD
    ) {
      throw new IllegalArgumentException(
        'Bulk adjustment action must be Replace or Add.'
      );
    }
    if (bulkRequest.inputValue == null) {
      throw new IllegalArgumentException(
        'Bulk adjustment requires an input value.'
      );
    }
    for (AdjustmentRequest item : bulkRequest.items) {
      if (item == null || item.paymentId == null) {
        throw new IllegalArgumentException(
          'Bulk adjustment requires a payment identity for every row.'
        );
      }
    }
  }

  private static AdjustmentRequest bulkCalculationRequest(
    Id paymentId,
    BulkAdjustmentRequest bulkRequest,
    MonthlyPayment__c beforePayment
  ) {
    AdjustmentRequest calcRequest = new AdjustmentRequest();
    calcRequest.paymentId = paymentId;
    calcRequest.inputType = bulkRequest.inputType;
    calcRequest.inputValue = bulkRequest.inputValue;
    calcRequest.action = resolveBulkEffectiveAction(
      beforePayment,
      bulkRequest.action
    );
    return calcRequest;
  }

  private static String resolveBulkEffectiveAction(
    MonthlyPayment__c beforePayment,
    String chosenAction
  ) {
    if (beforePayment == null || valueOrZero(beforePayment.Discount__c) == 0) {
      return ACTION_SET;
    }
    return chosenAction;
  }

  private static Boolean isBulkNoOp(
    AdjustmentRequest request,
    MonthlyPayment__c beforePayment
  ) {
    return valueOrZero(request.inputValue) == 0 &&
      (request.action == ACTION_ADD ||
      request.action == ACTION_SET);
  }

  private static String bulkStaleMessage() {
    return System.Label.MonthlyPayment_Adjustment_BulkStaleError;
  }

  /**
   * AuraHandledException.getMessage() often returns "Script-thrown exception"
   * unless setMessage is also called. setMessage keeps the user text visible
   * to LWC and to Apex tests when the exception is rethrown.
   */
  private static AuraHandledException userFacingException(String message) {
    AuraHandledException failure = new AuraHandledException(message);
    failure.setMessage(message);
    return failure;
  }

  /** UI FinalPrice is 2dp; payable from Price×Discount may carry extra precision. */
  private static Boolean finalPricesMatch(Decimal expected, Decimal actual) {
    return valueOrZero(expected).setScale(2, System.RoundingMode.HALF_UP) ==
      valueOrZero(actual).setScale(2, System.RoundingMode.HALF_UP);
  }

  private static void validateIndividualApplyRequest(
    AdjustmentRequest request
  ) {
    validateRequest(request);
    if (
      (request.inputType != INPUT_PERCENTAGE &&
      request.inputType != INPUT_AMOUNT) ||
      (request.action == ACTION_SET &&
      request.inputType != INPUT_AMOUNT)
    ) {
      throw new AuraHandledException(
        'Individual apply supports percentage Replace/Add or amount Set/Replace/Add only.'
      );
    }
  }

  private static AdjustmentResult calculateIndividualAdjustment(
    AdjustmentRequest request,
    MonthlyPayment__c payment
  ) {
    Decimal originalPrice = valueOrZero(payment.Price__c);
    Decimal priceBefore = valueOrZero(
      PackageBuilderService.payableAmountForMonthlyPayment(payment)
    );
    Decimal basis = request.action == ACTION_ADD ? priceBefore : originalPrice;
    Decimal targetFinal = request.inputType == INPUT_AMOUNT
      ? basis + request.inputValue
      : basis * (1 + (request.inputValue / 100));
    targetFinal = targetFinal.setScale(2, System.RoundingMode.HALF_UP);

    AdjustmentResult result = new AdjustmentResult();
    result.paymentId = request.paymentId;
    result.inputType = request.inputType;
    result.inputValue = request.inputValue;
    result.action = request.action;
    result.calculatedOutcome = new CalculatedOutcome();
    result.calculatedOutcome.originalPrice = originalPrice;
    result.calculatedOutcome.existingAdjustment = request.inputType ==
      INPUT_AMOUNT
      ? priceBefore - originalPrice
      : discountAsPercentPoints(payment.Discount__c);
    result.calculatedOutcome.priceBefore = priceBefore;
    result.calculatedOutcome.resultingAdjustment = request.inputType ==
      INPUT_AMOUNT
      ? targetFinal - originalPrice
      : RecurringPriceIncreaseService.discountFromBasis(
          originalPrice,
          targetFinal
        );
    result.calculatedOutcome.finalPriceAfter = targetFinal;
    result.currentStateExpectation = expectationFor(payment);
    result.recurringPricingActive = recurringPricingApplies(payment);
    return result;
  }

  private static AdjustmentResult resultFor(
    AdjustmentRequest request,
    MonthlyPayment__c beforePayment,
    MonthlyPayment__c afterPayment
  ) {
    AdjustmentResult result = new AdjustmentResult();
    result.paymentId = request.paymentId;
    result.inputType = request.inputType;
    result.inputValue = request.inputValue;
    result.action = request.action;
    result.calculatedOutcome = buildOutcome(
      beforePayment,
      afterPayment,
      request.inputType
    );
    result.currentStateExpectation = expectationFor(afterPayment);
    return result;
  }

  private static CurrentStateExpectation expectationFor(
    MonthlyPayment__c payment
  ) {
    CurrentStateExpectation expectation = new CurrentStateExpectation();
    expectation.discount = discountAsPercentPoints(payment.Discount__c);
    expectation.finalPrice = valueOrZero(
      PackageBuilderService.payableAmountForMonthlyPayment(payment)
    );
    expectation.lastModifiedDate = payment.LastModifiedDate;
    return expectation;
  }

  private static void assertBulkCurrentState(
    CurrentStateExpectation expected,
    MonthlyPayment__c actual
  ) {
    Decimal actualDiscount = discountAsPercentPoints(actual.Discount__c);
    Decimal actualFinal = valueOrZero(
      PackageBuilderService.payableAmountForMonthlyPayment(actual)
    );
    if (
      expected.lastModifiedDate == null ||
      expected.lastModifiedDate != actual.LastModifiedDate ||
      valueOrZero(expected.discount) != actualDiscount ||
      !finalPricesMatch(expected.finalPrice, actualFinal)
    ) {
      throw userFacingException(bulkStaleMessage());
    }
  }

  private static void assertCurrentState(
    CurrentStateExpectation expected,
    MonthlyPayment__c actual
  ) {
    Decimal actualDiscount = discountAsPercentPoints(actual.Discount__c);
    Decimal actualFinal = valueOrZero(
      PackageBuilderService.payableAmountForMonthlyPayment(actual)
    );
    if (
      expected.lastModifiedDate == null ||
      expected.lastModifiedDate != actual.LastModifiedDate ||
      valueOrZero(expected.discount) != actualDiscount ||
      !finalPricesMatch(expected.finalPrice, actualFinal)
    ) {
      throw userFacingException(
        'This Monthly Payment changed after preview. Refresh and preview it again.'
      );
    }
  }

  private static void assertExistingEffectiveAdjustment(
    MonthlyPayment__c payment
  ) {
    if (payment == null || valueOrZero(payment.Discount__c) == 0) {
      throw new AuraHandledException(
        'This Monthly Payment has no existing adjustment. Refresh and use Set.'
      );
    }
  }

  private static void assertNoExistingEffectiveAdjustment(
    MonthlyPayment__c payment
  ) {
    if (payment == null || valueOrZero(payment.Discount__c) != 0) {
      throw new AuraHandledException(
        'This Monthly Payment already has an adjustment. Refresh and choose Replace or Add.'
      );
    }
  }

  private static MonthlyPayment__c adjustmentUpdateForOutcome(
    MonthlyPayment__c beforePayment,
    CalculatedOutcome outcome
  ) {
    Decimal storageDiscount = RecurringPriceIncreaseService.discountForMonthlyPaymentStorage(
      outcome.originalPrice,
      outcome.finalPriceAfter
    );
    Decimal enteredForPersistence = storageDiscount;
    Date monthStart = beforePayment.Start_date__c;
    Date monthEnd = beforePayment.End_date__c;
    Date orderStart = beforePayment.OrderItem__r != null &&
      beforePayment.OrderItem__r.Order != null
      ? (beforePayment.OrderItem__r.Order.Order_Start_Date__c != null
          ? beforePayment.OrderItem__r.Order.Order_Start_Date__c
          : beforePayment.OrderItem__r.Order.EffectiveDate)
      : null;
    if (
      monthStart != null &&
      monthEnd != null &&
      orderStart != null &&
      monthStart < orderStart &&
      orderStart <= monthEnd
    ) {
      Integer totalDays = monthStart.daysBetween(monthEnd) + 1;
      Integer preDays = monthStart.daysBetween(orderStart);
      Integer postDays = orderStart.daysBetween(monthEnd) + 1;
      if (totalDays > 0 && postDays > 0) {
        enteredForPersistence =
          ((storageDiscount * totalDays) -
          (valueOrZero(beforePayment.Discount__c) * preDays)) / postDays;
      }
    }
    return new MonthlyPayment__c(
      Id = beforePayment.Id,
      Discount__c = enteredForPersistence
    );
  }

  private static Boolean recurringPricingApplies(MonthlyPayment__c payment) {
    Date paymentMonth = payment.Start_date__c != null
      ? payment.Start_date__c.toStartOfMonth()
      : null;
    if (paymentMonth == null) {
      return false;
    }
    if (payment.OrderItem__r != null) {
      Date startDate = payment.OrderItem__r.Recurring_Increase_Start_Date__c;
      return payment.OrderItem__r.Recurring_Price_Increase_Enabled__c == true &&
        startDate != null &&
        paymentMonth >= startDate.toStartOfMonth();
    }
    if (payment.OpportunityLineItem__r != null) {
      Date startDate = payment.OpportunityLineItem__r.Recurring_Increase_Start_Date__c;
      return payment.OpportunityLineItem__r.Recurring_Price_Increase_Enabled__c ==
        true &&
        startDate != null &&
        paymentMonth >= startDate.toStartOfMonth();
    }
    return false;
  }

  private static void validateRequest(AdjustmentRequest request) {
    if (request == null || request.paymentId == null) {
      throw new IllegalArgumentException(
        'Monthly Payment adjustment requires a payment identity.'
      );
    }
    if (
      request.inputType != INPUT_PERCENTAGE &&
      request.inputType != INPUT_AMOUNT &&
      request.inputType != INPUT_FINAL
    ) {
      throw new IllegalArgumentException(
        'Monthly Payment adjustment input type is invalid.'
      );
    }
    if (
      request.action != ACTION_SET &&
      request.action != ACTION_REPLACE &&
      request.action != ACTION_ADD
    ) {
      throw new IllegalArgumentException(
        'Monthly Payment adjustment action is invalid.'
      );
    }
    if (request.inputValue == null && request.inputType != INPUT_FINAL) {
      throw new IllegalArgumentException(
        'Monthly Payment adjustment requires an input value.'
      );
    }
  }

  /**
   * Supports typed callers without changing direct Final behavior.
   */
  private static MonthlyPayment__c paymentUpdateFromTypedRequest(
    AdjustmentRequest request
  ) {
    MonthlyPayment__c payment = new MonthlyPayment__c(Id = request.paymentId);
    if (request.inputType == INPUT_PERCENTAGE) {
      payment.Discount__c = request.inputValue;
    } else {
      payment.Final_Adjusted_Price__c = request.inputValue;
    }
    return payment;
  }

  private static Map<Id, MonthlyPayment__c> loadOutcomeState(
    Set<Id> paymentIds
  ) {
    if (paymentIds == null || paymentIds.isEmpty()) {
      return new Map<Id, MonthlyPayment__c>();
    }
    return new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c,
          FinalPrice__c,
          LastModifiedDate,
          Start_date__c,
          End_date__c,
          OrderItem__c,
          OrderItem__r.Order.Order_Start_Date__c,
          OrderItem__r.Order.EffectiveDate,
          OrderItem__r.Recurring_Price_Increase_Enabled__c,
          OrderItem__r.Recurring_Increase_Start_Date__c,
          OpportunityLineItem__c,
          OpportunityLineItem__r.Recurring_Price_Increase_Enabled__c,
          OpportunityLineItem__r.Recurring_Increase_Start_Date__c
        FROM MonthlyPayment__c
        WHERE Id IN :paymentIds
      ]
    );
  }

  private static CalculatedOutcome buildOutcome(
    MonthlyPayment__c beforePayment,
    MonthlyPayment__c afterPayment,
    String inputType
  ) {
    CalculatedOutcome outcome = new CalculatedOutcome();
    if (beforePayment != null) {
      outcome.originalPrice = beforePayment.Price__c;
      outcome.priceBefore = PackageBuilderService.payableAmountForMonthlyPayment(
        beforePayment
      );
      outcome.existingAdjustment = inputType == INPUT_AMOUNT
        ? valueOrZero(outcome.priceBefore) - valueOrZero(outcome.originalPrice)
        : discountAsPercentPoints(beforePayment.Discount__c);
    }
    if (afterPayment != null) {
      if (outcome.originalPrice == null) {
        outcome.originalPrice = afterPayment.Price__c;
      }
      outcome.finalPriceAfter = PackageBuilderService.payableAmountForMonthlyPayment(
        afterPayment
      );
      outcome.resultingAdjustment = inputType == INPUT_AMOUNT
        ? valueOrZero(outcome.finalPriceAfter) -
          valueOrZero(outcome.originalPrice)
        : discountAsPercentPoints(afterPayment.Discount__c);
    }
    return outcome;
  }
}
