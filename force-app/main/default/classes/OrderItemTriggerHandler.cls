/**
 * @description       :The OrderItemTriggerHandler class handles OrderItem trigger events, managing the creation, deletion, and updating of related monthly payments through the
 * 						 ContractService. It executes specific actions after insert, before delete, and after update trigger events.
 * @author            : LAURIE CS
 * @group             :
 * @last modified on  : 2024-10-13
 **/
public with sharing class OrderItemTriggerHandler extends TriggerHandler {
  /** Package Builder contract terms: Product2.Type__c value for Contract Terms lines. */
  private static final String PRODUCT_TYPE_CONTRACT_TERMS = 'Contract Terms';

  public static Boolean SKIP_DATE_SYNC = false;
  /**
   * Heavy monthly-payment DML/SOQL from {@link ContractService}; suppress in focused unit tests that only assert line-level behavior.
   * Always reset to false in a {@code finally} block.
   */
  @TestVisible
  public static Boolean TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = false;
  private static Boolean paymentSyncInProgress = false;
  private static Boolean parentEndDateSyncInProgress = false;
  private static Boolean deferParentEndDateSync = false;
  private static Set<Id> deferredParentEndDateOrderIds = new Set<Id>();
  private static Map<Id, Order> parentOrderById = new Map<Id, Order>();
  /** Prevents recursion when extending Contract/Order from OrderItem before-save. */
  private static Boolean extendingPackageDatesFromLines = false;

  /**
   * When > 0, {@link #normalizeContractTermMeterEndDates} does not clear meter line ends.
   * Used by termination, draft finalize exit bump, and previous-order curtail Apex that set EndDate without Change_Type = Removed.
   */
  private static Integer contractTermMeterEndDateNormalizeSuppressDepth = 0;

  /** Begin suppressing contract-term meter EndDate stripping for the current transaction (pair with exit). */
  public static void enterContractTermMeterEndDateNormalizeSuppress() {
    contractTermMeterEndDateNormalizeSuppressDepth++;
  }

  /** End suppressing contract-term meter EndDate stripping (pair with enter). */
  public static void exitContractTermMeterEndDateNormalizeSuppress() {
    if (contractTermMeterEndDateNormalizeSuppressDepth > 0) {
      contractTermMeterEndDateNormalizeSuppressDepth--;
    }
  }

  @TestVisible
  static void resetContractTermMeterEndDateNormalizeSuppressDepthForTests() {
    contractTermMeterEndDateNormalizeSuppressDepth = 0;
  }

  public OrderItemTriggerHandler() {
    super('OrderItemTriggerHandler');
  }

  public override void beforeInsert(List<SObject> newList) {
    normalizeContractTermMeterEndDates((List<OrderItem>) newList);
    clearPackageEndDatesWhenMonthlyAccess((List<OrderItem>) newList, null);
    ensureContractAndOrderCoverIncomingLineEndDates(
      (List<OrderItem>) newList,
      null
    );
    syncStartAndEntryDates((List<OrderItem>) newList, null);
  }

  public override void beforeUpdate(
    Map<Id, SObject> triggerNewMap,
    Map<Id, SObject> triggerOldMap
  ) {
    Map<Id, OrderItem> oldMap = new Map<Id, OrderItem>();
    for (Id keyId : triggerOldMap.keySet()) {
      oldMap.put(keyId, (OrderItem) triggerOldMap.get(keyId));
    }
    archiveSoftDeletedLineDates(
      (List<OrderItem>) triggerNewMap.values(),
      oldMap
    );
    normalizeContractTermMeterEndDates(
      (List<OrderItem>) triggerNewMap.values()
    );
    clearPackageEndDatesWhenMonthlyAccess(
      (List<OrderItem>) triggerNewMap.values(),
      oldMap
    );
    ensureContractAndOrderCoverIncomingLineEndDates(
      (List<OrderItem>) triggerNewMap.values(),
      oldMap
    );
    alignServiceDateToEndDateForContractTermination(
      (List<OrderItem>) triggerNewMap.values()
    );
    syncStartAndEntryDates((List<OrderItem>) triggerNewMap.values(), oldMap);
  }

  /**
   * Contract termination can curtail products to a termination date that is earlier than a future-dated ServiceDate.
   * To avoid validation/trigger failures, align ServiceDate down to EndDate for those curtailed lines.
   * Scoped to contracts that have Contract_Termination_Date__c populated.
   */
  /**
   * Monthly package access is open-ended: clear line end dates unless the product is terminated
   * (Termination_Reason__c set — those lines are managed by termination flows, not auto-cleared here).
   */
  private void clearPackageEndDatesWhenMonthlyAccess(
    List<OrderItem> incomingItems,
    Map<Id, OrderItem> oldMap
  ) {
    if (incomingItems == null || incomingItems.isEmpty()) {
      return;
    }
    Set<Id> monthlyReplacedParentIds = new Set<Id>();
    Set<Id> orderIds = new Set<Id>();
    for (OrderItem oi : incomingItems) {
      if (oi == null) {
        continue;
      }
      if (oi.Replaced_Order_Product__c != null) {
        monthlyReplacedParentIds.add(oi.Replaced_Order_Product__c);
      }
      if (oi.OrderId != null) {
        orderIds.add(oi.OrderId);
      }
    }
    if (!orderIds.isEmpty()) {
      for (OrderItem row : [
        SELECT Replaced_Order_Product__c
        FROM OrderItem
        WHERE OrderId IN :orderIds AND Replaced_Order_Product__c != NULL
      ]) {
        monthlyReplacedParentIds.add(row.Replaced_Order_Product__c);
      }
    }
    for (OrderItem oi : incomingItems) {
      if (oi == null) {
        continue;
      }
      OrderItem oldOi = oldMap != null &&
        oi.Id != null
        ? oldMap.get(oi.Id)
        : null;
      if (
        oi.Is_Line_Deleted__c == true ||
        (oldOi != null &&
        oldOi.Is_Line_Deleted__c == true)
      ) {
        continue;
      }
      // Use the incoming termination reason only. Do not fall back to the old value
      // when the user clears Termination_Reason__c — otherwise EndDate stays bounded
      // and monthly payment sync never sees an open-ended transition.
      if (String.isNotBlank(oi.Termination_Reason__c)) {
        continue;
      }
      String accessType = String.isNotBlank(oi.Access_Type__c)
        ? oi.Access_Type__c
        : (oldOi != null ? oldOi.Access_Type__c : null);
      if (!'Monthly'.equals(accessType)) {
        continue;
      }
      // Replacement flow updates the replaced line to Removed + EndDate before the replacement row exists;
      // do not strip that curtailed end date.
      if ('Removed'.equals(oi.Change_Type__c)) {
        continue;
      }
      if (oi.Id != null && monthlyReplacedParentIds.contains(oi.Id)) {
        continue;
      }
      if (oi.EndDate != null) {
        oi.EndDate = null;
      }
    }
  }

  /**
   * Soft-delete: archive ServiceDate/EndDate to Original_* then clear live dates before rollups run.
   */
  private void archiveSoftDeletedLineDates(
    List<OrderItem> incomingItems,
    Map<Id, OrderItem> oldMap
  ) {
    if (incomingItems == null || incomingItems.isEmpty()) {
      return;
    }
    for (OrderItem oi : incomingItems) {
      if (oi == null || oi.Id == null) {
        continue;
      }
      OrderItem oldOi = oldMap != null ? oldMap.get(oi.Id) : null;
      Boolean nowDeleted = oi.Is_Line_Deleted__c == true;
      Boolean wasDeleted = oldOi != null && oldOi.Is_Line_Deleted__c == true;
      if (nowDeleted && !wasDeleted) {
        PackageBuilderService.applySoftDeleteDateArchive(oi);
      }
    }
  }

  private void alignServiceDateToEndDateForContractTermination(
    List<OrderItem> items
  ) {
    if (items == null || items.isEmpty())
      return;
    Set<Id> contractIds = new Set<Id>();
    for (OrderItem oi : items) {
      if (
        oi != null &&
        oi.Replaced_Order_Product__c == null &&
        oi.Contract__c != null &&
        oi.EndDate != null &&
        oi.ServiceDate != null &&
        oi.ServiceDate > oi.EndDate
      ) {
        contractIds.add(oi.Contract__c);
      }
    }
    if (contractIds.isEmpty())
      return;

    Map<Id, Contract> contractsById = new Map<Id, Contract>(
      [
        SELECT Id, Contract_Termination_Date__c
        FROM Contract
        WHERE Id IN :contractIds
      ]
    );
    for (OrderItem oi : items) {
      if (oi == null || oi.Contract__c == null)
        continue;
      // Replacement rows: Package Builder mirrors entry to the calendar day after the replaced
      // line's end; ServiceDate can legitimately be one day after this line's EndDate until
      // ends are adjusted — do not force ServiceDate down to EndDate here.
      if (oi.Replaced_Order_Product__c != null) {
        continue;
      }
      if (oi.EndDate == null || oi.ServiceDate == null)
        continue;
      if (oi.ServiceDate <= oi.EndDate)
        continue;
      Contract c = contractsById.get(oi.Contract__c);
      if (c == null || c.Contract_Termination_Date__c == null)
        continue;
      // Only auto-align when the contract is under a termination regime and the line is being curtailed.
      oi.ServiceDate = oi.EndDate;
    }
  }

  /**
   * @description Function for Trigger after insert relate to OrderItem
   * @param orderItemNMap orderItemNMap map from trigger.new
   **/
  public override void afterInsert(Map<Id, SObject> orderItemNMap) {
    try {
      Map<Id, OrderItem> allItems = (Map<Id, OrderItem>) orderItemNMap;

      // Payment generation should run for all working and active orders.
      // This covers Opportunity-flow draft orders (Closed Won) and replacement drafts.
      Map<Id, OrderItem> paymentEligibleItems = TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC
        ? new Map<Id, OrderItem>()
        : filterMonthlyPaymentEligibleOrderItems(allItems);

      if (
        !paymentEligibleItems.isEmpty() &&
        !paymentSyncInProgress &&
        !TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC
      ) {
        paymentSyncInProgress = true;
        try {
          ContractService.generateMonthlyPaymentsRelatedToOrderItems(
            paymentEligibleItems
          );
        } finally {
          paymentSyncInProgress = false;
        }
      }
      if (!paymentSyncInProgress) {
        syncParentOrderEndDates(collectOrderIds(allItems.values()), null);
      }
      ContractService.publishEvent();
      if (!isReplacementOnlyInsert(allItems)) {
        ExtraCreditOrderItemService.ensureExtraCreditLinesForFirstContractOrder(
          new List<OrderItem>(allItems.values())
        );
      }
      IterationService.copyFromOpportunityProducts(
        new List<OrderItem>(allItems.values())
      );
      RecurringPriceIncreaseService.copyFromOpportunityProducts(
        new List<OrderItem>(allItems.values())
      );
      IterationService.copyFromReplacedOrderProducts(
        new List<OrderItem>(allItems.values())
      );
    } catch (Exception e) {
      throw e;
    } finally {
    }
  }

  /**
   * @description Function for Trigger before delete relate to OrderItem
   * @param orderItemNMap orderItemNMap map from trigger.new
   **/
  public override void beforeDelete(Map<Id, SObject> orderItemNMap) {
    try {
      Map<Id, OrderItem> orderItemToDelete = (Map<Id, OrderItem>) orderItemNMap;
      ContractService.deleteAllMonthlyPaymentRelatedToOrderItem(
        orderItemToDelete
      );
    } catch (Exception e) {
      throw e;
    } finally {
    }
  }

  /**
   * @description Function for Trigger after update relate to OrderItem
   * @param triggerNewMap
   * @param triggerOldMap
   **/
  public override void afterUpdate(
    Map<Id, SObject> triggerNewMap,
    Map<Id, SObject> triggerOldMap
  ) {
    try {
      Map<Id, OrderItem> allNewItems = (Map<Id, OrderItem>) triggerNewMap;
      Map<Id, OrderItem> allOldItems = (Map<Id, OrderItem>) triggerOldMap;

      Map<Id, OrderItem> paymentCandidates = new Map<Id, OrderItem>();
      if (!TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC) {
        for (Id itemId : allNewItems.keySet()) {
          OrderItem neu = allNewItems.get(itemId);
          OrderItem old = allOldItems.get(itemId);
          if (monthlyPaymentSyncFieldsChanged(neu, old)) {
            paymentCandidates.put(itemId, neu);
          }
        }
      }
      Map<Id, OrderItem> paymentEligibleNew = paymentCandidates.isEmpty()
        ? new Map<Id, OrderItem>()
        : filterMonthlyPaymentEligibleOrderItems(paymentCandidates);
      if (
        !paymentEligibleNew.isEmpty() &&
        !paymentSyncInProgress &&
        !TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC
      ) {
        Map<Id, OrderItem> paymentEligibleOld = new Map<Id, OrderItem>();
        for (Id itemId : paymentEligibleNew.keySet()) {
          if (allOldItems.containsKey(itemId)) {
            paymentEligibleOld.put(itemId, allOldItems.get(itemId));
          }
        }
        paymentSyncInProgress = true;
        try {
          ContractService.deleteAllMonthlyPaymentNotRelevant(
            paymentEligibleNew,
            paymentEligibleOld
          );
          Set<Id> unitPriceChangedIds = new Set<Id>();
          for (Id itemId : paymentEligibleNew.keySet()) {
            OrderItem neu = paymentEligibleNew.get(itemId);
            OrderItem old = paymentEligibleOld.get(itemId);
            if (old == null || neu == null) {
              continue;
            }
            if (
              neu.UnitPrice != old.UnitPrice ||
              neu.Quantity != old.Quantity
            ) {
              unitPriceChangedIds.add(itemId);
            }
          }
          if (!unitPriceChangedIds.isEmpty()) {
            PackageBuilderService.refreshFinalAdjustedPriceForOrderItems(
              unitPriceChangedIds
            );
          }
        } finally {
          paymentSyncInProgress = false;
        }
      }
      if (
        !paymentSyncInProgress &&
        parentEndDateFieldsChanged(allNewItems, allOldItems)
      ) {
        syncParentOrderEndDates(
          collectOrderIds(allNewItems.values()),
          collectOrderIds(allOldItems.values())
        );
      }
    } catch (Exception e) {
      throw e;
    } finally {
    }
  }

  public override void afterDelete(Map<Id, SObject> triggerOldMap) {
    try {
      Map<Id, OrderItem> oldItems = (Map<Id, OrderItem>) triggerOldMap;
      syncParentOrderEndDates(null, collectOrderIds(oldItems.values()));
    } catch (Exception e) {
      throw e;
    } finally {
    }
  }

  /**
   * Monthly payments: allow for Active/Archived and working orders (Draft/Negotiation).
   * This ensures monthly payments are created for Opportunity-flow draft orders and
   * recalculated when dates are edited on draft order items.
   */
  private Map<Id, OrderItem> filterMonthlyPaymentEligibleOrderItems(
    Map<Id, OrderItem> items
  ) {
    Set<Id> orderIds = new Set<Id>();
    for (OrderItem oi : items.values()) {
      if (oi.OrderId != null)
        orderIds.add(oi.OrderId);
    }
    Set<Id> missingOrderIds = new Set<Id>();
    for (Id orderId : orderIds) {
      if (!parentOrderById.containsKey(orderId)) {
        missingOrderIds.add(orderId);
      }
    }
    if (!missingOrderIds.isEmpty()) {
      parentOrderById.putAll(
        new Map<Id, Order>(
          [
            SELECT Id, Status, Previous_Order__c
            FROM Order
            WHERE Id IN :missingOrderIds
          ]
        )
      );
    }
    Map<Id, Order> parentOrders = parentOrderById;
    Map<Id, OrderItem> eligible = new Map<Id, OrderItem>();
    for (OrderItem oi : items.values()) {
      if (!PackageBuilderService.isLineVisible(oi)) {
        continue;
      }
      Order parent = parentOrders.get(oi.OrderId);
      if (parent == null) {
        continue;
      }
      Boolean include = false;
      if (parent.Status == 'Activated' || parent.Status == 'Archived') {
        include = true;
      } else if (parent.Status == 'Draft' || parent.Status == 'Negotiation') {
        include = true;
      }
      if (include) {
        eligible.put(oi.Id, oi);
      }
    }
    return eligible;
  }

  /**
   * Contract Terms (Product2.Type__c == 'Contract Terms') stay open-ended on the OrderItem unless:
   * - the line is superseded (Change_Type__c = Removed during replace), or
   * - another order product on the same order already references this line via Replaced_Order_Product__c, or
   * - {@link #enterContractTermMeterEndDateNormalizeSuppress} is active for bulk termination/curtail DML.
   */
  private void normalizeContractTermMeterEndDates(
    List<OrderItem> incomingItems
  ) {
    if (incomingItems == null || incomingItems.isEmpty()) {
      return;
    }
    if (contractTermMeterEndDateNormalizeSuppressDepth > 0) {
      return;
    }

    Set<Id> pbeIds = new Set<Id>();
    for (OrderItem oi : incomingItems) {
      if (oi != null && oi.PricebookEntryId != null) {
        pbeIds.add(oi.PricebookEntryId);
      }
    }
    if (pbeIds.isEmpty()) {
      return;
    }

    Map<Id, String> productTypeByPbeId = new Map<Id, String>();
    for (PricebookEntry pbe : [
      SELECT Id, Product2.Type__c
      FROM PricebookEntry
      WHERE Id IN :pbeIds
    ]) {
      productTypeByPbeId.put(
        pbe.Id,
        pbe.Product2 != null ? pbe.Product2.Type__c : null
      );
    }

    Set<Id> meterLineIdsNeedingChildLookup = new Set<Id>();
    for (OrderItem oi : incomingItems) {
      if (oi == null || oi.Id == null) {
        continue;
      }
      if (
        !PRODUCT_TYPE_CONTRACT_TERMS.equals(
          productTypeByPbeId.get(oi.PricebookEntryId)
        )
      ) {
        continue;
      }
      if ('Removed'.equals(oi.Change_Type__c)) {
        continue;
      }
      meterLineIdsNeedingChildLookup.add(oi.Id);
    }

    Set<Id> meterLineIdsWithReplacementChild = new Set<Id>();
    if (!meterLineIdsNeedingChildLookup.isEmpty()) {
      for (OrderItem child : [
        SELECT Replaced_Order_Product__c
        FROM OrderItem
        WHERE
          Replaced_Order_Product__c IN :meterLineIdsNeedingChildLookup
          AND (Is_Line_Deleted__c = FALSE
          OR Is_Line_Deleted__c = NULL)
      ]) {
        if (child.Replaced_Order_Product__c != null) {
          meterLineIdsWithReplacementChild.add(child.Replaced_Order_Product__c);
        }
      }
    }

    for (OrderItem oi : incomingItems) {
      if (oi == null) {
        continue;
      }
      if (
        !PRODUCT_TYPE_CONTRACT_TERMS.equals(
          productTypeByPbeId.get(oi.PricebookEntryId)
        )
      ) {
        continue;
      }
      if ('Removed'.equals(oi.Change_Type__c)) {
        continue;
      }
      if (oi.Id != null && meterLineIdsWithReplacementChild.contains(oi.Id)) {
        continue;
      }
      if (oi.EndDate != null) {
        oi.EndDate = null;
      }
    }
  }

  private void syncStartAndEntryDates(
    List<OrderItem> incomingItems,
    Map<Id, OrderItem> oldMap
  ) {
    if (SKIP_DATE_SYNC)
      return;
    if (incomingItems == null || incomingItems.isEmpty())
      return;
    Boolean hasEntryDateOverride = PackageBuilderAccessPolicy.hasEntryDateAdminOverride();
    Date todayDate = Date.today();

    Set<Id> orderIds = new Set<Id>();
    for (OrderItem oi : incomingItems) {
      if (oi.OrderId != null)
        orderIds.add(oi.OrderId);
    }
    if (orderIds.isEmpty())
      return;

    Map<Id, Order> ordersById = new Map<Id, Order>(
      [
        SELECT Id, Status, EffectiveDate, Order_Start_Date__c
        FROM Order
        WHERE Id IN :orderIds
      ]
    );

    for (OrderItem oi : incomingItems) {
      Order parent = ordersById.get(oi.OrderId);
      if (parent == null || parent.Status != 'Draft')
        continue;
      OrderItem oldItem = oldMap != null ? oldMap.get(oi.Id) : null;

      Date parentOrderStart = parent.Order_Start_Date__c != null
        ? parent.Order_Start_Date__c
        : parent.EffectiveDate;

      Boolean isExistingLine =
        oi.Original_Order_Product__c != null &&
        oi.Change_Type__c != 'New';
      Boolean isNewOrReplacement =
        oi.Change_Type__c == 'New' ||
        oi.Replaced_Order_Product__c != null ||
        oi.Original_Order_Product__c == null;

      if (isExistingLine) {
        // Preserve copied entry date from the previous active order.
        // Existing lines should not be auto-shifted to parent order start.
        if (
          !hasEntryDateOverride &&
          oldItem != null &&
          oi.ServiceDate != oldItem.ServiceDate
        ) {
          if (
            (oldItem.ServiceDate != null && oldItem.ServiceDate < todayDate) ||
            (oi.ServiceDate != null &&
            oi.ServiceDate < todayDate)
          ) {
            oi.ServiceDate.addError(
              System.Label.PackageBuilder_StartDate_PastEditError
            );
          }
        }
        continue;
      }

      if (!isNewOrReplacement)
        continue;

      Date startDate;
      if (oi.Replaced_Order_Product__c != null) {
        startDate = oi.ServiceDate;
        if (startDate == null && oldMap != null && oldMap.containsKey(oi.Id)) {
          startDate = oldMap.get(oi.Id).ServiceDate;
        }
      } else if (oldItem != null) {
        startDate = oi.ServiceDate;
        if (startDate == null) {
          startDate = oldItem.ServiceDate;
        }
      } else {
        startDate = oi.ServiceDate;
      }

      Boolean isSoftDeletedLine =
        oi.Is_Line_Deleted__c == true ||
        (oldItem != null &&
        oldItem.Is_Line_Deleted__c == true);
      if (isSoftDeletedLine) {
        continue;
      }
      if (
        startDate != null &&
        parentOrderStart != null &&
        startDate < parentOrderStart
      ) {
        oi.ServiceDate.addError(
          'Product start date cannot be earlier than Contract Start Date (' +
            String.valueOf(parentOrderStart) +
            ').'
        );
        continue;
      }

      if (startDate != null) {
        oi.ServiceDate = startDate;
      }
    }
  }

  /**
   * Parent order end-date rule:
   * - If any line has blank EndDate, parent EndDate must be blank (open-ended wins).
   * - Otherwise parent EndDate is the latest line EndDate.
   */
  private Set<Id> collectOrderIds(List<OrderItem> items) {
    Set<Id> orderIds = new Set<Id>();
    if (items == null) {
      return orderIds;
    }
    for (OrderItem oi : items) {
      if (oi != null && oi.OrderId != null) {
        orderIds.add(oi.OrderId);
      }
    }
    return orderIds;
  }

  /**
   * Before line save, extend Contract and Order so platform rules allow the incoming line EndDate(s).
   * Uses lightweight aggregates (not a full in-memory line merge) to avoid SOQL limits when flows
   * re-enter this path while syncing monthly payments.
   * Only pushes package/contract **forward**; shrink/clear runs in {@link #syncParentOrderEndDates}.
   * Skips parent Order DML when the rolled-forward target is still before the pre-commit line MAX(EndDate)
   * (subset curtail / same-transaction timing) so Salesforce does not reject the Order update.
   */
  private void ensureContractAndOrderCoverIncomingLineEndDates(
    List<OrderItem> incomingItems,
    Map<Id, OrderItem> oldMap
  ) {
    if (
      SKIP_DATE_SYNC ||
      extendingPackageDatesFromLines ||
      incomingItems == null ||
      incomingItems.isEmpty()
    ) {
      return;
    }
    Set<Id> orderIds = new Set<Id>();
    Set<Id> incomingLineIds = new Set<Id>();
    Map<Id, Date> maxIncomingEndByOrderId = new Map<Id, Date>();
    for (OrderItem oi : incomingItems) {
      if (oi == null || oi.OrderId == null) {
        continue;
      }
      Boolean consider = false;
      if (oldMap == null) {
        consider = true;
      } else {
        OrderItem oldOi = oldMap.get(oi.Id);
        if (oldOi == null) {
          consider = true;
        } else if (
          oi.EndDate != oldOi.EndDate ||
          oi.ServiceDate != oldOi.ServiceDate
        ) {
          consider = true;
        }
      }
      if (!consider) {
        continue;
      }
      orderIds.add(oi.OrderId);
      if (oi.Id != null) {
        incomingLineIds.add(oi.Id);
      }
      if (oi.EndDate != null && PackageBuilderService.isPackageRollupLine(oi)) {
        Date cur = maxIncomingEndByOrderId.get(oi.OrderId);
        if (cur == null || oi.EndDate > cur) {
          maxIncomingEndByOrderId.put(oi.OrderId, oi.EndDate);
        }
      }
    }
    if (orderIds.isEmpty()) {
      return;
    }

    // Open-ended parent when any included (non–Contract-Terms) line has blank EndDate — do not force package end here.
    Set<Id> ordersWithBlankIncludedEndDate = new Set<Id>();
    for (AggregateResult ar : [
      SELECT OrderId oid, COUNT(Id) totalCount, COUNT(EndDate) endCount
      FROM OrderItem
      WHERE
        OrderId IN :orderIds
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      GROUP BY OrderId
    ]) {
      Id oid = (Id) ar.get('oid');
      if (oid == null) {
        continue;
      }
      Integer totalCount = (Integer) ar.get('totalCount');
      Integer endCount = (Integer) ar.get('endCount');
      if (endCount < totalCount) {
        ordersWithBlankIncludedEndDate.add(oid);
      }
    }

    Map<Id, Date> maxOtherBoundedEndByOrderId = new Map<Id, Date>();
    if (!incomingLineIds.isEmpty()) {
      for (AggregateResult ar : [
        SELECT OrderId oid, MAX(EndDate) maxEnd
        FROM OrderItem
        WHERE
          OrderId IN :orderIds
          AND Id NOT IN :incomingLineIds
          AND EndDate != NULL
          AND (Is_Line_Deleted__c = FALSE
          OR Is_Line_Deleted__c = NULL)
          AND (Product2.Type__c = NULL
          OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
        GROUP BY OrderId
      ]) {
        Id oid = (Id) ar.get('oid');
        Date maxEnd = (Date) ar.get('maxEnd');
        if (oid != null && maxEnd != null) {
          maxOtherBoundedEndByOrderId.put(oid, maxEnd);
        }
      }
    } else {
      for (AggregateResult ar : [
        SELECT OrderId oid, MAX(EndDate) maxEnd
        FROM OrderItem
        WHERE
          OrderId IN :orderIds
          AND EndDate != NULL
          AND (Is_Line_Deleted__c = FALSE
          OR Is_Line_Deleted__c = NULL)
          AND (Product2.Type__c = NULL
          OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
        GROUP BY OrderId
      ]) {
        Id oid = (Id) ar.get('oid');
        Date maxEnd = (Date) ar.get('maxEnd');
        if (oid != null && maxEnd != null) {
          maxOtherBoundedEndByOrderId.put(oid, maxEnd);
        }
      }
    }

    // Pre-commit MAX(EndDate) across all lines on each order (SOQL sees old values for rows in this trigger).
    // Used to avoid updating Order.EndDate inside before-update to a date that is still earlier than DB line
    // ends (FIELD_INTEGRITY: Order end cannot be earlier than product ends). After commit,
    // {@link #syncParentOrderEndDates} rolls Order/Contract to the true max including this DML.
    Map<Id, Date> persistedMaxLineEndByOrderId = new Map<Id, Date>();
    for (AggregateResult ar : [
      SELECT OrderId oid, MAX(EndDate) maxEnd
      FROM OrderItem
      WHERE
        OrderId IN :orderIds
        AND EndDate != NULL
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      GROUP BY OrderId
    ]) {
      Id oid = (Id) ar.get('oid');
      Date maxEnd = (Date) ar.get('maxEnd');
      if (oid != null && maxEnd != null) {
        persistedMaxLineEndByOrderId.put(oid, maxEnd);
      }
    }

    List<Order> parentOrders = [
      SELECT Id, EndDate, Status, ContractId
      FROM Order
      WHERE Id IN :orderIds AND Status NOT IN ('Cancelled', 'Archived')
    ];
    Map<Id, Date> parentOrderEndById = new Map<Id, Date>();
    for (Order po : parentOrders) {
      if (po.EndDate != null) {
        parentOrderEndById.put(po.Id, po.EndDate);
      }
    }
    for (OrderItem oi : incomingItems) {
      if (oi == null || oi.OrderId == null) {
        continue;
      }
      Boolean considerSd = false;
      if (oldMap == null) {
        considerSd = true;
      } else {
        OrderItem oldOiSd = oldMap.get(oi.Id);
        if (oldOiSd == null) {
          considerSd = true;
        } else if (
          oi.EndDate != oldOiSd.EndDate ||
          oi.ServiceDate != oldOiSd.ServiceDate
        ) {
          considerSd = true;
        }
      }
      if (!considerSd) {
        continue;
      }
      Date parentEnd = parentOrderEndById.get(oi.OrderId);
      if (
        parentEnd != null &&
        oi.ServiceDate != null &&
        oi.ServiceDate > parentEnd
      ) {
        Date curSd = maxIncomingEndByOrderId.get(oi.OrderId);
        if (curSd == null || oi.ServiceDate > curSd) {
          maxIncomingEndByOrderId.put(oi.OrderId, oi.ServiceDate);
        }
      }
    }

    List<Order> ordersToUpdate = new List<Order>();
    for (Order ord : parentOrders) {
      if (ordersWithBlankIncludedEndDate.contains(ord.Id)) {
        continue;
      }
      Date incomingMax = maxIncomingEndByOrderId.get(ord.Id);
      Date otherMax = maxOtherBoundedEndByOrderId.get(ord.Id);
      Date targetEnd = incomingMax;
      if (otherMax != null && (targetEnd == null || otherMax > targetEnd)) {
        targetEnd = otherMax;
      }
      Boolean needExtend =
        targetEnd != null && (ord.EndDate == null || targetEnd > ord.EndDate);
      if (needExtend) {
        Date persistedLineMax = persistedMaxLineEndByOrderId.get(ord.Id);
        if (persistedLineMax != null && targetEnd < persistedLineMax) {
          continue;
        }
        ord.EndDate = targetEnd;
        ordersToUpdate.add(ord);
      }
    }
    if (ordersToUpdate.isEmpty()) {
      return;
    }
    extendingPackageDatesFromLines = true;
    try {
      PackageEndDateRollupService.extendContractsToCoverOrderEndDates(
        ordersToUpdate
      );
      update ordersToUpdate;
    } finally {
      extendingPackageDatesFromLines = false;
    }
  }

  private static Set<Id> collectContractIdsFromOrders(List<Order> orders) {
    Set<Id> ids = new Set<Id>();
    if (orders == null) {
      return ids;
    }
    for (Order o : orders) {
      if (o != null && o.ContractId != null) {
        ids.add(o.ContractId);
      }
    }
    return ids;
  }

  private static Boolean isReplacementOnlyInsert(Map<Id, OrderItem> items) {
    if (items == null || items.isEmpty()) {
      return false;
    }
    for (OrderItem oi : items.values()) {
      if (oi == null || oi.Replaced_Order_Product__c == null) {
        return false;
      }
    }
    return true;
  }

  private static Boolean parentEndDateFieldsChanged(
    Map<Id, OrderItem> newItems,
    Map<Id, OrderItem> oldItems
  ) {
    if (newItems == null || newItems.isEmpty()) {
      return false;
    }
    for (Id itemId : newItems.keySet()) {
      OrderItem neu = newItems.get(itemId);
      OrderItem old = oldItems == null ? null : oldItems.get(itemId);
      if (neu == null) {
        continue;
      }
      if (old == null) {
        return true;
      }
      if (
        neu.ServiceDate != old.ServiceDate ||
        neu.EndDate != old.EndDate ||
        neu.OrderId != old.OrderId ||
        neu.Is_Line_Deleted__c != old.Is_Line_Deleted__c
      ) {
        return true;
      }
    }
    return false;
  }

  private static Boolean monthlyPaymentSyncFieldsChanged(
    OrderItem neu,
    OrderItem old
  ) {
    if (neu == null) {
      return false;
    }
    if (old == null) {
      return true;
    }
    return neu.ServiceDate != old.ServiceDate ||
      neu.EndDate != old.EndDate ||
      neu.Access_Type__c != old.Access_Type__c ||
      neu.Change_Action_Type__c != old.Change_Action_Type__c ||
      neu.Change_Action_Effective_End_Date__c !=
      old.Change_Action_Effective_End_Date__c ||
      neu.Termination_Reason__c != old.Termination_Reason__c ||
      neu.UnitPrice != old.UnitPrice ||
      neu.Quantity != old.Quantity ||
      neu.Change_Type__c != old.Change_Type__c;
  }

  public static void beginDeferredParentEndDateSync() {
    deferParentEndDateSync = true;
  }

  public static void cancelDeferredParentEndDateSync() {
    deferParentEndDateSync = false;
    deferredParentEndDateOrderIds.clear();
  }

  public static void endDeferredParentEndDateSync() {
    deferParentEndDateSync = false;
    if (deferredParentEndDateOrderIds.isEmpty()) {
      return;
    }
    Set<Id> orderIds = new Set<Id>(deferredParentEndDateOrderIds);
    deferredParentEndDateOrderIds.clear();
    new OrderItemTriggerHandler().syncParentOrderEndDates(orderIds, null);
  }

  private void syncParentOrderEndDates(
    Set<Id> newOrderIds,
    Set<Id> oldOrderIds
  ) {
    if (SKIP_DATE_SYNC || parentEndDateSyncInProgress) {
      return;
    }
    Set<Id> orderIds = new Set<Id>();
    if (newOrderIds != null) {
      orderIds.addAll(newOrderIds);
    }
    if (oldOrderIds != null) {
      orderIds.addAll(oldOrderIds);
    }
    if (orderIds.isEmpty()) {
      return;
    }
    if (deferParentEndDateSync) {
      deferredParentEndDateOrderIds.addAll(orderIds);
      return;
    }

    parentEndDateSyncInProgress = true;
    try {
      syncParentOrderEndDatesUnguarded(orderIds);
    } finally {
      parentEndDateSyncInProgress = false;
    }
  }

  private void syncParentOrderEndDatesUnguarded(Set<Id> orderIds) {
    Map<Id, Date> maxEndByOrderId = new Map<Id, Date>();
    Set<Id> ordersWithBlankIncludedEndDate = new Set<Id>();
    // Special rule: Contract Terms (Product2.Type__c == 'Contract Terms') with blank EndDate
    // must NOT force parent orders to become open-ended. Only included (non-Contract-Terms) blank EndDates do.
    List<AggregateResult> includedOpenEndedAggregates = [
      SELECT OrderId oid, COUNT(Id) totalCount, COUNT(EndDate) endCount
      FROM OrderItem
      WHERE
        OrderId IN :orderIds
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      GROUP BY OrderId
    ];
    for (AggregateResult ar : includedOpenEndedAggregates) {
      Id oid = (Id) ar.get('oid');
      if (oid == null)
        continue;
      Integer totalCount = (Integer) ar.get('totalCount');
      Integer endCount = (Integer) ar.get('endCount');
      if (endCount < totalCount) {
        ordersWithBlankIncludedEndDate.add(oid);
      }
    }

    // Max end date across visible non–Contract-Terms bounded lines only.
    List<AggregateResult> maxEndAggregates = [
      SELECT OrderId oid, MAX(EndDate) maxEnd
      FROM OrderItem
      WHERE
        OrderId IN :orderIds
        AND EndDate != NULL
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      GROUP BY OrderId
    ];
    for (AggregateResult ar : maxEndAggregates) {
      Id oid = (Id) ar.get('oid');
      Date maxEnd = (Date) ar.get('maxEnd');
      if (oid == null)
        continue;
      if (maxEnd != null) {
        maxEndByOrderId.put(oid, maxEnd);
      }
    }

    List<Order> ordersToUpdate = new List<Order>();
    // Ignore Cancelled/Archived orders for parent EndDate rollup.
    // These historical orders can have line EndDates beyond a shortened Contract.EndDate,
    // and rolling them up would violate downstream contract/order integrity rules.
    List<Order> parentOrders = [
      SELECT Id, EndDate, Status, ContractId
      FROM Order
      WHERE Id IN :orderIds AND Status NOT IN ('Cancelled', 'Archived')
    ];
    for (Order ord : parentOrders) {
      Date targetEndDate = ordersWithBlankIncludedEndDate.contains(ord.Id)
        ? null
        : maxEndByOrderId.get(ord.Id);
      if (ord.EndDate != targetEndDate) {
        ord.EndDate = targetEndDate;
        ordersToUpdate.add(ord);
      }
    }
    if (!ordersToUpdate.isEmpty()) {
      PackageEndDateRollupService.extendContractsToCoverOrderEndDates(
        ordersToUpdate
      );
      update ordersToUpdate;
      PackageEndDateRollupService.alignContractEndsToOrderPackageRollups(
        collectContractIdsFromOrders(ordersToUpdate)
      );
    }
  }
}
