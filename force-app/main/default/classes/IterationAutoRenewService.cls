public with sharing class IterationAutoRenewService {
  @TestVisible
  static Boolean failAfterClone = false;

  public class RunResult {
    public String outcome;
    public String message;
    public Id newOrderId;
  }

  public static void processDueRenewals() {
    for (
      Id contractId : findContractsWithDueActivatedIterations(Date.today())
    ) {
      try {
        processContract(contractId);
      } catch (Exception e) {
        stamp(contractId, 'Failed', e.getMessage(), null);
      }
    }
  }

  /**
   * Contracts whose Activated Periodic lines have a due Iteration.
   * Draft / Negotiation / Archived copies are excluded so modify-contract
   * Iteration clones never drive renewals alongside the live order.
   */
  public static Set<Id> findContractsWithDueActivatedIterations(Date today) {
    Set<Id> contractIds = new Set<Id>();
    if (today == null) {
      return contractIds;
    }
    for (Iteration__c row : [
      SELECT Order_Product__r.Order.ContractId
      FROM Iteration__c
      WHERE
        Status__c != :IterationService.STATUS_COMPLETED
        AND Status__c != :IterationService.STATUS_INACTIVE
        AND Notice_Date__c <= :today
        AND Order_Product__c != NULL
        AND Order_Product__r.Access_Type__c = :IterationService.ACCESS_PERIODIC
        AND Order_Product__r.Termination_Reason__c = NULL
        AND Order_Product__r.Order.Status = 'Activated'
        AND Order_Product__r.Remaining_Iterations__c > 0
    ]) {
      if (row.Order_Product__r?.Order?.ContractId != null) {
        contractIds.add(row.Order_Product__r.Order.ContractId);
      }
    }
    return contractIds;
  }

  public static RunResult processContract(Id contractId) {
    RunResult result = new RunResult();
    if (contractId == null) {
      result.outcome = 'Skipped';
      result.message = 'No contract';
      return result;
    }

    Boolean prevMpSuppress = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    Boolean prevSkipIterCopy = PackageBuilderService.skipIterationCopyOnDraftClone;
    Boolean prevSkipActivateBackfill = PackageBuilderService.skipActivatePaymentBackfill;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    PackageBuilderService.skipIterationCopyOnDraftClone = true;
    PackageBuilderService.skipActivatePaymentBackfill = true;

    try {
      return processContractInternal(contractId, result);
    } finally {
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMpSuppress;
      PackageBuilderService.skipIterationCopyOnDraftClone = prevSkipIterCopy;
      PackageBuilderService.skipActivatePaymentBackfill = prevSkipActivateBackfill;
    }
  }

  static RunResult processContractInternal(Id contractId, RunResult result) {
    List<Order> activeOrders = [
      SELECT Id, Status, ContractId, EffectiveDate, EndDate
      FROM Order
      WHERE ContractId = :contractId AND Status = 'Activated'
      LIMIT 1
    ];
    if (activeOrders.isEmpty()) {
      result.outcome = 'Skipped';
      result.message = 'No active order';
      stamp(contractId, result.outcome, result.message, null);
      return result;
    }
    Order active = activeOrders[0];
    List<OrderItem> activeItems = [
      SELECT
        Id,
        OrderId,
        Access_Type__c,
        Termination_Reason__c,
        Remaining_Iterations__c,
        EndDate,
        UnitPrice,
        Quantity,
        Change_Type__c
      FROM OrderItem
      WHERE OrderId = :active.Id
    ];
    Set<Id> itemIds = new Map<Id, OrderItem>(activeItems).keySet();
    Map<Id, List<Iteration__c>> byItem = IterationService.groupByParent(
      IterationService.queryByParent(itemIds)
    );

    Date today = Date.today();
    List<OrderItem> dueItems = new List<OrderItem>();
    Map<Id, Iteration__c> dueIterationByItem = new Map<Id, Iteration__c>();
    for (OrderItem item : activeItems) {
      if (!isLineEligible(item)) {
        continue;
      }
      List<Iteration__c> plan = byItem.get(item.Id);
      Iteration__c nextRow = IterationService.nextDueIteration(plan, today);
      if (nextRow == null) {
        continue;
      }
      dueItems.add(item);
      dueIterationByItem.put(item.Id, nextRow);
    }

    if (dueItems.isEmpty()) {
      result.outcome = 'Skipped';
      result.message = 'Zero eligible due lines';
      stamp(contractId, result.outcome, result.message, null);
      return result;
    }

    List<Order> existingDrafts = [
      SELECT Id
      FROM Order
      WHERE ContractId = :contractId AND Status IN ('Draft', 'Negotiation')
      LIMIT 1
    ];
    if (!existingDrafts.isEmpty()) {
      PackageBuilderService.cancelDraftOrder(existingDrafts[0].Id);
    }

    PackageBuilderService.DraftOrderResult cloned = PackageBuilderService.ensureDraftOrder(
      contractId
    );
    if (failAfterClone) {
      throw new AutoRenewException('Forced failure after clone');
    }

    Map<Id, Id> itemIdMapping = cloned.itemIdMapping;
    if (itemIdMapping == null || itemIdMapping.isEmpty()) {
      throw new AutoRenewException('Draft clone mapping missing');
    }

    Map<Id, Decimal> basisByItem = resolveBasisByItems(dueItems);

    List<OrderItem> draftUpdates = new List<OrderItem>();
    List<Iteration__c> iterationUpdates = new List<Iteration__c>();
    Map<Id, Iteration__c> completedPriorById = new Map<Id, Iteration__c>();
    List<Iteration__c> iterationInserts = new List<Iteration__c>();
    Set<Id> renewedLineIds = new Set<Id>();
    Set<Id> iterationTargetLineIds = new Set<Id>();
    Map<Id, Date> oldEndByNewLine = new Map<Id, Date>();
    Map<Id, Decimal> discountByNewLine = new Map<Id, Decimal>();
    Map<Id, Decimal> targetFinalByNewLine = new Map<Id, Decimal>();
    Date maxNewEnd = cloned.draftOrder.EndDate;

    for (OrderItem oldItem : dueItems) {
      Id newItemId = itemIdMapping.get(oldItem.Id);
      if (newItemId == null) {
        continue;
      }
      Iteration__c due = dueIterationByItem.get(oldItem.Id);
      Date oldEnd = oldItem.EndDate;
      Integer months = due.Duration_Months__c == null
        ? 0
        : Integer.valueOf(due.Duration_Months__c);
      Date newStart = oldEnd.addDays(1);
      Date newEnd = months > 0
        ? newStart.addMonths(months).addDays(-1)
        : newStart;

      Decimal basis = basisByItem.containsKey(oldItem.Id)
        ? basisByItem.get(oldItem.Id)
        : lineListMonthTotal(oldItem);
      Decimal targetFinal = applyIncrease(due, basis);
      // MP Discount__c derives payable from list total (UnitPrice × qty), not commercial basis.
      Decimal listTotal = lineListMonthTotal(oldItem);
      Decimal discountPct = RecurringPriceIncreaseService.discountForMonthlyPaymentStorage(
        listTotal,
        targetFinal
      );

      // basis is a full-month commercial total; UnitPrice is per desk — never copy basis onto UnitPrice.
      draftUpdates.add(
        new OrderItem(
          Id = newItemId,
          EndDate = newEnd,
          Change_Type__c = 'No Change'
        )
      );
      oldEndByNewLine.put(newItemId, oldEnd);
      discountByNewLine.put(newItemId, discountPct);
      targetFinalByNewLine.put(newItemId, targetFinal);
      renewedLineIds.add(newItemId);
      if (maxNewEnd == null || (newEnd != null && newEnd > maxNewEnd)) {
        maxNewEnd = newEnd;
      }

      completedPriorById.put(due.Id, due.clone(true, true, true, true));
      due.Status__c = IterationService.STATUS_COMPLETED;
      iterationUpdates.add(due);
    }

    // Copy full plan onto draft lines (including completed) for N-out-of-M display.
    // Draft clone skipped Iteration copy to avoid duplicates and extra SOQL.
    for (OrderItem oldItem : activeItems) {
      Id newItemId = itemIdMapping.get(oldItem.Id);
      if (newItemId == null) {
        continue;
      }
      List<Iteration__c> siblingPlan = byItem.get(oldItem.Id);
      if (siblingPlan == null || siblingPlan.isEmpty()) {
        continue;
      }
      Iteration__c due = dueIterationByItem.get(oldItem.Id);
      for (Iteration__c row : siblingPlan) {
        Iteration__c source = (due != null && row.Id == due.Id) ? due : row;
        Iteration__c copy = source.clone(false, true, false, false);
        copy.Order_Product__c = newItemId;
        copy.Opportunity_Product__c = null;
        iterationInserts.add(copy);
      }
      iterationTargetLineIds.add(newItemId);
    }

    // Extend Contract.EndDate before Order.EndDate (platform rule); same path as Package Builder.
    if (
      maxNewEnd != null &&
      (cloned.draftOrder.EndDate == null ||
      maxNewEnd > cloned.draftOrder.EndDate)
    ) {
      PackageEndDateRollupService.applyContractThenOrderEndForPackage(
        cloned.draftOrder.Id,
        maxNewEnd
      );
      cloned.draftOrder.EndDate = maxNewEnd;
    }
    if (!draftUpdates.isEmpty()) {
      update draftUpdates;
    }
    if (!iterationUpdates.isEmpty()) {
      update iterationUpdates;
      for (Iteration__c completed : iterationUpdates) {
        Iteration__c prior = completedPriorById.get(completed.Id);
        if (prior != null) {
          IterationHistoryService.recordStatusChanged(
            prior,
            completed,
            'Auto-renew applied'
          );
        }
      }
    }
    if (!iterationInserts.isEmpty()) {
      insert iterationInserts;
    }

    Map<Id, List<Iteration__c>> newPlans = IterationService.groupByParent(
      IterationService.queryByParent(iterationTargetLineIds)
    );
    Map<Id, OrderItem> newLines = new Map<Id, OrderItem>(
      [SELECT Id, EndDate FROM OrderItem WHERE Id IN :iterationTargetLineIds]
    );
    List<Iteration__c> projectionUpdates = new List<Iteration__c>();
    List<OrderItem> remainingUpdates = new List<OrderItem>();
    for (Id newId : iterationTargetLineIds) {
      List<Iteration__c> plan = newPlans.get(newId);
      OrderItem newLine = newLines.get(newId);
      if (plan == null) {
        plan = new List<Iteration__c>();
      }
      IterationService.recalculateProjections(
        newId,
        newLine?.EndDate,
        plan,
        false
      );
      for (Iteration__c row : plan) {
        if (
          row.Status__c != IterationService.STATUS_COMPLETED &&
          row.Status__c != IterationService.STATUS_INACTIVE
        ) {
          projectionUpdates.add(row);
        }
      }
      remainingUpdates.add(
        new OrderItem(
          Id = newId,
          Remaining_Iterations__c = IterationService.countRemaining(plan)
        )
      );
    }
    if (!projectionUpdates.isEmpty()) {
      update projectionUpdates;
    }
    if (!remainingUpdates.isEmpty()) {
      update remainingUpdates;
    }

    // One payment backfill for all draft lines (triggers were suppressed during clone/apply).
    List<String> draftLineIds = new List<String>();
    for (Id draftLineId : itemIdMapping.values()) {
      draftLineIds.add(String.valueOf(draftLineId));
    }
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = false;
    PackageBuilderService.ensureMonthlyPaymentsForLineItems(
      String.valueOf(cloned.draftOrder.Id),
      draftLineIds
    );

    applyNewPeriodDiscounts(
      renewedLineIds,
      oldEndByNewLine,
      discountByNewLine,
      targetFinalByNewLine
    );

    Map<Id, Date> renewalStartByNewLine = new Map<Id, Date>();
    for (Id newLineId : oldEndByNewLine.keySet()) {
      Date oldEnd = oldEndByNewLine.get(newLineId);
      if (oldEnd != null) {
        renewalStartByNewLine.put(newLineId, oldEnd.addDays(1));
      }
    }
    RecurringPriceIncreaseService.stackRecurringAfterRenewalPricing(
      targetFinalByNewLine,
      renewalStartByNewLine
    );

    PackageBuilderService.activateDraftOrder(
      cloned.draftOrder.Id,
      cloned.draftOrder.EffectiveDate
    );

    result.outcome = 'Success';
    result.message = 'Auto-renew activated';
    result.newOrderId = cloned.draftOrder.Id;
    stamp(contractId, result.outcome, result.message, result.newOrderId);
    return result;
  }

  @TestVisible
  static Boolean isLineEligible(OrderItem item) {
    return item != null &&
      item.Access_Type__c == IterationService.ACCESS_PERIODIC &&
      String.isBlank(item.Termination_Reason__c) &&
      item.Remaining_Iterations__c != null &&
      item.Remaining_Iterations__c > 0;
  }

  @TestVisible
  static Decimal resolveBasis(OrderItem item) {
    if (item == null) {
      return 0;
    }
    Map<Id, Decimal> byId = resolveBasisByItems(new List<OrderItem>{ item });
    return byId.containsKey(item.Id)
      ? byId.get(item.Id)
      : lineListMonthTotal(item);
  }

  @TestVisible
  static Map<Id, Decimal> resolveBasisByItems(List<OrderItem> items) {
    Map<Id, Decimal> basisByItem = new Map<Id, Decimal>();
    if (items == null || items.isEmpty()) {
      return basisByItem;
    }
    Map<Id, OrderItem> itemById = new Map<Id, OrderItem>();
    for (OrderItem item : items) {
      if (item != null && item.Id != null) {
        itemById.put(item.Id, item);
        basisByItem.put(item.Id, lineListMonthTotal(item));
      }
    }
    if (itemById.isEmpty()) {
      return basisByItem;
    }

    Map<Id, MonthlyPayment__c> lastPaymentByItem = new Map<Id, MonthlyPayment__c>();
    for (MonthlyPayment__c payment : [
      SELECT
        FinalPrice__c,
        Monthly_Units__c,
        Access_Type__c,
        OrderItem__c,
        Start_date__c,
        End_date__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :itemById.keySet()
    ]) {
      OrderItem item = itemById.get(payment.OrderItem__c);
      if (item == null) {
        continue;
      }
      Date startDate = payment.Start_date__c != null
        ? payment.Start_date__c
        : payment.Stat_Date_Trigger__c;
      if (
        startDate == null ||
        item.EndDate == null ||
        startDate > item.EndDate
      ) {
        continue;
      }
      MonthlyPayment__c lastPayment = lastPaymentByItem.get(item.Id);
      Date lastStart = lastPayment == null
        ? null
        : (lastPayment.Start_date__c != null
            ? lastPayment.Start_date__c
            : lastPayment.Stat_Date_Trigger__c);
      if (lastPayment == null || (lastStart != null && startDate > lastStart)) {
        lastPaymentByItem.put(item.Id, payment);
      }
    }

    for (Id itemId : lastPaymentByItem.keySet()) {
      OrderItem item = itemById.get(itemId);
      Decimal fullMonth = PackageBuilderMonthPriceService.fullMonthTotalFromPayment(
        lastPaymentByItem.get(itemId)
      );
      basisByItem.put(
        itemId,
        fullMonth == null ? lineListMonthTotal(item) : fullMonth
      );
    }
    return basisByItem;
  }

  @TestVisible
  static Decimal applyIncrease(Iteration__c row, Decimal basis) {
    Decimal workingBasis = basis == null ? 0 : basis;
    String increaseType = IterationService.normalizeIncreaseType(
      row.Increase_Type__c
    );
    Decimal percentVal = row.Increase_Percent__c;
    Decimal amountVal = row.Increase_Amount__c;
    Decimal finalVal = row.Final_Price__c;

    if (String.isBlank(increaseType)) {
      return workingBasis;
    }
    if (increaseType == IterationService.TYPE_FINAL) {
      return finalVal == null ? workingBasis : finalVal;
    }
    if (increaseType == IterationService.TYPE_VALUE) {
      return workingBasis + (amountVal == null ? 0 : amountVal);
    }
    Decimal pct = percentVal == null ? 0 : percentVal;
    if (workingBasis == 0) {
      return 0;
    }
    Decimal pctFraction = Math.abs(pct) > 1 ? (pct / 100) : pct;
    return (workingBasis * (1 + pctFraction)).setScale(2);
  }

  /** Full-month list total from line pricing (UnitPrice is per desk). */
  @TestVisible
  static Decimal lineListMonthTotal(OrderItem item) {
    if (item == null) {
      return 0;
    }
    Decimal unitPrice = item.UnitPrice == null ? 0 : item.UnitPrice;
    Decimal quantity = 1;
    if (item.getPopulatedFieldsAsMap().containsKey('Quantity')) {
      Decimal lineQty = item.Quantity;
      if (lineQty != null && lineQty != 0) {
        quantity = lineQty;
      }
    }
    return (unitPrice * quantity).setScale(2);
  }

  static Decimal discountFromBasis(Decimal basis, Decimal targetFinal) {
    if (basis == null || basis == 0 || targetFinal == null) {
      return 0;
    }
    return (((targetFinal / basis) - 1) * 100).setScale(6);
  }

  @TestVisible
  static void applyNewPeriodDiscounts(
    Set<Id> newLineIds,
    Map<Id, Date> oldEndByNewLine,
    Map<Id, Decimal> discountByNewLine,
    Map<Id, Decimal> targetFinalByNewLine
  ) {
    if (newLineIds == null || newLineIds.isEmpty()) {
      return;
    }
    List<MonthlyPayment__c> updates = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c payment : [
      SELECT Id, OrderItem__c, End_date__c, End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :newLineIds
    ]) {
      Date oldEnd = oldEndByNewLine.get(payment.OrderItem__c);
      if (oldEnd == null) {
        continue;
      }
      Date newStart = oldEnd.addDays(1);
      Date paymentEnd = payment.End_date__c != null
        ? payment.End_date__c
        : payment.End_Date_trigger__c;
      if (paymentEnd == null || paymentEnd < newStart) {
        continue;
      }
      updates.add(
        new MonthlyPayment__c(
          Id = payment.Id,
          Discount__c = discountByNewLine.get(payment.OrderItem__c),
          Final_Adjusted_Price__c = targetFinalByNewLine.get(
            payment.OrderItem__c
          )
        )
      );
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  public static void stamp(
    Id contractId,
    String outcome,
    String message,
    Id newOrderId
  ) {
    if (contractId == null) {
      return;
    }
    String text =
      Datetime.now().formatGmt('yyyy-MM-dd HH:mm:ss') +
      'Z | ' +
      outcome +
      ' | ' +
      (message == null ? '' : message);
    if (newOrderId != null) {
      text += ' | Order ' + String.valueOf(newOrderId);
    }
    update new Contract(
      Id = contractId,
      Last_Auto_Renew_Result__c = text,
      Last_Auto_Renew_At__c = Datetime.now()
    );
  }

  static Decimal nvl(Decimal a, Decimal b) {
    return a != null ? a : b;
  }
  static String firstNonBlank(String a, String b) {
    return String.isNotBlank(a) ? a : b;
  }

  public class AutoRenewException extends Exception {
  }
}
