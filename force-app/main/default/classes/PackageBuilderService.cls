// WI-000168: Date-based renewal discount, removed Current_Iteration__c dependency
public without sharing class PackageBuilderService {
  /** Auto-renew: skip OI Iteration clone on draft create; renew service copies remaining rows. */
  public static Boolean skipIterationCopyOnDraftClone = false;
  /** Auto-renew: payments already backfilled before Activate. */
  public static Boolean skipActivatePaymentBackfill = false;

  private static final String PRODUCT_TYPE_CONTRACT_TERMS = 'Contract Terms';

  /**
   * Package Builder visible line: unchecked/null Is_Line_Deleted__c. Soft-deleted lines stay in DB for payments and cloning.
   */
  public static Boolean isLineVisible(OrderItem oi) {
    return isLineVisible((SObject) oi);
  }

  public static Boolean isLineVisible(SObject lineItem) {
    if (
      lineItem == null ||
      lineItem.getSObjectType() != OrderItem.SObjectType
    ) {
      return true;
    }
    if (!lineItem.getPopulatedFieldsAsMap().containsKey('Is_Line_Deleted__c')) {
      return true;
    }
    return (Boolean) lineItem.get('Is_Line_Deleted__c') != true;
  }

  /**
   * Other-site Temporary rule: product has a location and it differs from the
   * parent (Order or Opportunity) location. Blank product location is not other-site.
   */
  public static Boolean isOtherSiteProduct(
    Id productLocationId,
    Id orderLocationId
  ) {
    return productLocationId != null &&
      orderLocationId != null &&
      productLocationId != orderLocationId;
  }

  /** Order Summary KPI inclusion: visible, not Temporary, EndDate null or >= today. */
  public static Boolean isIncludedInOrderSummary(OrderItem item) {
    if (item == null || !isLineVisible(item)) {
      return false;
    }
    if (item.Temporary__c == true) {
      return false;
    }
    if (item.EndDate != null && item.EndDate < Date.today()) {
      return false;
    }
    return true;
  }

  /**
   * When a line is soft-deleted, archive live dates to Original_* then clear ServiceDate/EndDate
   * so package rollups and platform validation ignore the row while payments stay on the OrderItem Id.
   */
  public static void applySoftDeleteDateArchive(OrderItem oi) {
    if (oi == null) {
      return;
    }
    if (oi.ServiceDate != null) {
      oi.Original_Start_Date__c = oi.ServiceDate;
    }
    if (oi.EndDate != null) {
      oi.Original_End_Date__c = oi.EndDate;
      oi.put('EndDate', null);
    }
    oi.ServiceDate = null;
  }

  /**
   * Permanently removes OrderItems and their Monthly Payments.
   * MonthlyPayment__c.OrderItem__c is a SetNull lookup, so payments must be
   * deleted explicitly before their parent lines.
   */
  public static Set<Id> hardDeleteLinesWithPayments(List<OrderItem> lines) {
    Set<Id> requestedIds = new Set<Id>();
    if (lines != null) {
      for (OrderItem oi : lines) {
        if (oi != null && oi.Id != null) {
          requestedIds.add(oi.Id);
        }
      }
    }
    if (requestedIds.isEmpty()) {
      return requestedIds;
    }

    List<OrderItem> persistedLines = [
      SELECT Id
      FROM OrderItem
      WHERE Id IN :requestedIds
    ];
    Set<Id> persistedIds = new Map<Id, OrderItem>(persistedLines).keySet();
    if (persistedIds.isEmpty()) {
      return persistedIds;
    }

    List<MonthlyPayment__c> payments = [
      SELECT Id
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :persistedIds
    ];
    if (!payments.isEmpty()) {
      delete payments;
    }
    delete persistedLines;
    return persistedIds;
  }

  /** Live date when present; archived Original_* for soft-deleted backend rows. */
  @TestVisible
  private static Date effectiveArchivedLineStart(OrderItem oi) {
    if (oi == null) {
      return null;
    }
    return oi.ServiceDate != null ? oi.ServiceDate : oi.Original_Start_Date__c;
  }

  @TestVisible
  private static Date effectiveArchivedLineEnd(OrderItem oi) {
    if (oi == null) {
      return null;
    }
    return oi.EndDate != null ? oi.EndDate : oi.Original_End_Date__c;
  }

  @TestVisible
  private static Boolean isContractTermsLineItem(SObject lineItem) {
    if (lineItem == null) {
      return false;
    }
    try {
      SObject p2 = lineItem.getSObject('Product2');
      String pt = p2 != null ? (String) p2.get('Type__c') : null;
      return PRODUCT_TYPE_CONTRACT_TERMS.equals(pt);
    } catch (System.SObjectException e) {
      return false;
    }
  }

  /** Visible standard-product lines that drive package/order end rollups (not Contract Terms). */
  public static Boolean isPackageRollupLine(OrderItem oi) {
    if (oi == null || !isLineVisible(oi)) {
      return false;
    }
    return !isContractTermsLineItem(oi);
  }

  /** Both Product2 and PricebookEntry must be active to copy a line into a new draft. */
  @TestVisible
  private static Boolean isCatalogLineActive(OrderItem item) {
    if (item == null) {
      return false;
    }
    return item.Product2 != null &&
      item.Product2.IsActive == true &&
      item.PricebookEntry != null &&
      item.PricebookEntry.IsActive == true;
  }

  /**
   * @description : Generates monthly payments for the OpportunityLineItems provided in the map.
   **/
  public static void generateMonthlyPaymentsRelatedToOppLineItems(
    Map<Id, OpportunityLineItem> oppLineItemsMap
  ) {
    List<MonthlyPayment__c> allPayments = new List<MonthlyPayment__c>();

    Map<Id, SObject> relevantItems = getRelevantItems(
      oppLineItemsMap.values(),
      null,
      'OpportunityLineItem'
    );
    if (relevantItems.isEmpty())
      return;

    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings.size() > 0 &&
      mpSettings[0].NumberOfMonths__c != null
      ? Integer.valueOf(mpSettings[0].NumberOfMonths__c)
      : 12;

    List<OpportunityLineItem> itemsRetrieve = [
      SELECT
        Id,
        Entry_Date__c,
        End_Date__c,
        ListPrice,
        OpportunityId,
        Product2Id,
        Product2.Name,
        Product2.Type__c,
        Access_Type__c,
        Original_Contract_Product__c
      FROM OpportunityLineItem
      WHERE Id IN :relevantItems.keySet()
    ];

    Map<Id, List<MonthlyPayment__c>> oliToOrderItemMap = getOliToOrderItemMonthlyPaymentsMap(
      itemsRetrieve
    );

    RecurringPriceIncreaseService.preloadLines(relevantItems.keySet());

    for (OpportunityLineItem lineItem : itemsRetrieve) {
      List<MonthlyPayment__c> paymentsToCopy = oliToOrderItemMap.get(
        lineItem.Id
      );
      allPayments.addAll(
        generateMonthlyPaymentsForLineItem(
          lineItem,
          lineItem.Entry_Date__c,
          numberOfMonths,
          paymentsToCopy,
          true
        )
      );
    }

    if (!allPayments.isEmpty())
      insert allPayments;
  }

  /**
   * @description : Generates monthly payments for OrderItems.
   **/
  public static void generateMonthlyPaymentsRelatedToOrderItems(
    Map<Id, OrderItem> orderItemsMap
  ) {
    List<MonthlyPayment__c> allPayments = new List<MonthlyPayment__c>();

    Map<Id, SObject> relevantItems = getRelevantItems(
      orderItemsMap.values(),
      null,
      'OrderItem'
    );
    if (relevantItems.isEmpty())
      return;

    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings.size() > 0 &&
      mpSettings[0].NumberOfMonths__c != null
      ? Integer.valueOf(mpSettings[0].NumberOfMonths__c)
      : 12;

    List<OrderItem> itemsRetrieve = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        OrderId,
        Product2Id,
        Contract__c,
        Order.OpportunityId,
        Order.Status,
        Product2.Name,
        Product2.Type__c,
        Access_Type__c
      FROM OrderItem
      WHERE Id IN :relevantItems.keySet()
    ];

    Set<Id> orderItemIds = new Set<Id>();
    for (OrderItem item : itemsRetrieve) {
      orderItemIds.add(item.Id);
    }

    RecurringPriceIncreaseService.preloadLines(orderItemIds);

    for (OrderItem item : itemsRetrieve) {
      Integer monthCount = PackageBuilderAccessTypePolicy.isMonthlyLike(
          item.Access_Type__c
        ) || PackageBuilderAccessTypePolicy.isUsageBased(item.Access_Type__c)
        ? orderItemMonthlyPaymentCount(
            item.ServiceDate,
            item.EndDate,
            item.Order.Status
          )
        : numberOfMonths;
      allPayments.addAll(
        generateMonthlyPaymentsForLineItem(
          item,
          item.ServiceDate,
          monthCount,
          null,
          false
        )
      );
    }

    if (!allPayments.isEmpty()) {
      insert allPayments;
      syncOrderItemPriceRollups(orderItemIds);
    }
  }

  private static Map<Id, List<MonthlyPayment__c>> getOliToOrderItemMonthlyPaymentsMap(
    List<OpportunityLineItem> oppLineRetrieve
  ) {
    List<Id> contractProductList = new List<Id>();
    Map<Id, Id> orderItemIdToOliId = new Map<Id, Id>();
    for (OpportunityLineItem oppItem : oppLineRetrieve) {
      if (oppItem.Original_Contract_Product__c != null) {
        contractProductList.add(oppItem.Original_Contract_Product__c);
        orderItemIdToOliId.put(
          oppItem.Original_Contract_Product__c,
          oppItem.Id
        );
      }
    }

    Map<Id, List<MonthlyPayment__c>> oliToOrderItemMap = new Map<Id, List<MonthlyPayment__c>>();
    if (!contractProductList.isEmpty()) {
      for (MonthlyPayment__c mp : [
        SELECT
          Id,
          OrderItem__c,
          Discount__c,
          Final_Adjusted_Price__c,
          Stat_Date_Trigger__c,
          End_Date_trigger__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c IN :contractProductList
        ORDER BY MonthIndex__c ASC
      ]) {
        Id oliId = orderItemIdToOliId.get(mp.OrderItem__c);
        if (!oliToOrderItemMap.containsKey(oliId))
          oliToOrderItemMap.put(oliId, new List<MonthlyPayment__c>());
        oliToOrderItemMap.get(oliId).add(mp);
      }
    }
    return oliToOrderItemMap;
  }

  private static Decimal getRenewalDiscountForDate(
    Id itemId,
    Date targetDate,
    Boolean isOli
  ) {
    // Consult active recurring price-increase rule (user layer = 0 on create).
    return RecurringPriceIncreaseService.resolveDiscount(itemId, targetDate, 0);
  }

  /**
   * Rebuilds monthly payments when visible OrderItem dates change outside the trigger path
   * (e.g. parent end-date restoration after replacement delete while sync is suppressed).
   */
  public static void syncMonthlyPaymentsForVisibleOrderItemDateChanges(
    Map<Id, OrderItem> oldItemsById
  ) {
    if (oldItemsById == null || oldItemsById.isEmpty()) {
      return;
    }
    Map<Id, OrderItem> newItemsById = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          Is_Line_Deleted__c,
          Access_Type__c,
          Termination_Reason__c,
          Change_Action_Type__c,
          Change_Action_Effective_End_Date__c
        FROM OrderItem
        WHERE Id IN :oldItemsById.keySet()
      ]
    );
    Map<Id, OrderItem> eligibleNew = new Map<Id, OrderItem>();
    Map<Id, OrderItem> eligibleOld = new Map<Id, OrderItem>();
    for (Id itemId : oldItemsById.keySet()) {
      OrderItem oldOi = oldItemsById.get(itemId);
      OrderItem newOi = newItemsById.get(itemId);
      if (oldOi == null || newOi == null || newOi.Is_Line_Deleted__c == true) {
        continue;
      }
      if (
        newOi.EndDate == oldOi.EndDate &&
        newOi.ServiceDate == oldOi.ServiceDate
      ) {
        continue;
      }
      eligibleNew.put(itemId, newOi);
      eligibleOld.put(itemId, oldOi);
    }
    if (!eligibleNew.isEmpty()) {
      ContractService.deleteAllMonthlyPaymentNotRelevant(
        eligibleNew,
        eligibleOld
      );
    }
  }

  /**
   * Backfills MonthlyPayment__c for lines with none, and add-only top-up for open-ended Monthly
   * lines whose forward horizon is short. Used on draft activation, drawer open, and PB saves.
   */
  public static void backfillMissingMonthlyPaymentsForOrderItems(
    Id orderId,
    List<Id> lineItemIds
  ) {
    if (orderId == null) {
      return;
    }
    Set<Id> filterIds = lineItemIds == null ? null : new Set<Id>(lineItemIds);
    if (filterIds != null && filterIds.isEmpty()) {
      return;
    }

    Set<Id> itemsWithPayments = new Set<Id>();
    if (filterIds == null) {
      for (MonthlyPayment__c mp : [
        SELECT OrderItem__c
        FROM MonthlyPayment__c
        WHERE OrderItem__r.OrderId = :orderId AND OrderItem__c != NULL
      ]) {
        itemsWithPayments.add(mp.OrderItem__c);
      }
    } else {
      for (MonthlyPayment__c mp : [
        SELECT OrderItem__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c IN :filterIds
      ]) {
        itemsWithPayments.add(mp.OrderItem__c);
      }
    }

    List<OrderItem> candidateLines;
    if (filterIds == null) {
      candidateLines = [
        SELECT Id
        FROM OrderItem
        WHERE OrderId = :orderId
      ];
    } else {
      candidateLines = [
        SELECT Id
        FROM OrderItem
        WHERE Id IN :filterIds AND OrderId = :orderId
      ];
    }

    List<OrderItem> linesNeedingPayments = new List<OrderItem>();
    for (OrderItem ol : candidateLines) {
      if (!itemsWithPayments.contains(ol.Id)) {
        linesNeedingPayments.add(ol);
      }
    }
    if (!linesNeedingPayments.isEmpty()) {
      ContractService.generateMonthlyPaymentsRelatedToOrderItems(
        new Map<Id, OrderItem>(linesNeedingPayments)
      );
    }

    Set<Id> lineIdsWithPayments = new Set<Id>();
    for (OrderItem ol : candidateLines) {
      if (itemsWithPayments.contains(ol.Id)) {
        lineIdsWithPayments.add(ol.Id);
      }
    }
    if (!lineIdsWithPayments.isEmpty()) {
      List<OrderItem> linesForHorizonSync = [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          Access_Type__c,
          Termination_Reason__c,
          Contract__c,
          Contract__r.EndDate,
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
        WHERE Id IN :lineIdsWithPayments
      ];
      ContractService.syncOpenEndedMonthlyPaymentsAddOnly(linesForHorizonSync);
    }
  }

  /**
   * Ensures draft-order lines have monthly payments (drawer open safety net).
   */
  @AuraEnabled
  public static void ensureMonthlyPaymentsForLineItems(
    String orderId,
    List<String> lineItemIds
  ) {
    if (
      String.isBlank(orderId) ||
      lineItemIds == null ||
      lineItemIds.isEmpty()
    ) {
      return;
    }
    try {
      Id orderIdTyped = (Id) orderId;
      List<Order> orders = [
        SELECT Id, Status
        FROM Order
        WHERE Id = :orderIdTyped
        LIMIT 1
      ];
      if (orders.isEmpty()) {
        return;
      }
      String status = orders[0].Status;
      if (status != 'Draft' && status != 'Negotiation') {
        return;
      }

      Set<Id> requestedIds = new Set<Id>();
      for (String rawId : lineItemIds) {
        if (String.isNotBlank(rawId)) {
          requestedIds.add((Id) rawId);
        }
      }
      if (requestedIds.isEmpty()) {
        return;
      }

      List<OrderItem> lines = [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          Access_Type__c,
          Is_Line_Deleted__c,
          Product2.Type__c
        FROM OrderItem
        WHERE Id IN :requestedIds AND OrderId = :orderIdTyped
      ];

      List<Id> eligibleIds = new List<Id>();
      for (OrderItem oi : lines) {
        if (!isLineVisible(oi)) {
          continue;
        }
        if (isContractTermsLineItem(oi)) {
          continue;
        }
        if (PackageBuilderAccessTypePolicy.isPeriodicLike(oi.Access_Type__c)) {
          if (oi.ServiceDate == null || oi.EndDate == null) {
            continue;
          }
        }
        eligibleIds.add(oi.Id);
      }
      if (eligibleIds.isEmpty()) {
        return;
      }

      backfillMissingMonthlyPaymentsForOrderItems(orderIdTyped, eligibleIds);
      publishEvent();
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error ensuring monthly payments: ' + e.getMessage()
      );
    }
  }

  @AuraEnabled
  public static List<MonthlyPayment__c> getMonthlyPayments(
    String oppId,
    String contractId,
    String orderId
  ) {
    try {
      Date orderStartDate = null;
      String query =
        'SELECT Start_date__c, End_date__c, Price__c, FinalPrice__c, ListPrice__c, Access_Type__c, Products_Name__c, Monthly_Units__c, ' +
        'Discount__c, Id, LastModifiedDate, ' +
        'OpportunityLineItem__c, OrderItem__c, OrderItem__r.OrderId, OpportunityLineItem__r.Name, OpportunityLineItem__r.Quantity, ' +
        'OpportunityLineItem__r.ServiceDate, OpportunityLineItem__r.End_date__c, OpportunityLineItem__r.Recurring_Price_Increase_Enabled__c, OpportunityLineItem__r.Recurring_Increase_Start_Date__c, Opportunity__r.Start_Date__c, ' +
        'OrderItem__r.Quantity, OrderItem__r.ServiceDate, OrderItem__r.EndDate, ' +
        'OrderItem__r.Order.Order_Start_Date__c, OrderItem__r.Order.EffectiveDate, OrderItem__r.Recurring_Price_Increase_Enabled__c, OrderItem__r.Recurring_Increase_Start_Date__c, ' +
        'OrderItem__r.Calculated_List_Price_Adjustment__c, OpportunityLineItem__r.Calculated_List_Price_Adjustment__c, ' +
        'OpportunityLineItem__r.Aggregated_List_Price_Adjustment__c, ' +
        'OrderItem__r.Aggregated_List_Price_Adjustment__c ' +
        'FROM MonthlyPayment__c ';

      List<String> filters = new List<String>();
      if (String.isNotBlank(contractId)) {
        filters.add('Contract__c = :contractId');
        filters.add('Products_Name__c != null');
      } else if (String.isNotBlank(oppId)) {
        filters.add('Opportunity__c = :oppId');
      } else if (String.isNotBlank(orderId)) {
        filters.add('OrderItem__r.OrderId = :orderId');
        List<Order> ordRows = [
          SELECT Id, EffectiveDate, Order_Start_Date__c
          FROM Order
          WHERE Id = :orderId
          LIMIT 1
        ];
        if (!ordRows.isEmpty()) {
          Order ord = ordRows[0];
          orderStartDate = ord.Order_Start_Date__c != null
            ? ord.Order_Start_Date__c
            : ord.EffectiveDate;
        }
      } else {
        return new List<MonthlyPayment__c>();
      }
      filters.add('Start_date__c != null');
      if (orderStartDate != null) {
        // Keep the month containing order start date visible (split-month behavior).
        filters.add('End_date__c >= :orderStartDate');
      }

      if (!filters.isEmpty()) {
        query += 'WHERE ' + String.join(filters, ' AND ');
      }

      query += ' ORDER BY Start_date__c ASC';
      return Database.query(query);
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error fetching monthly payments: ' + e.getMessage()
      );
    }
  }

  public class SplitMonthDiscountMeta {
    @AuraEnabled
    public Id paymentId;
    @AuraEnabled
    public Boolean isSplitMonth;
    @AuraEnabled
    public Decimal oldDiscount;
    @AuraEnabled
    public Decimal enteredDiscount;
    @AuraEnabled
    public Decimal effectiveDiscount;
    @AuraEnabled
    public Integer preStartDays;
    @AuraEnabled
    public Integer postStartDays;
    @AuraEnabled
    public Integer totalDays;
    @AuraEnabled
    public Date orderStartDate;
  }

  @AuraEnabled
  public static Map<Id, SplitMonthDiscountMeta> getSplitMonthDiscountMetadata(
    List<Id> paymentIds
  ) {
    Map<Id, SplitMonthDiscountMeta> result = new Map<Id, SplitMonthDiscountMeta>();
    if (paymentIds == null || paymentIds.isEmpty()) {
      return result;
    }

    List<MonthlyPayment__c> rows = [
      SELECT
        Id,
        Discount__c,
        Start_date__c,
        End_date__c,
        OrderItem__r.Original_Order_Product__c,
        OrderItem__r.Replaced_Order_Product__c,
        OrderItem__r.Order.Order_Start_Date__c,
        OrderItem__r.Order.EffectiveDate
      FROM MonthlyPayment__c
      WHERE Id IN :paymentIds
    ];

    Set<Id> sourceOrderItemIds = new Set<Id>();
    Set<Date> monthStarts = new Set<Date>();
    for (MonthlyPayment__c mp : rows) {
      if (mp == null)
        continue;
      if (mp.Start_date__c != null) {
        monthStarts.add(mp.Start_date__c);
      }
      Id sourceOrderItemId = null;
      if (mp.OrderItem__r != null) {
        sourceOrderItemId = mp.OrderItem__r.Original_Order_Product__c != null
          ? mp.OrderItem__r.Original_Order_Product__c
          : mp.OrderItem__r.Replaced_Order_Product__c;
      }
      if (sourceOrderItemId != null) {
        sourceOrderItemIds.add(sourceOrderItemId);
      }
    }

    Map<String, Decimal> oldDiscountBySourceAndMonth = new Map<String, Decimal>();
    if (!sourceOrderItemIds.isEmpty() && !monthStarts.isEmpty()) {
      for (MonthlyPayment__c oldMp : [
        SELECT OrderItem__c, Start_date__c, Discount__c
        FROM MonthlyPayment__c
        WHERE
          OrderItem__c IN :sourceOrderItemIds
          AND Start_date__c IN :monthStarts
      ]) {
        if (oldMp.OrderItem__c == null || oldMp.Start_date__c == null)
          continue;
        oldDiscountBySourceAndMonth.put(
          String.valueOf(oldMp.OrderItem__c) +
            '|' +
            String.valueOf(oldMp.Start_date__c),
          oldMp.Discount__c
        );
      }
    }

    for (MonthlyPayment__c mp : rows) {
      SplitMonthDiscountMeta meta = new SplitMonthDiscountMeta();
      meta.paymentId = mp.Id;
      meta.effectiveDiscount = mp.Discount__c != null ? mp.Discount__c : 0;
      meta.enteredDiscount = meta.effectiveDiscount;
      meta.oldDiscount = meta.effectiveDiscount;
      meta.isSplitMonth = false;

      Date monthStart = mp.Start_date__c;
      Date monthEnd = mp.End_date__c;
      Date orderStart = mp.OrderItem__r != null &&
        mp.OrderItem__r.Order != null
        ? (mp.OrderItem__r.Order.Order_Start_Date__c != null
            ? mp.OrderItem__r.Order.Order_Start_Date__c
            : mp.OrderItem__r.Order.EffectiveDate)
        : null;
      meta.orderStartDate = orderStart;

      if (
        monthStart != null &&
        monthEnd != null &&
        orderStart != null &&
        monthStart < orderStart &&
        orderStart <= monthEnd
      ) {
        meta.isSplitMonth = true;
        Integer totalDays = monthStart.daysBetween(monthEnd) + 1;
        Integer preDays = monthStart.daysBetween(orderStart);
        Integer postDays = orderStart.daysBetween(monthEnd) + 1;
        meta.totalDays = totalDays;
        meta.preStartDays = preDays;
        meta.postStartDays = postDays;

        Id sourceOrderItemId = null;
        if (mp.OrderItem__r != null) {
          sourceOrderItemId = mp.OrderItem__r.Original_Order_Product__c != null
            ? mp.OrderItem__r.Original_Order_Product__c
            : mp.OrderItem__r.Replaced_Order_Product__c;
        }
        Decimal oldD = null;
        if (sourceOrderItemId != null && monthStart != null) {
          oldD = oldDiscountBySourceAndMonth.get(
            String.valueOf(sourceOrderItemId) + '|' + String.valueOf(monthStart)
          );
        }
        if (oldD == null) {
          oldD = meta.effectiveDiscount;
        }
        meta.oldDiscount = oldD;

        if (totalDays > 0 && postDays > 0) {
          Decimal entered =
            ((meta.effectiveDiscount * totalDays) - (oldD * preDays)) /
            postDays;
          meta.enteredDiscount = entered.setScale(
            6,
            System.RoundingMode.HALF_UP
          );
        }
      }
      result.put(mp.Id, meta);
    }
    return result;
  }

  @AuraEnabled
  public static Boolean updateDiscount(List<MonthlyPayment__c> payments) {
    try {
      if (payments == null || payments.isEmpty()) {
        return true;
      }
      MonthlyPaymentAdjustmentService.apply(
        MonthlyPaymentAdjustmentService.requestsFromPaymentUpdates(payments)
      );
      return true;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * Individual percentage adapter that keeps the exact value displayed and
   * entered by the user separate from split-month transport weighting.
   */
  @AuraEnabled
  public static Boolean updateDiscountWithEnteredPercentages(
    List<MonthlyPayment__c> payments,
    Map<Id, Decimal> enteredPercentageByPaymentId
  ) {
    try {
      if (payments == null || payments.isEmpty()) {
        return true;
      }
      MonthlyPaymentAdjustmentService.apply(
        MonthlyPaymentAdjustmentService.requestsFromPaymentUpdates(
          payments,
          enteredPercentageByPaymentId
        )
      );
      return true;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * Persistence adapter used only by MonthlyPaymentAdjustmentService for
   * Package Builder user saves. Task 1/2 system pricing paths continue to call
   * their existing methods directly.
   */
  public static void persistUserAdjustmentUpdates(
    List<MonthlyPayment__c> payments
  ) {
    validateAndNormalizeUsageBasedPaymentUpdates(payments);
    Set<Id> splitWeightedIds = applyOrderStartWeightedDiscounts(payments);
    RecurringPriceIncreaseService.applyUserLayerFromGridEdits(payments);
    explicitFinalAdjustedPriceIds.clear();
    for (MonthlyPayment__c p : payments) {
      if (
        p != null &&
        p.Id != null &&
        isUsableFinalAdjustedPrice(p.Final_Adjusted_Price__c) &&
        !splitWeightedIds.contains(p.Id)
      ) {
        explicitFinalAdjustedPriceIds.add(p.Id);
      }
    }
    Set<Id> explicitIds = new Set<Id>(explicitFinalAdjustedPriceIds);
    try {
      update payments;
      Set<Id> discountRefreshIds = new Set<Id>();
      for (MonthlyPayment__c p : payments) {
        if (p != null && p.Id != null && !explicitIds.contains(p.Id)) {
          discountRefreshIds.add(p.Id);
        }
      }
      refreshFinalAdjustedPriceForPaymentIds(discountRefreshIds);
    } finally {
      explicitFinalAdjustedPriceIds.clear();
    }

    // LWC often sends only Id + Discount__c; resolve OrderItem parents after DML.
    Set<Id> orderItemIds = new Set<Id>();
    Set<Id> paymentIds = new Set<Id>();
    for (MonthlyPayment__c p : payments) {
      if (p.OrderItem__c != null) {
        orderItemIds.add(p.OrderItem__c);
      }
      if (p.Id != null) {
        paymentIds.add(p.Id);
      }
    }
    if (!paymentIds.isEmpty()) {
      for (MonthlyPayment__c row : [
        SELECT OrderItem__c
        FROM MonthlyPayment__c
        WHERE Id IN :paymentIds
      ]) {
        if (row.OrderItem__c != null) {
          orderItemIds.add(row.OrderItem__c);
        }
      }
    }
    syncOrderItemPriceRollups(orderItemIds, true);
  }

  @TestVisible
  private static Set<Id> applyOrderStartWeightedDiscounts(
    List<MonthlyPayment__c> payments
  ) {
    Set<Id> weightedIds = new Set<Id>();
    if (payments == null || payments.isEmpty()) {
      return weightedIds;
    }
    Set<Id> paymentIds = new Set<Id>();
    for (MonthlyPayment__c p : payments) {
      if (p != null && p.Id != null) {
        paymentIds.add(p.Id);
      }
    }
    if (paymentIds.isEmpty()) {
      return weightedIds;
    }
    Map<Id, MonthlyPayment__c> existingById = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          Discount__c,
          Start_date__c,
          End_date__c,
          OrderItem__r.Order.Order_Start_Date__c,
          OrderItem__r.Order.EffectiveDate
        FROM MonthlyPayment__c
        WHERE Id IN :paymentIds
      ]
    );
    for (MonthlyPayment__c incoming : payments) {
      if (
        incoming == null ||
        incoming.Id == null ||
        incoming.Discount__c == null
      ) {
        continue;
      }
      MonthlyPayment__c existing = existingById.get(incoming.Id);
      if (existing == null) {
        continue;
      }
      Date monthStart = existing.Start_date__c;
      Date monthEnd = existing.End_date__c;
      Date orderStart = existing.OrderItem__r != null &&
        existing.OrderItem__r.Order != null
        ? (existing.OrderItem__r.Order.Order_Start_Date__c != null
            ? existing.OrderItem__r.Order.Order_Start_Date__c
            : existing.OrderItem__r.Order.EffectiveDate)
        : null;
      if (monthStart == null || monthEnd == null || orderStart == null) {
        continue;
      }
      if (!(monthStart < orderStart && orderStart <= monthEnd)) {
        continue;
      }
      Decimal weighted = computeWeightedDiscount(
        existing.Discount__c,
        incoming.Discount__c,
        monthStart,
        monthEnd,
        orderStart
      );
      incoming.Discount__c = weighted;
      weightedIds.add(incoming.Id);
    }
    return weightedIds;
  }

  @TestVisible
  private static Decimal toDiscountPercentPoints(Decimal discountRaw) {
    if (discountRaw == null) {
      return 0;
    }
    Decimal d = discountRaw;
    if (Math.abs(d) < 1 && d != 0) {
      return d * 100;
    }
    return d;
  }

  @TestVisible
  private static Decimal computeWeightedDiscount(
    Decimal oldDiscount,
    Decimal newDiscount,
    Date monthStart,
    Date monthEnd,
    Date orderStart
  ) {
    if (monthStart == null || monthEnd == null || orderStart == null) {
      return newDiscount;
    }
    if (!(monthStart < orderStart && orderStart <= monthEnd)) {
      return newDiscount;
    }
    Integer totalDays = monthStart.daysBetween(monthEnd) + 1;
    Integer preDays = monthStart.daysBetween(orderStart);
    Integer postDays = orderStart.daysBetween(monthEnd) + 1;
    if (totalDays <= 0 || preDays < 0 || postDays <= 0) {
      return newDiscount;
    }
    Decimal oldD = toDiscountPercentPoints(oldDiscount);
    Decimal newD = toDiscountPercentPoints(newDiscount);
    Decimal weighted = ((oldD * preDays) + (newD * postDays)) / totalDays;
    return weighted.setScale(6, System.RoundingMode.HALF_UP);
  }

  /**
   * Rolls up payable monthly line amounts to OrderItem from Price__c + Discount__c in Apex (same rules as
   * monthlyPaymentTable LWC). Intentionally does not use FinalPrice__c — formula fields can lag or be unavailable
   * in the same transaction as automation/trigger DML.
   * When Original_Price__c is null, sets both Original and Adjusted to the sum (first baseline).
   * Otherwise updates Adjusted_Total_Price__c only; Original_Price__c is never changed.
   * @param markFinancialAdjustmentIcon When true (Package Builder monthly save only), sets Show_Financial_Adjustment_Icon__c on affected order lines. Contract/date-driven rollups must pass false.
   */
  public static void syncOrderItemPriceRollups(Set<Id> orderItemIds) {
    syncOrderItemPriceRollups(orderItemIds, false);
  }

  public static void syncOrderItemPriceRollups(
    Set<Id> orderItemIds,
    Boolean markFinancialAdjustmentIcon
  ) {
    if (orderItemIds == null || orderItemIds.isEmpty()) {
      return;
    }
    Map<Id, Decimal> sumByOrderItem = new Map<Id, Decimal>();
    for (Id oid : orderItemIds) {
      sumByOrderItem.put(oid, 0);
    }
    for (MonthlyPayment__c mp : [
      SELECT
        OrderItem__c,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :orderItemIds
    ]) {
      if (mp.OrderItem__c == null) {
        continue;
      }
      Decimal lineAmt = monthlyPaymentLineAmount(mp);
      Decimal cur = sumByOrderItem.containsKey(mp.OrderItem__c)
        ? sumByOrderItem.get(mp.OrderItem__c)
        : 0;
      sumByOrderItem.put(mp.OrderItem__c, cur + lineAmt);
    }
    List<OrderItem> items = [
      SELECT
        Id,
        Original_Price__c,
        Adjusted_Total_Price__c,
        Show_Financial_Adjustment_Icon__c
      FROM OrderItem
      WHERE Id IN :orderItemIds
    ];
    List<OrderItem> toUpdate = new List<OrderItem>();
    Boolean markIcon = markFinancialAdjustmentIcon == true;
    for (OrderItem oi : items) {
      Decimal total = sumByOrderItem.containsKey(oi.Id)
        ? sumByOrderItem.get(oi.Id)
        : 0;
      Decimal roundedTotal = total.setScale(2, System.RoundingMode.HALF_UP);
      Boolean setIcon =
        markIcon && (oi.Show_Financial_Adjustment_Icon__c != true);
      OrderItem patch = new OrderItem(Id = oi.Id);
      Boolean changed = false;
      if (oi.Original_Price__c == null) {
        patch.Original_Price__c = roundedTotal;
        patch.Adjusted_Total_Price__c = roundedTotal;
        changed = true;
      } else if (
        priceDecimalsDiffer(oi.Adjusted_Total_Price__c, roundedTotal)
      ) {
        patch.Adjusted_Total_Price__c = roundedTotal;
        changed = true;
      }
      if (setIcon) {
        patch.Show_Financial_Adjustment_Icon__c = true;
        changed = true;
      }
      if (changed) {
        toUpdate.add(patch);
      }
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
  }

  /**
   * Same as {@link #syncOrderItemPriceRollups(Set<Id>, Boolean)}; {@code retryCount} is reserved for
   * {@link OrderItemPriceRollupRetryQueueable} and currently ignored (delegates to the two-argument overload).
   */
  public static void syncOrderItemPriceRollups(
    Set<Id> orderItemIds,
    Boolean markFinancialAdjustmentIcon,
    Integer retryCount
  ) {
    syncOrderItemPriceRollups(orderItemIds, markFinancialAdjustmentIcon);
  }

  /**
   * Line payable from Price__c and Discount__c (no formula fields).
   * - When absolute Discount__c is below 1, treat as Salesforce Percent fraction (0.05 = 5%, 0.01 = 1%, -0.12 = -12%).
   * - Otherwise treat as whole-number percent points (5 means 5/100, 100 means 100%).
   * Note: a stored value of exactly 1 is interpreted as 1% (1/100), not +100%; use 100 for a full doubling.
   */
  private static Decimal monthlyLinePayableAmount(
    Decimal price,
    Decimal discountRaw
  ) {
    Decimal p = price != null ? price : 0;
    Decimal d = discountRaw != null ? discountRaw : 0;
    Decimal rate = (Math.abs(d) < 1) ? d : (d / 100);
    return p * (1 + rate);
  }

  /**
   * Mirror FinalPrice__c: Usage Based → ListPrice; else prefer Final_Adjusted_Price__c when set;
   * else Price × (1 + Discount) with the same discount normalization as monthlyLinePayableAmount.
   */
  private static Decimal monthlyPaymentLineAmount(MonthlyPayment__c mp) {
    if (mp == null) {
      return 0;
    }
    if (PackageBuilderAccessTypePolicy.isUsageBased(mp.Access_Type__c)) {
      return mp.ListPrice__c != null ? mp.ListPrice__c : 0;
    }
    Map<String, Object> populated = mp.getPopulatedFieldsAsMap();
    if (populated.containsKey('Final_Adjusted_Price__c')) {
      Decimal fap = (Decimal) populated.get('Final_Adjusted_Price__c');
      if (isUsableFinalAdjustedPrice(fap)) {
        return fap;
      }
    }
    return monthlyLinePayableAmount(mp.Price__c, mp.Discount__c);
  }

  public static Boolean isUsableFinalAdjustedPrice(Decimal fap) {
    return fap != null && fap != 0;
  }

  /**
   * Derived Final Adjusted Price from current Price + Discount (non–Usage Based).
   * Returns null when Price is unavailable (e.g. before-insert before formula resolves).
   */
  @TestVisible
  private static Decimal deriveFinalAdjustedPriceFromDiscount(
    MonthlyPayment__c mp
  ) {
    if (
      mp == null ||
      PackageBuilderAccessTypePolicy.isUsageBased(mp.Access_Type__c)
    ) {
      return null;
    }
    if (mp.Price__c == null) {
      return null;
    }
    return monthlyLinePayableAmount(mp.Price__c, mp.Discount__c);
  }

  private static Boolean finalAdjustedPriceSyncInProgress = false;
  private static Set<Id> explicitFinalAdjustedPriceIds = new Set<Id>();

  /**
   * Before-save: keep explicit Final_Adjusted_Price__c (Amount path); otherwise refresh from
   * Price + Discount / ListPrice rules whenever money inputs change or FAP is blank.
   */
  public static void applyFinalAdjustedPriceBeforeSave(
    List<MonthlyPayment__c> newPayments,
    Map<Id, MonthlyPayment__c> oldMap
  ) {
    if (newPayments == null || newPayments.isEmpty()) {
      return;
    }
    for (MonthlyPayment__c incoming : newPayments) {
      if (incoming == null) {
        continue;
      }
      if (
        PackageBuilderAccessTypePolicy.isUsageBased(incoming.Access_Type__c)
      ) {
        continue;
      }
      MonthlyPayment__c prior = (oldMap != null &&
        incoming.Id != null)
        ? oldMap.get(incoming.Id)
        : null;
      if (!isUsableFinalAdjustedPrice(incoming.Final_Adjusted_Price__c)) {
        incoming.Final_Adjusted_Price__c = null;
      }
      Boolean fapExplicit = incoming.Id != null
        ? explicitFinalAdjustedPriceIds.contains(incoming.Id)
        : isUsableFinalAdjustedPrice(incoming.Final_Adjusted_Price__c);
      if (fapExplicit) {
        continue;
      }
      Boolean datesChanged =
        prior != null &&
        (incoming.Stat_Date_Trigger__c != prior.Stat_Date_Trigger__c ||
        incoming.End_Date_trigger__c != prior.End_Date_trigger__c);
      if (datesChanged) {
        incoming.Final_Adjusted_Price__c = null;
        continue;
      }
      Boolean moneyInputsChanged =
        prior == null ||
        incoming.Discount__c != prior.Discount__c ||
        incoming.ListPrice__c != prior.ListPrice__c ||
        incoming.Access_Type__c != prior.Access_Type__c ||
        !isUsableFinalAdjustedPrice(incoming.Final_Adjusted_Price__c);
      if (!moneyInputsChanged) {
        continue;
      }
      Decimal derived = deriveFinalAdjustedPriceFromDiscount(incoming);
      incoming.Final_Adjusted_Price__c = isUsableFinalAdjustedPrice(derived)
        ? derived
        : null;
    }
  }

  /**
   * Mirrors Monthly_Units__c for same-calendar-month spans. When start/end cross a month
   * boundary (Monthly day-early Stat_Date_Trigger), measures the covered end month so a
   * full month is units=1 instead of a negative day-count fraction.
   */
  public static Decimal monthlyUnitsForAccessAndDates(
    String accessType,
    Date startDt,
    Date endDt
  ) {
    if (startDt == null || endDt == null) {
      return 1;
    }
    Boolean usesDayFraction =
      PackageBuilderAccessTypePolicy.isPeriodicLike(accessType) ||
      PackageBuilderAccessTypePolicy.isMonthlyLike(accessType);
    if (!usesDayFraction) {
      return 1;
    }
    // Monthly trigger dates start the day before the covered month (see
    // ContractService.monthlyStatDateForOrderItemMonth), so a full month arrives here as
    // e.g. Jan 31 -> Feb 28. Anchor on the covered month or the day arithmetic below
    // yields a negative span and the caller scales money by a nonsense factor.
    Date spanStart = startDt;
    if (startDt.year() != endDt.year() || startDt.month() != endDt.month()) {
      spanStart = endDt.toStartOfMonth();
    }
    Integer spanDays = endDt.day() - spanStart.day() + 1;
    Integer monthDays = Date.daysInMonth(spanStart.year(), spanStart.month());
    if (monthDays <= 0) {
      return 1;
    }
    return Decimal.valueOf(spanDays) / Decimal.valueOf(monthDays);
  }

  public static Decimal scaleFinalAdjustedPrice(
    Decimal fap,
    Decimal oldUnits,
    Decimal newUnits
  ) {
    if (fap == null) {
      return null;
    }
    Decimal ou = (oldUnits != null && oldUnits != 0) ? oldUnits : 1;
    Decimal nu = newUnits != null ? newUnits : 1;
    if (ou == nu) {
      return fap;
    }
    return (fap * nu) / ou;
  }

  public static Decimal scaleCopiedFinalAdjustedPrice(
    Decimal copiedFap,
    String accessType,
    Date sourceStart,
    Date sourceEnd,
    Date targetStart,
    Date targetEnd
  ) {
    return scaleCopiedFinalAdjustedPrice(
      copiedFap,
      accessType,
      sourceStart,
      sourceEnd,
      targetStart,
      targetEnd,
      null,
      null
    );
  }

  public static void applyCopiedFinalAdjustedPriceIfSameSpan(
    MonthlyPayment__c target,
    MonthlyPayment__c source,
    String accessType,
    Decimal copiedFap
  ) {
    if (
      target == null ||
      String.isBlank(accessType) ||
      !isUsableFinalAdjustedPrice(copiedFap)
    ) {
      return;
    }
    Date srcStart = source != null ? source.Stat_Date_Trigger__c : null;
    Date srcEnd = source != null ? source.End_Date_trigger__c : null;
    if (
      srcStart == null ||
      srcEnd == null ||
      target.Stat_Date_Trigger__c == null ||
      target.End_Date_trigger__c == null
    ) {
      return;
    }
    Decimal oldUnits = monthlyUnitsForAccessAndDates(
      accessType,
      srcStart,
      srcEnd
    );
    Decimal newUnits = monthlyUnitsForAccessAndDates(
      accessType,
      target.Stat_Date_Trigger__c,
      target.End_Date_trigger__c
    );
    if ((oldUnits - newUnits).abs() < 0.0000001) {
      target.Final_Adjusted_Price__c = copiedFap;
    }
  }

  public static Decimal scaleCopiedFinalAdjustedPrice(
    Decimal copiedFap,
    String accessType,
    Date sourceStart,
    Date sourceEnd,
    Date targetStart,
    Date targetEnd,
    Decimal lineMonthlyTotal,
    Decimal discountPercent
  ) {
    Decimal oldUnits = monthlyUnitsForAccessAndDates(
      accessType,
      sourceStart,
      sourceEnd
    );
    Decimal newUnits = monthlyUnitsForAccessAndDates(
      accessType,
      targetStart,
      targetEnd
    );
    // Date-sync may curtail src dates before rebuild copies them. If FAP still
    // matches the full-month commercial lock, scale from units=1.
    if (
      oldUnits == newUnits &&
      newUnits != 1 &&
      copiedFap != null &&
      lineMonthlyTotal != null &&
      lineMonthlyTotal != 0
    ) {
      Decimal factor =
        1 + ((discountPercent != null ? discountPercent : 0) / 100);
      Decimal fullMonthFap = lineMonthlyTotal * factor;
      if ((copiedFap - fullMonthFap).abs() <= 0.05) {
        oldUnits = 1;
      }
    }
    return scaleFinalAdjustedPrice(copiedFap, oldUnits, newUnits);
  }

  /** Last day of stat month, or line end when that end falls in the same month. */
  public static Date paymentEndClampedToLineEnd(
    Date statDate,
    Date lineEndDate
  ) {
    if (statDate == null) {
      return lineEndDate;
    }
    Date monthEnd = getLastDayOfMonth(statDate);
    if (
      lineEndDate != null &&
      lineEndDate.toStartOfMonth() == statDate.toStartOfMonth() &&
      lineEndDate < monthEnd
    ) {
      return lineEndDate;
    }
    return monthEnd;
  }

  /**
   * After insert: fill Final_Adjusted_Price__c when Price__c was not yet available in before-insert.
   */
  public static void ensureFinalAdjustedPriceAfterInsert(
    List<MonthlyPayment__c> inserted
  ) {
    if (
      inserted == null ||
      inserted.isEmpty() ||
      finalAdjustedPriceSyncInProgress
    ) {
      return;
    }
    Set<Id> ids = new Set<Id>();
    for (MonthlyPayment__c mp : inserted) {
      if (mp != null && mp.Id != null) {
        ids.add(mp.Id);
      }
    }
    if (ids.isEmpty()) {
      return;
    }
    List<MonthlyPayment__c> rows = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id IN :ids
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c row : rows) {
      if (PackageBuilderAccessTypePolicy.isUsageBased(row.Access_Type__c)) {
        continue;
      }
      if (isUsableFinalAdjustedPrice(row.Final_Adjusted_Price__c)) {
        continue;
      }
      Decimal derived = deriveFinalAdjustedPriceFromDiscount(row);
      if (!isUsableFinalAdjustedPrice(derived)) {
        continue;
      }
      toUpdate.add(
        new MonthlyPayment__c(Id = row.Id, Final_Adjusted_Price__c = derived)
      );
    }
    if (toUpdate.isEmpty()) {
      return;
    }
    finalAdjustedPriceSyncInProgress = true;
    try {
      update toUpdate;
    } finally {
      finalAdjustedPriceSyncInProgress = false;
    }
  }

  /**
   * After Discount/% saves, Price__c is current. Fill/replace FAP from
   * Price x (1+Discount). Skips Amount-explicit rows and Usage Based.
   * Date-sync must not call this — before-save clears FAP and FinalPrice derives.
   */
  public static void refreshFinalAdjustedPriceForPaymentIds(
    Set<Id> paymentIds
  ) {
    if (
      paymentIds == null ||
      paymentIds.isEmpty() ||
      finalAdjustedPriceSyncInProgress
    ) {
      return;
    }
    Set<Id> ids = new Set<Id>();
    for (Id paymentId : paymentIds) {
      if (
        paymentId != null && !explicitFinalAdjustedPriceIds.contains(paymentId)
      ) {
        ids.add(paymentId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }
    List<MonthlyPayment__c> rows = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE Id IN :ids
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c row : rows) {
      if (PackageBuilderAccessTypePolicy.isUsageBased(row.Access_Type__c)) {
        continue;
      }
      Decimal derived = deriveFinalAdjustedPriceFromDiscount(row);
      if (!isUsableFinalAdjustedPrice(derived)) {
        continue;
      }
      if (row.Final_Adjusted_Price__c == derived) {
        continue;
      }
      toUpdate.add(
        new MonthlyPayment__c(Id = row.Id, Final_Adjusted_Price__c = derived)
      );
    }
    if (toUpdate.isEmpty()) {
      return;
    }
    finalAdjustedPriceSyncInProgress = true;
    try {
      update toUpdate;
    } finally {
      finalAdjustedPriceSyncInProgress = false;
    }
  }

  /**
   * When parent UnitPrice/Quantity change, Price__c formula updates without MP DML.
   * Refresh Final_Adjusted_Price__c so Calculated Price does not keep a stale absolute.
   */
  public static void refreshFinalAdjustedPriceForOrderItems(
    Set<Id> orderItemIds
  ) {
    if (
      orderItemIds == null ||
      orderItemIds.isEmpty() ||
      finalAdjustedPriceSyncInProgress
    ) {
      return;
    }
    List<MonthlyPayment__c> rows = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :orderItemIds
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c row : rows) {
      if (PackageBuilderAccessTypePolicy.isUsageBased(row.Access_Type__c)) {
        continue;
      }
      Decimal derived = deriveFinalAdjustedPriceFromDiscount(row);
      if (derived == null) {
        continue;
      }
      if (
        isUsableFinalAdjustedPrice(row.Final_Adjusted_Price__c) &&
        !priceDecimalsDiffer(row.Final_Adjusted_Price__c, derived)
      ) {
        continue;
      }
      toUpdate.add(
        new MonthlyPayment__c(
          Id = row.Id,
          Final_Adjusted_Price__c = isUsableFinalAdjustedPrice(derived)
            ? derived
            : null
        )
      );
    }
    if (toUpdate.isEmpty()) {
      return;
    }
    finalAdjustedPriceSyncInProgress = true;
    try {
      update toUpdate;
    } finally {
      finalAdjustedPriceSyncInProgress = false;
    }
  }

  public static void refreshFinalAdjustedPriceForOpportunityLineItems(
    Set<Id> oliIds
  ) {
    if (
      oliIds == null ||
      oliIds.isEmpty() ||
      finalAdjustedPriceSyncInProgress
    ) {
      return;
    }
    List<MonthlyPayment__c> rows = [
      SELECT
        Id,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c IN :oliIds
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c row : rows) {
      if (PackageBuilderAccessTypePolicy.isUsageBased(row.Access_Type__c)) {
        continue;
      }
      Decimal derived = deriveFinalAdjustedPriceFromDiscount(row);
      if (derived == null) {
        continue;
      }
      if (
        isUsableFinalAdjustedPrice(row.Final_Adjusted_Price__c) &&
        !priceDecimalsDiffer(row.Final_Adjusted_Price__c, derived)
      ) {
        continue;
      }
      toUpdate.add(
        new MonthlyPayment__c(
          Id = row.Id,
          Final_Adjusted_Price__c = isUsableFinalAdjustedPrice(derived)
            ? derived
            : null
        )
      );
    }
    if (toUpdate.isEmpty()) {
      return;
    }
    finalAdjustedPriceSyncInProgress = true;
    try {
      update toUpdate;
    } finally {
      finalAdjustedPriceSyncInProgress = false;
    }
  }

  /** One-time / admin backfill: set Final_Adjusted_Price__c from current FinalPrice__c where blank. */
  public static Integer backfillFinalAdjustedPrice(Integer limitSize) {
    Integer lim = limitSize != null && limitSize > 0 ? limitSize : 200;
    List<MonthlyPayment__c> rows = [
      SELECT Id, FinalPrice__c, Access_Type__c, Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE
        (Final_Adjusted_Price__c = NULL
        OR Final_Adjusted_Price__c = 0)
        AND Access_Type__c != 'Usage Based'
      LIMIT :lim
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c row : rows) {
      if (!isUsableFinalAdjustedPrice(row.FinalPrice__c)) {
        continue;
      }
      toUpdate.add(
        new MonthlyPayment__c(
          Id = row.Id,
          Final_Adjusted_Price__c = row.FinalPrice__c
        )
      );
    }
    if (toUpdate.isEmpty()) {
      return 0;
    }
    finalAdjustedPriceSyncInProgress = true;
    Boolean wasBypassed = TriggerHandler.isBypassed(
      'MonthlyPaymentTriggerHandler'
    );
    if (!wasBypassed) {
      TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    }
    try {
      update toUpdate;
    } finally {
      if (!wasBypassed) {
        TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
      }
      finalAdjustedPriceSyncInProgress = false;
    }
    return toUpdate.size();
  }

  @TestVisible
  private static Boolean isUsageBasedPastPaymentMonth(
    Date startDate,
    Date today
  ) {
    if (startDate == null || today == null) {
      return false;
    }
    Integer startYm = startDate.year() * 12 + startDate.month();
    Integer todayYm = today.year() * 12 + today.month();
    return startYm < todayYm;
  }

  @TestVisible
  private static void validateAndNormalizeUsageBasedPaymentUpdates(
    List<MonthlyPayment__c> payments
  ) {
    if (payments == null || payments.isEmpty()) {
      return;
    }
    Set<Id> paymentIds = new Set<Id>();
    for (MonthlyPayment__c p : payments) {
      if (p != null && p.Id != null) {
        paymentIds.add(p.Id);
      }
    }
    if (paymentIds.isEmpty()) {
      return;
    }
    Map<Id, MonthlyPayment__c> existingById = new Map<Id, MonthlyPayment__c>(
      [
        SELECT Id, Access_Type__c, Start_date__c, ListPrice__c, Discount__c
        FROM MonthlyPayment__c
        WHERE Id IN :paymentIds
      ]
    );
    Date today = Date.today();
    for (MonthlyPayment__c incoming : payments) {
      if (incoming == null || incoming.Id == null) {
        continue;
      }
      MonthlyPayment__c existing = existingById.get(incoming.Id);
      if (
        existing == null ||
        !PackageBuilderAccessTypePolicy.isUsageBased(existing.Access_Type__c)
      ) {
        continue;
      }
      if (isUsageBasedPastPaymentMonth(existing.Start_date__c, today)) {
        throw new AuraHandledException(
          'Usage Based monthly payments cannot be edited for past months.'
        );
      }
      Decimal finalPrice = incoming.ListPrice__c;
      if (finalPrice == null) {
        finalPrice = incoming.Discount__c;
      }
      if (finalPrice != null && finalPrice < 0) {
        throw new AuraHandledException(
          'Usage Based final price cannot be negative.'
        );
      }
      incoming.Discount__c = null;
      incoming.ListPrice__c = finalPrice;
    }
  }

  /**
   * One MonthlyPayment row: Price__c * (1 + rate) using the same discount normalization as monthlyLinePayableAmount.
   * Exposed for callers outside this class (e.g. Opportunity line adjusted totals in PackageBuilderController).
   */
  public static Decimal payableAmountForMonthlyPayment(MonthlyPayment__c mp) {
    return monthlyPaymentLineAmount(mp);
  }

  private static Boolean priceDecimalsDiffer(Decimal a, Decimal b) {
    if (a == null && b == null) {
      return false;
    }
    if (a == null || b == null) {
      return true;
    }
    return a.setScale(2, System.RoundingMode.HALF_UP) !=
      b.setScale(2, System.RoundingMode.HALF_UP);
  }

  /**
   * @param isOli True when lineItem is OpportunityLineItem (use oliRenewalIntervals), false for OrderItem (use orderItemRenewalIntervals). Null when no date-based renewal lookup (e.g. deleteAllMonthlyPaymentNotRelevant).
   */
  public static List<MonthlyPayment__c> generateMonthlyPaymentsForLineItem(
    SObject lineItem,
    Date startDate,
    Integer numberOfMonths,
    List<MonthlyPayment__c> paymentsToCopy,
    Boolean isOli
  ) {
    List<MonthlyPayment__c> payments = new List<MonthlyPayment__c>();
    if (isContractTermsLineItem(lineItem)) {
      return payments;
    }
    String accessType = (String) lineItem.get('Access_Type__c');
    Decimal listPrice = (Decimal) lineItem.get('ListPrice');
    Id itemId = lineItem.Id;

    String sType = String.valueOf(lineItem.getSObjectType());
    Date entryDt = (sType == 'OpportunityLineItem')
      ? (Date) lineItem.get('Entry_Date__c')
      : (Date) lineItem.get('ServiceDate');
    Date endDt = (sType == 'OpportunityLineItem')
      ? (Date) lineItem.get('End_Date__c')
      : (Date) lineItem.get('EndDate');

    if (
      PackageBuilderAccessTypePolicy.isPeriodicLike(accessType) ||
      (PackageBuilderAccessTypePolicy.isUsageBased(accessType) &&
      sType == 'OpportunityLineItem')
    ) {
      Date currentStart = (entryDt != null) ? entryDt : Date.today();
      Date calculatedEndDt = (endDt != null)
        ? getLastDayOfMonth(endDt)
        : getLastDayOfMonth(currentStart.addMonths(1).addDays(-1));
      Integer mIdx = 0;
      while (currentStart < calculatedEndDt) {
        mIdx++;
        Date payStart = currentStart;
        Date payEnd = paymentEndClampedToLineEnd(payStart, endDt);
        payStart = clampPayStartToModifyOrderStart(lineItem, payStart, payEnd);
        Decimal renewalForDate = (isOli != null)
          ? getRenewalDiscountForDate(itemId, payStart, isOli)
          : null;
        payments.add(
          createPayment(
            lineItem,
            mIdx,
            getDiscountFromCopy(paymentsToCopy, mIdx),
            renewalForDate,
            payStart,
            payEnd
          )
        );
        currentStart = currentStart.addMonths(1).toStartOfMonth();
      }
    } else if (
      PackageBuilderAccessTypePolicy.isUsageBased(accessType) ||
      PackageBuilderAccessTypePolicy.isMonthlyLike(accessType)
    ) {
      if (
        PackageBuilderAccessTypePolicy.isUsageBased(accessType) &&
        sType != 'OrderItem' &&
        sType != 'OpportunityLineItem'
      ) {
        return payments;
      }
      if (sType == 'OrderItem') {
        String orderStatus = (lineItem.getSObject('Order') != null)
          ? (String) lineItem.getSObject('Order').get('Status')
          : null;
        Integer count = orderItemMonthlyPaymentCount(
          entryDt,
          endDt,
          orderStatus
        );
        Date effectiveEntry = (entryDt != null) ? entryDt : Date.today();
        for (Integer i = 1; i <= count; i++) {
          Date statD = ContractService.monthlyStatDateForOrderItemMonth(
            effectiveEntry,
            i
          );
          Date endD = ContractService.monthlyEndDateForOrderItemMonth(
            effectiveEntry,
            i
          );
          statD = clampPayStartToModifyOrderStart(lineItem, statD, endD);
          Decimal renewalForDate = (isOli != null)
            ? getRenewalDiscountForDate(
                itemId,
                endD != null ? endD.toStartOfMonth() : statD,
                isOli
              )
            : null;
          payments.add(
            createPayment(
              lineItem,
              i,
              getDiscountFromCopy(paymentsToCopy, i),
              renewalForDate,
              statD,
              endD
            )
          );
        }
      } else {
        Date baseStart = (startDate != null)
          ? startDate
          : (entryDt != null ? entryDt : Date.today());
        for (Integer i = 1; i <= numberOfMonths; i++) {
          Date payStart = baseStart.addMonths(i - 1);
          Date payEnd = getLastDayOfMonth(payStart);
          Decimal renewalForDate = (isOli != null)
            ? getRenewalDiscountForDate(itemId, payStart, isOli)
            : null;
          payments.add(
            createPayment(
              lineItem,
              i,
              getDiscountFromCopy(paymentsToCopy, i),
              renewalForDate,
              payStart,
              payEnd
            )
          );
        }
      }
    } else {
      Date payStart = (startDate != null)
        ? startDate
        : (entryDt != null ? entryDt : Date.today());
      Date payEnd = getLastDayOfMonth(payStart);
      Decimal renewalForDate = (isOli != null)
        ? getRenewalDiscountForDate(itemId, payStart, isOli)
        : null;
      payments.add(
        createPayment(
          lineItem,
          1,
          (paymentsToCopy != null && !paymentsToCopy.isEmpty())
            ? paymentsToCopy[0].Discount__c
            : null,
          renewalForDate,
          payStart,
          payEnd
        )
      );
    }

    applyCopiedFinalAdjustedPrices(payments, paymentsToCopy, accessType);
    return payments;
  }

  private static Decimal getDiscountFromCopy(
    List<MonthlyPayment__c> paymentsToCopy,
    Integer monthIndex
  ) {
    return (paymentsToCopy != null &&
      monthIndex <= paymentsToCopy.size())
      ? paymentsToCopy[monthIndex - 1].Discount__c
      : null;
  }

  private static Decimal getFapFromCopy(
    List<MonthlyPayment__c> paymentsToCopy,
    Integer monthIndex
  ) {
    if (paymentsToCopy == null || monthIndex > paymentsToCopy.size()) {
      return null;
    }
    MonthlyPayment__c src = paymentsToCopy[monthIndex - 1];
    if (src == null) {
      return null;
    }
    Map<String, Object> fields = src.getPopulatedFieldsAsMap();
    if (!fields.containsKey('Final_Adjusted_Price__c')) {
      return null;
    }
    return (Decimal) fields.get('Final_Adjusted_Price__c');
  }

  private static void applyCopiedFinalAdjustedPrices(
    List<MonthlyPayment__c> newPayments,
    List<MonthlyPayment__c> paymentsToCopy,
    String accessType
  ) {
    if (
      newPayments == null ||
      newPayments.isEmpty() ||
      paymentsToCopy == null ||
      paymentsToCopy.isEmpty()
    ) {
      return;
    }
    for (MonthlyPayment__c neu : newPayments) {
      if (neu == null || neu.MonthIndex__c == null) {
        continue;
      }
      Integer idx = Integer.valueOf(neu.MonthIndex__c);
      Decimal copiedFap = getFapFromCopy(paymentsToCopy, idx);
      if (copiedFap == null) {
        continue;
      }
      Decimal copiedDiscount = getDiscountFromCopy(paymentsToCopy, idx);
      if (
        copiedDiscount != null &&
        neu.Discount__c != null &&
        neu.Discount__c != copiedDiscount
      ) {
        continue;
      }
      applyCopiedFinalAdjustedPriceIfSameSpan(
        neu,
        paymentsToCopy[idx - 1],
        accessType,
        copiedFap
      );
    }
  }

  public static Date getLastDayOfMonth(Date inputDate) {
    return inputDate == null
      ? null
      : inputDate.toStartOfMonth().addMonths(1).addDays(-1);
  }

  /** Delegates to ContractService horizon for open-ended Monthly lines. */
  private static Integer orderItemMonthlyPaymentCount(
    Date entryDt,
    Date endDt,
    String orderStatus
  ) {
    if (entryDt == null) {
      return 0;
    }
    if (endDt != null) {
      Integer monthsDiff =
        (endDt.year() - entryDt.year()) * 12 +
        (endDt.month() - entryDt.month()) +
        1;
      if (endDt.day() < entryDt.day()) {
        monthsDiff--;
      }
      return monthsDiff > 0 ? monthsDiff : 0;
    }
    OrderItem stub = new OrderItem(
      ServiceDate = entryDt,
      Access_Type__c = 'Monthly',
      EndDate = null
    );
    stub.putSObject('Order', new Order(Status = orderStatus));
    return ContractService.monthlyPaymentCountForOrderItem(stub);
  }

  /**
   * Creates a MonthlyPayment__c. Start_date__c/End_date__c are formula fields from Stat_Date_Trigger__c/End_Date_trigger__c;
   * we set those so discount-from-adjustment logic can use Start_date__c/End_date__c consistently.
   */
  private static Date orderStartDateFromLine(SObject lineItem) {
    if (
      lineItem == null ||
      String.valueOf(lineItem.getSObjectType()) != 'OrderItem'
    ) {
      return null;
    }
    Order parent = (Order) lineItem.getSObject('Order');
    if (parent == null) {
      return null;
    }
    Map<String, Object> fields = parent.getPopulatedFieldsAsMap();
    if (fields.containsKey('Replacement_Start_Date__c')) {
      Date replacementStart = (Date) fields.get('Replacement_Start_Date__c');
      if (replacementStart != null) {
        return replacementStart;
      }
    }
    if (fields.containsKey('Order_Start_Date__c')) {
      return (Date) fields.get('Order_Start_Date__c');
    }
    return null;
  }

  /**
   * Floor a payment start to Order/Replacement Start only when the product itself
   * starts on or after that date. Continuing products (ServiceDate before Order Start)
   * keep a full calendar month in the Order Start month.
   */
  public static Date clampPayStartToModifyOrderStart(
    SObject lineItem,
    Date payStart,
    Date payEnd
  ) {
    Date orderStart = orderStartDateFromLine(lineItem);
    if (
      orderStart == null ||
      payStart == null ||
      payEnd == null ||
      payStart >= orderStart ||
      payEnd < orderStart ||
      payStart.year() != orderStart.year() ||
      payStart.month() != orderStart.month()
    ) {
      return payStart;
    }
    Date productStart = productStartDateFromLine(lineItem);
    if (productStart != null && productStart < orderStart) {
      return payStart;
    }
    return orderStart;
  }

  private static Date productStartDateFromLine(SObject lineItem) {
    if (lineItem == null) {
      return null;
    }
    String sType = String.valueOf(lineItem.getSObjectType());
    if (sType == 'OrderItem') {
      Map<String, Object> fields = lineItem.getPopulatedFieldsAsMap();
      if (fields.containsKey('ServiceDate')) {
        return (Date) fields.get('ServiceDate');
      }
      return null;
    }
    if (sType == 'OpportunityLineItem') {
      Map<String, Object> fields = lineItem.getPopulatedFieldsAsMap();
      if (fields.containsKey('Entry_Date__c')) {
        return (Date) fields.get('Entry_Date__c');
      }
      return null;
    }
    return null;
  }

  private static MonthlyPayment__c createPayment(
    SObject lineItem,
    Integer monthIndex,
    Decimal discount,
    Decimal renewalAdjustment,
    Date paymentStartDate,
    Date paymentEndDate
  ) {
    MonthlyPayment__c payment = new MonthlyPayment__c();
    payment.MonthIndex__c = monthIndex;
    payment.User_Price_Adjustment__c = 0;
    if (renewalAdjustment != null) {
      payment.Discount__c = renewalAdjustment;
    } else {
      payment.Discount__c = discount != null ? discount : 0;
    }
    if (paymentStartDate != null) {
      payment.Stat_Date_Trigger__c = paymentStartDate;
    }
    if (paymentEndDate != null) {
      payment.End_Date_trigger__c = paymentEndDate;
    }

    if (String.valueOf(lineItem.getSObjectType()) == 'OpportunityLineItem') {
      payment.OpportunityLineItem__c = lineItem.Id;
      payment.Opportunity__c = (Id) lineItem.get('OpportunityId');
    } else {
      payment.OrderItem__c = lineItem.Id;
      Id contractId = (Id) lineItem.get('Contract__c');
      if (contractId != null) {
        payment.Contract__c = contractId;
      } else {
      }
      payment.Opportunity__c = (Id) lineItem.getSObject('Order')
        ?.get('OpportunityId');
    }
    return payment;
  }

  private static void regeneratePackageBuilderOrderItemPayments(
    Set<Id> rebuildIds
  ) {
    if (rebuildIds == null || rebuildIds.isEmpty()) {
      return;
    }
    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings.size() > 0 &&
      mpSettings[0].NumberOfMonths__c != null
      ? Integer.valueOf(mpSettings[0].NumberOfMonths__c)
      : 12;

    List<OrderItem> itemsToProcess = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        ListPrice,
        OrderId,
        Product2Id,
        Contract__c,
        Contract__r.EndDate,
        Order.OpportunityId,
        Order.Status,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.Replacement_Start_Date__c,
        Access_Type__c,
        Product2.Type__c
      FROM OrderItem
      WHERE Id IN :rebuildIds
    ];

    RecurringPriceIncreaseService.preloadLines(rebuildIds);

    List<MonthlyPayment__c> toInsert = new List<MonthlyPayment__c>();
    for (OrderItem item : itemsToProcess) {
      String at = item.Access_Type__c;
      Integer n = numberOfMonths;
      if (PackageBuilderAccessTypePolicy.isMonthlyLike(at)) {
        n = orderItemMonthlyPaymentCount(
          item.ServiceDate,
          item.EndDate,
          item.Order != null ? item.Order.Status : null
        );
      } else if (PackageBuilderAccessTypePolicy.isUsageBased(at)) {
        n = orderItemMonthlyPaymentCount(
          item.ServiceDate,
          item.EndDate,
          item.Order != null ? item.Order.Status : null
        );
      }
      toInsert.addAll(
        generateMonthlyPaymentsForLineItem(item, null, n, null, false)
      );
    }
    if (!toInsert.isEmpty()) {
      insert toInsert;
    }
  }

  public static void deleteAllMonthlyPaymentNotRelevant(
    List<SObject> itemsNew,
    Map<Id, SObject> itemsOldMap
  ) {
    if (itemsNew == null || itemsNew.isEmpty())
      return;
    String sType = String.valueOf(itemsNew[0].getSObjectType());

    Map<Id, SObject> relevantItems = getRelevantItems(
      itemsNew,
      itemsOldMap,
      sType
    );
    if (relevantItems.isEmpty())
      return;

    String lookupField = (sType == 'OpportunityLineItem')
      ? 'OpportunityLineItem__c'
      : 'OrderItem__c';
    Set<Id> itemIds = relevantItems.keySet();

    if (sType == 'OrderItem') {
      List<OrderItem> orderItemsToProcess = [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Contract__c,
          Contract__r.EndDate,
          Order.OpportunityId,
          Order.Status,
          Order.EffectiveDate,
          Order.Order_Start_Date__c,
          Access_Type__c,
          Product2.Type__c
        FROM OrderItem
        WHERE Id IN :itemIds
      ];
      Set<Id> rebuildIds = new Set<Id>();
      List<OrderItem> addOnlyLines = new List<OrderItem>();
      for (OrderItem oi : orderItemsToProcess) {
        OrderItem oldOi = itemsOldMap != null && itemsOldMap.containsKey(oi.Id)
          ? (OrderItem) itemsOldMap.get(oi.Id)
          : null;
        if (ContractService.shouldUseOpenEndedMonthlyAddOnlySync(oi, oldOi)) {
          addOnlyLines.add(oi);
        } else {
          rebuildIds.add(oi.Id);
        }
      }
      if (!addOnlyLines.isEmpty()) {
        ContractService.syncOpenEndedMonthlyPaymentsAddOnly(addOnlyLines);
      }
      if (!rebuildIds.isEmpty()) {
        delete Database.query(
          'SELECT Id FROM MonthlyPayment__c WHERE ' +
            lookupField +
            ' IN :rebuildIds'
        );
        regeneratePackageBuilderOrderItemPayments(rebuildIds);
      }
      return;
    }

    delete Database.query(
      'SELECT Id FROM MonthlyPayment__c WHERE ' + lookupField + ' IN :itemIds'
    );

    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings.size() > 0 &&
      mpSettings[0].NumberOfMonths__c != null
      ? Integer.valueOf(mpSettings[0].NumberOfMonths__c)
      : 12;

    // Re-query items with all necessary fields
    List<SObject> itemsToProcess = new List<SObject>();
    if (sType == 'OpportunityLineItem') {
      itemsToProcess = [
        SELECT
          Id,
          Entry_Date__c,
          End_Date__c,
          ListPrice,
          OpportunityId,
          Product2Id,
          Access_Type__c,
          Product2.Type__c
        FROM OpportunityLineItem
        WHERE Id IN :itemIds
      ];
    } else {
      itemsToProcess = [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          ListPrice,
          OrderId,
          Product2Id,
          Contract__c,
          Order.OpportunityId,
          Order.Status,
          Access_Type__c,
          Product2.Type__c
        FROM OrderItem
        WHERE Id IN :itemIds
      ];
    }

    RecurringPriceIncreaseService.preloadLines(itemIds);

    List<MonthlyPayment__c> toInsert = new List<MonthlyPayment__c>();
    for (SObject item : itemsToProcess) {
      String at = (String) item.get('Access_Type__c');
      Integer n = numberOfMonths;
      if (
        sType == 'OrderItem' && PackageBuilderAccessTypePolicy.isMonthlyLike(at)
      ) {
        String orderStatus = (item.getSObject('Order') != null)
          ? (String) item.getSObject('Order').get('Status')
          : null;
        n = orderItemMonthlyPaymentCount(
          (Date) item.get('ServiceDate'),
          (Date) item.get('EndDate'),
          orderStatus
        );
      } else if (
        sType == 'OrderItem' && PackageBuilderAccessTypePolicy.isUsageBased(at)
      ) {
        String orderStatus = (item.getSObject('Order') != null)
          ? (String) item.getSObject('Order').get('Status')
          : null;
        n = orderItemMonthlyPaymentCount(
          (Date) item.get('ServiceDate'),
          (Date) item.get('EndDate'),
          orderStatus
        );
      }
      Boolean isOliFlag = sType == 'OpportunityLineItem';
      toInsert.addAll(
        generateMonthlyPaymentsForLineItem(item, null, n, null, isOliFlag)
      );
    }
    if (!toInsert.isEmpty())
      insert toInsert;
  }

  private static Map<Id, SObject> getRelevantItems(
    List<SObject> newItems,
    Map<Id, SObject> oldItems,
    String sType
  ) {
    Map<Id, SObject> relevant = new Map<Id, SObject>();
    String entryFld = (sType == 'OpportunityLineItem')
      ? 'Entry_Date__c'
      : 'ServiceDate';
    String endFld = (sType == 'OpportunityLineItem')
      ? 'End_Date__c'
      : 'EndDate';

    for (SObject item : newItems) {
      if (oldItems == null) {
        relevant.put(item.Id, item);
      } else {
        SObject oldItem = oldItems.get(item.Id);
        Boolean changed = (item.get('Quantity') != oldItem.get('Quantity') ||
        item.get('UnitPrice') != oldItem.get('UnitPrice') ||
        item.get(entryFld) != oldItem.get(entryFld) ||
        item.get(endFld) != oldItem.get(endFld) ||
        item.get('Access_Type__c') != oldItem.get('Access_Type__c'));
        if (changed)
          relevant.put(item.Id, item);
      }
    }
    return relevant;
  }

  public static void publishEvent() {
    EventBus.publish(new MonthlyPaymentAdded__e());
  }

  private static Date orderStartDate(Order o) {
    if (o == null) {
      return null;
    }
    return o.Order_Start_Date__c != null
      ? o.Order_Start_Date__c
      : o.EffectiveDate;
  }

  /**
   * Parent order end-date rule: if any line has blank EndDate, parent is blank (open-ended wins);
   * otherwise use the latest line EndDate.
   */
  @TestVisible
  private static Date deriveMaxOrderEndDateFromItems(
    List<OrderItem> items,
    Date fallbackEndDate
  ) {
    return PackageEndDateRollupService.derivePackageEndDateFromLines(
      items,
      fallbackEndDate
    );
  }

  // ========== DRAFT ORDER MANAGEMENT METHODS ==========

  /**
   * Result wrapper for ensureDraftOrder – includes the draft Order plus a
   * mapping from old (active) OrderItem Ids to new (draft) OrderItem Ids so
   * the LWC can re-map any pending inline edits.
   */
  public class DraftOrderResult {
    @AuraEnabled
    public Order draftOrder;
    @AuraEnabled
    public Map<Id, Id> itemIdMapping; // old active item Id → new draft item Id
  }

  /**
   * Ensures a draft order exists for the given contract (lazy creation).
   * If a draft already exists it is returned as-is (with an empty mapping).
   * Otherwise the active order and all its OrderItems are cloned.
   */
  @AuraEnabled
  public static DraftOrderResult ensureDraftOrder(Id contractId) {
    return ensureDraftOrderInternal(contractId, null);
  }

  public static DraftOrderResult ensureDraftOrderWithStartDate(
    Id contractId,
    Date initialOrderStartDate
  ) {
    return ensureDraftOrderInternal(contractId, initialOrderStartDate);
  }

  private static DraftOrderResult ensureDraftOrderInternal(
    Id contractId,
    Date initialOrderStartDate
  ) {
    try {
      // Serialize concurrent ensure-draft calls so two overlapping Modify
      // requests cannot both see "no draft" and insert duplicates.
      Contract lockedContract = [
        SELECT Id
        FROM Contract
        WHERE Id = :contractId
        FOR UPDATE
      ];

      List<Order> orders = [
        SELECT
          Id,
          Status,
          EffectiveDate,
          Order_Start_Date__c,
          EndDate,
          ContractId,
          Previous_Order__c,
          Pricebook2Id,
          AccountId,
          Replacement_Start_Date__c,
          Agreement_language__c,
          Credits_for_MR__c,
          Prints_Color__c,
          Prints_B_W__c,
          Auto_Renewal__c,
          Renewal_Status__c,
          Renewal_Total_Iterations__c,
          Last_Status_Change_Date__c,
          Non_Renewal_Reason__c,
          Renewal_Period_Months__c,
          Description,
          Depusit_Amount_DM__c,
          Number_of_members__c,
          Payment_Method__c,
          Track_CPI__c,
          Track_CPI_Date__c,
          Lease_Termination_Notice_Months__c
        FROM Order
        WHERE
          ContractId = :contractId
          AND (Status = 'Activated'
          OR Status = 'Draft'
          OR Status = 'Negotiation'
          OR Status = 'Cancelled')
        ORDER BY CreatedDate DESC
      ];

      Order activeOrder = null;
      Order draftOrder = null;

      for (Order ord : orders) {
        if (ord.Status == 'Activated' && activeOrder == null) {
          activeOrder = ord;
        } else if (
          (ord.Status == 'Draft' || ord.Status == 'Negotiation') &&
          draftOrder == null
        ) {
          draftOrder = ord;
        }
      }

      DraftOrderResult result = new DraftOrderResult();
      result.itemIdMapping = new Map<Id, Id>();

      // If draft already exists, return it (no mapping needed – items already exist)
      if (draftOrder != null) {
        List<OrderItem> existingDraftItems = [
          SELECT EndDate, Is_Line_Deleted__c, Product2.Type__c
          FROM OrderItem
          WHERE OrderId = :draftOrder.Id
        ];
        Date recalculatedDraftEnd = deriveMaxOrderEndDateFromItems(
          existingDraftItems,
          draftOrder.EndDate
        );
        if (draftOrder.EndDate != recalculatedDraftEnd) {
          draftOrder.put('EndDate', recalculatedDraftEnd);
          update draftOrder;
        }
        result.draftOrder = draftOrder;
        return result;
      }

      // Must have an active order to clone from
      if (activeOrder == null) {
        throw new AuraHandledException(
          'No active order found on this contract to create a draft from.'
        );
      }

      // Clone active order → draft (Package Builder modify contract)
      Order newDraft = activeOrder.clone(false, true, false, false);
      newDraft.Status = 'Draft';
      newDraft.Previous_Order__c = activeOrder.Id;
      newDraft.Replacement_Start_Date__c = null; // set on activation
      newDraft.Order_Start_Date__c = initialOrderStartDate != null
        ? initialOrderStartDate
        : activeOrder.Order_Start_Date__c;
      // Temporary value; recalculated from cloned draft line items below.
      newDraft.put('EndDate', activeOrder.EndDate);
      insert newDraft;

      // Clone active OrderItems. Contract Terms (meter) lines with EndDate <= today are skipped unless
      // another line on this order still references them via Replaced_Order_Product__c (replacement chain).
      List<OrderItem> activeItems = [
        SELECT
          Id,
          PricebookEntryId,
          Product2Id,
          Quantity,
          UnitPrice,
          ListPrice,
          ServiceDate,
          EndDate,
          Description,
          Access_Type__c,
          Temporary__c,
          Product_Type_Name__c,
          Contract__c,
          Opportunity_Product__c,
          Original_Start_Date__c,
          Original_End_Date__c,
          CPI_Date__c,
          Replaced_Order_Product__c,
          Termination_Reason__c,
          Early_Exit_Request__c,
          Is_Line_Deleted__c,
          Product2.Type__c,
          Product2.IsActive,
          PricebookEntry.IsActive
        FROM OrderItem
        WHERE OrderId = :activeOrder.Id
      ];

      Map<Id, Decimal> currentListPriceByPricebookEntryId = currentListPriceByPricebookEntryId(
        activeItems
      );

      List<OrderItem> draftItems = new List<OrderItem>();
      // Maintain insertion order so we can build the mapping after insert
      List<Id> activeItemIds = new List<Id>();
      Date today = Date.today();
      // Contract-term lines with EndDate <= today are normally omitted from the draft snapshot.
      // A replaced parent line (Removed, ended on/before today) must still be cloned when another
      // active line references it via Replaced_Order_Product__c; otherwise the replacement row
      // keeps a cross-order lookup, remap fails, and Package Builder treats every line as new.
      Set<Id> activeItemIdsReferencedAsReplaced = new Set<Id>();
      for (OrderItem item : activeItems) {
        if (item.Replaced_Order_Product__c != null) {
          activeItemIdsReferencedAsReplaced.add(item.Replaced_Order_Product__c);
        }
      }
      for (OrderItem item : activeItems) {
        Boolean isContractTerms =
          item.Product2 != null &&
          item.Product2.Type__c == PRODUCT_TYPE_CONTRACT_TERMS;
        if (
          isContractTerms &&
          item.EndDate != null &&
          item.EndDate <= today &&
          isLineVisible(item) &&
          !activeItemIdsReferencedAsReplaced.contains(item.Id)
        ) {
          continue;
        }
        if (!isCatalogLineActive(item)) {
          continue;
        }
        OrderItem draftItem = item.clone(false, true, false, false);
        draftItem.OrderId = newDraft.Id;
        // Preserve active line entry date on draft creation (copy-as-is requirement).
        draftItem.ServiceDate = item.ServiceDate;
        draftItem.put('EndDate', item.EndDate);
        draftItem.Termination_Reason__c = item.Termination_Reason__c;
        // Draft semantics: cloned lines are carried over unchanged, linked to original.
        draftItem.Change_Type__c = 'No Change';
        draftItem.Original_Order_Product__c = item.Id;
        draftItem.Show_Financial_Adjustment_Icon__c = false;
        applyCurrentPricebookListPriceOnDraftClone(
          draftItem,
          item,
          currentListPriceByPricebookEntryId
        );
        draftItems.add(draftItem);
        activeItemIds.add(item.Id);
      }

      if (!draftItems.isEmpty()) {
        insert draftItems;
        if (!skipIterationCopyOnDraftClone) {
          IterationService.copyFromOriginalOrderProducts(draftItems);
        }
        // Always copy recurring rule fields (including auto-renew, which skips Iteration copy).
        RecurringPriceIncreaseService.copyFromOriginalOrderProducts(draftItems);
      }

      Date recalculatedNewDraftEnd = deriveMaxOrderEndDateFromItems(
        draftItems,
        newDraft.EndDate
      );
      if (newDraft.EndDate != recalculatedNewDraftEnd) {
        newDraft.put('EndDate', recalculatedNewDraftEnd);
        update newDraft;
      }

      // Build old→new mapping
      for (Integer i = 0; i < activeItemIds.size(); i++) {
        result.itemIdMapping.put(activeItemIds[i], draftItems[i].Id);
      }

      // Replacement rows on the active order point Replaced_Order_Product__c at active parent line Ids.
      // After clone those Ids are wrong for the draft (parent lines received new OrderItem Ids). Remap so
      // Package Builder can show moving-in / moving-out pairs on the Draft tab (LWC keys off draft Ids).
      List<OrderItem> replacedLookupRemaps = new List<OrderItem>();
      for (OrderItem draftItem : draftItems) {
        if (draftItem.Replaced_Order_Product__c == null) {
          continue;
        }
        Id draftReplacedTarget = result.itemIdMapping.get(
          draftItem.Replaced_Order_Product__c
        );
        if (
          draftReplacedTarget != null &&
          draftReplacedTarget != draftItem.Replaced_Order_Product__c
        ) {
          replacedLookupRemaps.add(
            new OrderItem(
              Id = draftItem.Id,
              Replaced_Order_Product__c = draftReplacedTarget
            )
          );
        } else if (draftReplacedTarget == null) {
          // Parent was not cloned (e.g. inactive catalog) — show child as a normal line.
          replacedLookupRemaps.add(
            new OrderItem(Id = draftItem.Id, Replaced_Order_Product__c = null)
          );
        }
      }
      if (!replacedLookupRemaps.isEmpty()) {
        update replacedLookupRemaps;
      }

      // Monthly payments for draft lines are created in OrderItemTriggerHandler.afterInsert when the parent order
      // is a replacement draft (Draft/Negotiation + Previous_Order__c). Old active-order payments stay unchanged
      // until activation (OrderTriggerHandler + ContractService.deleteAllMonthlyPaymentNotRelevant).

      result.draftOrder = newDraft;
      return result;
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error creating draft order: ' + e.getMessage()
      );
    }
  }

  /**
   * On OrderItem insert, ListPrice must match the related PricebookEntry.UnitPrice. Activated lines can
   * retain a historical list price after the price book changes; refresh from the entry when cloning to draft.
   */
  @TestVisible
  private static Map<Id, Decimal> currentListPriceByPricebookEntryId(
    List<OrderItem> sourceItems
  ) {
    Map<Id, Decimal> listPriceByEntryId = new Map<Id, Decimal>();
    if (sourceItems == null || sourceItems.isEmpty()) {
      return listPriceByEntryId;
    }
    Set<Id> pricebookEntryIds = new Set<Id>();
    for (OrderItem item : sourceItems) {
      if (item != null && item.PricebookEntryId != null) {
        pricebookEntryIds.add(item.PricebookEntryId);
      }
    }
    if (pricebookEntryIds.isEmpty()) {
      return listPriceByEntryId;
    }
    for (PricebookEntry pbe : [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE Id IN :pricebookEntryIds
    ]) {
      listPriceByEntryId.put(pbe.Id, pbe.UnitPrice);
    }
    return listPriceByEntryId;
  }

  @TestVisible
  private static void applyCurrentPricebookListPriceOnDraftClone(
    OrderItem draftItem,
    OrderItem sourceItem,
    Map<Id, Decimal> currentListPriceByPricebookEntryId
  ) {
    if (
      draftItem == null ||
      sourceItem == null ||
      sourceItem.PricebookEntryId == null ||
      currentListPriceByPricebookEntryId == null ||
      !currentListPriceByPricebookEntryId.containsKey(
        sourceItem.PricebookEntryId
      )
    ) {
      return;
    }
    draftItem.ListPrice = currentListPriceByPricebookEntryId.get(
      sourceItem.PricebookEntryId
    );
  }

  /**
   * Business rule when switching packages: the previous order's Customer Package End Date becomes
   * the day before the new (activating) order's start. If that day is before the previous order's
   * start (order start date / Customer Package Start Date), use the previous start date instead
   * so the package never ends before it began.
   */
  private static Date computeArchivedPreviousOrderEndDate(
    Date newOrderStartDate,
    Date previousOrderEffectiveDate
  ) {
    if (newOrderStartDate == null) {
      return null;
    }
    Date prevEnd = newOrderStartDate.addDays(-1);
    if (
      previousOrderEffectiveDate != null &&
      prevEnd < previousOrderEffectiveDate
    ) {
      prevEnd = previousOrderEffectiveDate;
    }
    return prevEnd;
  }

  /**
   * Replacement / modify-contract curtailment only: set previous-order line EndDate to the day before
   * the new order starts (same as OrderTriggerHandler.handleOrderSwitchOver), so the previous order
   * can be archived with EndDate = that day without violating rules that require the package end date
   * to be on or after each product end date. Trigger handler still runs after activation for idempotent
   * line updates and payment cleanup.
   * If a legacy line has ServiceDate after the cutoff day, align ServiceDate down to the cutoff so
   * EndDate can still be set to the strict replacement cutoff.
   */
  private static void curtailPreviousOrderItemsForReplacement(
    Id previousOrderId,
    Date replacementOrderStartDate
  ) {
    if (previousOrderId == null || replacementOrderStartDate == null) {
      return;
    }
    Date cutoffDate = replacementOrderStartDate.addDays(-1);
    Date effectiveCutoffDate = cutoffDate;
    List<Order> prevOrders = [
      SELECT Id, EffectiveDate, Order_Start_Date__c, Contract.StartDate
      FROM Order
      WHERE Id = :previousOrderId
      LIMIT 1
    ];
    if (!prevOrders.isEmpty()) {
      Order prevOrder = prevOrders[0];
      Date contractStart = prevOrder.Contract != null
        ? prevOrder.Contract.StartDate
        : null;
      if (contractStart != null && effectiveCutoffDate < contractStart) {
        effectiveCutoffDate = contractStart;
      }
      Date prevBusinessStart = orderStartDate(prevOrder);
      if (
        prevBusinessStart != null &&
        prevBusinessStart > effectiveCutoffDate
      ) {
        // Keep product-date validations satisfied when we curtail lines to cutoffDate.
        prevOrder.Order_Start_Date__c = effectiveCutoffDate;
        if (
          prevOrder.EffectiveDate == null ||
          prevOrder.EffectiveDate > effectiveCutoffDate
        ) {
          prevOrder.EffectiveDate = effectiveCutoffDate;
        }
        update prevOrder;
      }
    }

    List<OrderItem> oldOrderItems = [
      SELECT Id, OrderId, EndDate, ServiceDate
      FROM OrderItem
      WHERE OrderId = :previousOrderId
    ];
    List<OrderItem> itemsToUpdate = new List<OrderItem>();
    for (OrderItem item : oldOrderItems) {
      if (item.ServiceDate == null) {
        continue;
      }
      Date newEndDate = effectiveCutoffDate;
      Boolean changed = false;
      // Keep replacement rule strict: previous lines end on cutoff day.
      // Align ServiceDate when it is later than cutoff to satisfy start/end validation.
      if (item.ServiceDate > newEndDate) {
        item.ServiceDate = newEndDate;
        changed = true;
      }
      if (item.EndDate != newEndDate) {
        item.put('EndDate', newEndDate);
        changed = true;
      }
      if (changed) {
        itemsToUpdate.add(item);
      }
    }
    if (!itemsToUpdate.isEmpty()) {
      OrderItemTriggerHandler.enterContractTermMeterEndDateNormalizeSuppress();
      try {
        update itemsToUpdate;
      } finally {
        OrderItemTriggerHandler.exitContractTermMeterEndDateNormalizeSuppress();
      }
    }
  }

  /**
   * Marks draft lines soft-deleted on activation (869dfgerd) instead of physical delete.
   * Returns affected OrderItem Ids for in-memory list filtering.
   */
  @TestVisible
  private static Set<Id> markLinesSoftDeletedOnActivation(
    List<OrderItem> lines
  ) {
    Set<Id> affectedIds = new Set<Id>();
    if (lines == null || lines.isEmpty()) {
      return affectedIds;
    }
    List<OrderItem> toSoftDelete = new List<OrderItem>();
    for (OrderItem oi : lines) {
      if (oi == null || oi.Id == null) {
        continue;
      }
      affectedIds.add(oi.Id);
      if (oi.Is_Line_Deleted__c != true) {
        toSoftDelete.add(new OrderItem(Id = oi.Id, Is_Line_Deleted__c = true));
      }
    }
    if (!toSoftDelete.isEmpty()) {
      update toSoftDelete;
    }
    return affectedIds;
  }

  /**
   * Restores draft parents before never-activated replacement children are
   * permanently removed during activation.
   */
  private static Set<Id> restoreParentsForHardDeletedReplacements(
    List<OrderItem> lines
  ) {
    Set<Id> replacedIds = new Set<Id>();
    Map<Id, Date> replacementEndDateByReplacedId = new Map<Id, Date>();
    Map<Id, Boolean> accessTypeChangeUndoByReplacedId = new Map<Id, Boolean>();
    if (lines != null) {
      for (OrderItem oi : lines) {
        if (oi == null || oi.Replaced_Order_Product__c == null) {
          continue;
        }
        replacedIds.add(oi.Replaced_Order_Product__c);
        replacementEndDateByReplacedId.put(
          oi.Replaced_Order_Product__c,
          oi.EndDate
        );
        if (oi.Changed_Access_Type__c == true) {
          accessTypeChangeUndoByReplacedId.put(
            oi.Replaced_Order_Product__c,
            true
          );
        }
      }
    }
    if (replacedIds.isEmpty()) {
      return replacedIds;
    }

    Map<Id, OrderItem> replacedParentsById = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          Change_Type__c,
          EndDate,
          ServiceDate,
          Original_Order_Product__c,
          OrderId,
          Access_Type__c,
          PricebookEntryId
        FROM OrderItem
        WHERE Id IN :replacedIds
      ]
    );
    if (replacedParentsById.isEmpty()) {
      return replacedParentsById.keySet();
    }

    Map<Id, Boolean> pastStartSplitUndoByReplacedId = new Map<Id, Boolean>();
    for (OrderItem oi : lines) {
      if (oi == null || oi.Replaced_Order_Product__c == null) {
        continue;
      }
      OrderItem replacedParent = replacedParentsById.get(
        oi.Replaced_Order_Product__c
      );
      if (isPastStartSplitReplacementForUndo(oi, replacedParent)) {
        pastStartSplitUndoByReplacedId.put(oi.Replaced_Order_Product__c, true);
      }
    }

    Set<Id> activeLineIds = new Set<Id>();
    for (OrderItem replaced : replacedParentsById.values()) {
      if (replaced.Original_Order_Product__c != null) {
        activeLineIds.add(replaced.Original_Order_Product__c);
      }
    }
    Map<Id, OrderItem> activeLinesById = activeLineIds.isEmpty()
      ? new Map<Id, OrderItem>()
      : new Map<Id, OrderItem>(
          [SELECT Id, EndDate FROM OrderItem WHERE Id IN :activeLineIds]
        );

    Map<Id, List<OrderItem>> parentsByOrderId = new Map<Id, List<OrderItem>>();
    for (OrderItem replaced : replacedParentsById.values()) {
      Date activeEnd = null;
      if (replaced.Original_Order_Product__c != null) {
        OrderItem activeLine = activeLinesById.get(
          replaced.Original_Order_Product__c
        );
        if (activeLine != null) {
          activeEnd = activeLine.EndDate;
        }
      }
      replaced.Change_Type__c = null;
      replaced.EndDate = resolveReplacedEndDateOnReplacementDelete(
        replacementEndDateByReplacedId.get(replaced.Id),
        activeEnd,
        pastStartSplitUndoByReplacedId.get(replaced.Id) == true,
        replaced.Access_Type__c,
        accessTypeChangeUndoByReplacedId.get(replaced.Id) == true
      );
      if (!parentsByOrderId.containsKey(replaced.OrderId)) {
        parentsByOrderId.put(replaced.OrderId, new List<OrderItem>());
      }
      parentsByOrderId.get(replaced.OrderId).add(replaced);
    }

    for (Id orderId : parentsByOrderId.keySet()) {
      ensureDraftOrderEndCoversLineEndDates(
        orderId,
        parentsByOrderId.get(orderId),
        null
      );
    }
    update replacedParentsById.values();
    return replacedParentsById.keySet();
  }

  @TestVisible
  private static List<OrderItem> removeOrderItemsById(
    List<OrderItem> items,
    Set<Id> idsToRemove
  ) {
    if (
      items == null ||
      items.isEmpty() ||
      idsToRemove == null ||
      idsToRemove.isEmpty()
    ) {
      return items != null ? items : new List<OrderItem>();
    }
    List<OrderItem> remaining = new List<OrderItem>();
    for (OrderItem oi : items) {
      if (!idsToRemove.contains(oi.Id)) {
        remaining.add(oi);
      }
    }
    return remaining;
  }

  /**
   * When a terminated or expired contract is re-activated via Package Builder, sync Status and termination date
   * so record-triggered flows do not immediately re-terminate (Calculated_End_Date__c must be > today).
   */
  @TestVisible
  private static Boolean reactivateTerminatedContractIfApplicable(
    Contract con,
    Date effectiveEndDate
  ) {
    if (
      con == null || (con.Status != 'Terminated' && con.Status != 'Expired')
    ) {
      return false;
    }
    Date today = Date.today();
    if (effectiveEndDate != null && effectiveEndDate < today) {
      return false;
    }

    Boolean wasTerminated = con.Status == 'Terminated';
    Boolean wasExpired = con.Status == 'Expired';
    con.Status = 'Activated';
    if (effectiveEndDate == null) {
      con.Contract_Termination_Date__c = null;
      con.Contract_Termination_Reason__c = null;
      con.put('EndDate', null);
      return true;
    }
    if (wasTerminated) {
      con.Contract_Termination_Date__c = effectiveEndDate;
    }
    if (wasExpired || con.EndDate == null || effectiveEndDate > con.EndDate) {
      con.put('EndDate', effectiveEndDate);
    }
    return true;
  }

  /** Full terminate-all / signed path: keep contract terminated when every standard line ends on/before today. */
  @TestVisible
  private static void applyFullTerminationContractStatus(
    Contract con,
    Date terminationDate
  ) {
    if (con == null || terminationDate == null) {
      return;
    }
    con.Status = 'Terminated';
    con.Contract_Termination_Date__c = terminationDate;
  }

  /**
   * Visible non–Contract-Terms lines that are fully terminated on the draft (bounded ends, none after today).
   */
  @TestVisible
  private static Boolean isFullTerminationDraft(List<OrderItem> items) {
    if (items == null || items.isEmpty()) {
      return false;
    }
    Boolean hasRollupLine = false;
    Date today = Date.today();
    for (OrderItem oi : items) {
      if (!isPackageRollupLine(oi)) {
        continue;
      }
      hasRollupLine = true;
      if (oi.EndDate == null || oi.EndDate > today) {
        return false;
      }
    }
    return hasRollupLine;
  }

  @TestVisible
  private static Date deriveMaxVisibleStandardEndDate(List<OrderItem> items) {
    Date maxEnd = null;
    if (items == null) {
      return null;
    }
    for (OrderItem oi : items) {
      if (!isPackageRollupLine(oi) || oi.EndDate == null) {
        continue;
      }
      if (maxEnd == null || oi.EndDate > maxEnd) {
        maxEnd = oi.EndDate;
      }
    }
    return maxEnd;
  }

  /** Earliest future start among visible CT replacement children (credit rollover). */
  @TestVisible
  private static Date deriveEarliestFutureContractTermsReplacementStart(
    List<OrderItem> items,
    Date referenceDate
  ) {
    if (items == null || referenceDate == null) {
      return null;
    }
    Date earliest = null;
    for (OrderItem oi : items) {
      if (!isLineVisible(oi) || !isContractTermsLineItem(oi)) {
        continue;
      }
      if (oi.Replaced_Order_Product__c == null || oi.ServiceDate == null) {
        continue;
      }
      if (oi.ServiceDate <= referenceDate) {
        continue;
      }
      if (earliest == null || oi.ServiceDate < earliest) {
        earliest = oi.ServiceDate;
      }
    }
    return earliest;
  }

  /** Max EndDate across visible lines (platform validation includes Contract Terms). */
  @TestVisible
  private static Date deriveMaxVisibleLineEndDate(List<OrderItem> items) {
    Date maxEnd = null;
    if (items == null) {
      return null;
    }
    for (OrderItem oi : items) {
      if (!isLineVisible(oi) || oi.EndDate == null) {
        continue;
      }
      if (maxEnd == null || oi.EndDate > maxEnd) {
        maxEnd = oi.EndDate;
      }
    }
    return maxEnd;
  }

  /**
   * Before package end shrinks below a bounded CT parent: hard-delete future-start CT replacement
   * children (ServiceDate > cutoff) and clear the replaced parent's EndDate.
   */
  @AuraEnabled
  public static void reconcileContractTermsForCutoff(
    Id draftOrderId,
    Date cutoffDate
  ) {
    if (draftOrderId == null || cutoffDate == null) {
      return;
    }

    List<Order> orders = [
      SELECT Id, Status
      FROM Order
      WHERE Id = :draftOrderId
      LIMIT 1
    ];
    if (orders.isEmpty()) {
      throw new AuraHandledException('Draft order not found.');
    }
    Order ord = orders[0];
    if (ord.Status != 'Draft' && ord.Status != 'Negotiation') {
      return;
    }

    List<OrderItem> allItems = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        Replaced_Order_Product__c,
        Is_Line_Deleted__c,
        Product2.Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrderId
    ];

    List<OrderItem> replacementsToHardDelete = new List<OrderItem>();
    Set<Id> parentIdsToClearEnd = new Set<Id>();

    for (OrderItem oi : allItems) {
      if (!isLineVisible(oi) || !isContractTermsLineItem(oi)) {
        continue;
      }
      if (oi.Replaced_Order_Product__c == null) {
        continue;
      }
      if (oi.ServiceDate != null && oi.ServiceDate > cutoffDate) {
        replacementsToHardDelete.add(oi);
        parentIdsToClearEnd.add(oi.Replaced_Order_Product__c);
      }
    }

    if (replacementsToHardDelete.isEmpty()) {
      return;
    }

    Boolean prevSkipDateSync = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMpSuppress = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    OrderItemTriggerHandler.enterContractTermMeterEndDateNormalizeSuppress();
    try {
      hardDeleteLinesWithPayments(replacementsToHardDelete);

      if (!parentIdsToClearEnd.isEmpty()) {
        List<OrderItem> parentPatches = new List<OrderItem>();
        for (Id parentId : parentIdsToClearEnd) {
          parentPatches.add(new OrderItem(Id = parentId, EndDate = null));
        }
        update parentPatches;
      }
    } finally {
      OrderItemTriggerHandler.exitContractTermMeterEndDateNormalizeSuppress();
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkipDateSync;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMpSuppress;
    }
  }

  private static List<OrderItem> queryOrderItemsForActivation(Id orderId) {
    return [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        Original_Start_Date__c,
        Original_Order_Product__c,
        Change_Type__c,
        Replaced_Order_Product__c,
        Access_Type__c,
        PricebookEntryId,
        Changed_Access_Type__c,
        OrderId,
        Is_Line_Deleted__c,
        Product2.Type__c
      FROM OrderItem
      WHERE OrderId = :orderId
    ];
  }

  /**
   * Activates a draft order and archives the previous active order.
   * For replacement drafts (Previous_Order__c), curtails the previous order's lines before archive;
   * OrderTriggerHandler still curtails on activation (same dates) and handles monthly payments.
   */
  @AuraEnabled
  public static void activateDraftOrder(Id orderId, Date replacementStartDate) {
    try {
      Order draftOrder = [
        SELECT
          Id,
          Status,
          Previous_Order__c,
          EffectiveDate,
          Order_Start_Date__c,
          EndDate,
          ContractId
        FROM Order
        WHERE Id = :orderId
        LIMIT 1
      ];
      if (draftOrder.Status == 'Activated') {
        // Idempotent: concurrent Signed/Activate clicks or a stale UI retry after success.
        return;
      }
      if (draftOrder.Status != 'Draft' && draftOrder.Status != 'Negotiation') {
        throw new AuraHandledException(
          'Order must be in Draft or Negotiation status.'
        );
      }

      // Set order start from contract; EffectiveDate must not be later than any product start (validation).
      Contract con = [
        SELECT
          Id,
          StartDate,
          EndDate,
          Status,
          Contract_Termination_Date__c,
          Contract_Termination_Reason__c
        FROM Contract
        WHERE Id = :draftOrder.ContractId
        LIMIT 1
      ];
      List<OrderItem> items = queryOrderItemsForActivation(orderId);
      // Expired lines that existed on an activated order retain history; draft-only
      // lines never happened and are permanently removed.
      List<OrderItem> expiredActivatedItems = new List<OrderItem>();
      List<OrderItem> expiredNeverActivatedItems = new List<OrderItem>();
      Date today = Date.today();
      for (OrderItem oi : items) {
        if (!isLineVisible(oi)) {
          continue;
        }
        if (oi.EndDate != null && oi.EndDate < today) {
          if (oi.Original_Order_Product__c != null) {
            expiredActivatedItems.add(oi);
          } else {
            expiredNeverActivatedItems.add(oi);
          }
        }
      }
      Boolean prevSkipDateSync = OrderItemTriggerHandler.SKIP_DATE_SYNC;
      Boolean prevMpSuppress = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
      OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
      try {
        Set<Id> restoredParentIds = new Set<Id>();
        if (!expiredNeverActivatedItems.isEmpty()) {
          restoredParentIds.addAll(
            restoreParentsForHardDeletedReplacements(expiredNeverActivatedItems)
          );
          hardDeleteLinesWithPayments(expiredNeverActivatedItems);
        }
        if (!expiredActivatedItems.isEmpty()) {
          List<OrderItem> activatedItemsToSoftDelete = new List<OrderItem>();
          for (OrderItem oi : expiredActivatedItems) {
            if (!restoredParentIds.contains(oi.Id)) {
              activatedItemsToSoftDelete.add(oi);
            }
          }
          markLinesSoftDeletedOnActivation(activatedItemsToSoftDelete);
        }
        items = queryOrderItemsForActivation(orderId);
      } finally {
        OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkipDateSync;
        OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMpSuppress;
      }

      if (isFullTerminationDraft(items)) {
        Date cutoffDate = deriveMaxVisibleStandardEndDate(items);
        if (cutoffDate != null) {
          reconcileContractTermsForCutoff(orderId, cutoffDate);
          items = queryOrderItemsForActivation(orderId);
        }
      }

      Date orderStart = con.StartDate;
      for (OrderItem oi : items) {
        if (!isLineVisible(oi)) {
          continue;
        }
        if (
          oi.ServiceDate != null &&
          (orderStart == null ||
          oi.ServiceDate < orderStart)
        ) {
          orderStart = oi.ServiceDate;
        }
      }
      if (orderStart == null) {
        orderStart = con.StartDate != null
          ? con.StartDate
          : replacementStartDate;
      }
      Date finalEffectiveDate;
      if (replacementStartDate != null) {
        finalEffectiveDate = replacementStartDate;
      } else {
        finalEffectiveDate = orderStart;
      }
      Date activationOrderStart = finalEffectiveDate;
      for (OrderItem oi : items) {
        if (!isLineVisible(oi)) {
          continue;
        }
        if (oi.ServiceDate == null) {
          continue;
        }
        if (
          activationOrderStart == null ||
          oi.ServiceDate < activationOrderStart
        ) {
          activationOrderStart = oi.ServiceDate;
        }
      }

      draftOrder.Order_Start_Date__c = activationOrderStart;
      Date derivedEndDate = deriveMaxOrderEndDateFromItems(
        items,
        draftOrder.EndDate
      );
      if (derivedEndDate == null) {
        for (OrderItem oi : items) {
          if (
            !isLineVisible(oi) ||
            !isPackageRollupLine(oi) ||
            oi.EndDate == null
          ) {
            continue;
          }
          if (derivedEndDate == null || oi.EndDate > derivedEndDate) {
            derivedEndDate = oi.EndDate;
          }
        }
        if (derivedEndDate == null && draftOrder.EndDate != null) {
          derivedEndDate = draftOrder.EndDate;
        }
      }
      if (!isFullTerminationDraft(items)) {
        Date requiredEnd = deriveEarliestFutureContractTermsReplacementStart(
          items,
          today
        );
        Date maxVisibleLineEnd = deriveMaxVisibleLineEndDate(items);
        if (
          maxVisibleLineEnd != null &&
          (requiredEnd == null ||
          maxVisibleLineEnd > requiredEnd)
        ) {
          requiredEnd = maxVisibleLineEnd;
        }
        if (
          requiredEnd != null &&
          (derivedEndDate == null ||
          derivedEndDate < requiredEnd)
        ) {
          derivedEndDate = requiredEnd;
        }
      }
      draftOrder.put('EndDate', derivedEndDate);
      if (derivedEndDate != null) {
        PackageEndDateRollupService.extendContractsToCoverOrderEndDates(
          new List<Order>{ draftOrder }
        );
      }
      // Replacement floor for payment split on old order items (ContractService.deleteAllMonthlyPaymentNotRelevant).
      draftOrder.Replacement_Start_Date__c = replacementStartDate != null
        ? replacementStartDate
        : activationOrderStart;
      draftOrder.Status = 'Activated';

      Boolean contractNeedsUpdate = false;
      if (isFullTerminationDraft(items)) {
        if (derivedEndDate != null) {
          applyFullTerminationContractStatus(con, derivedEndDate);
          if (String.isBlank(con.Contract_Termination_Reason__c)) {
            con.Contract_Termination_Reason__c = 'Optimization Process';
          }
          contractNeedsUpdate = true;
        }
      } else {
        contractNeedsUpdate = reactivateTerminatedContractIfApplicable(
          con,
          derivedEndDate
        );
      }

      // Preserve draft line dates on activation; Package Builder should activate with the dates users set.

      // Many orgs allow only one Activated order per contract. Archive the previous order first, then activate the draft (two DML calls).
      if (draftOrder.Previous_Order__c != null) {
        Order previousOrder = [
          SELECT Id, Status, EndDate, EffectiveDate, Order_Start_Date__c
          FROM Order
          WHERE Id = :draftOrder.Previous_Order__c
          LIMIT 1
        ];
        previousOrder.Status = 'Archived';
        List<Database.SaveResult> archiveResults = Database.update(
          new List<Order>{ previousOrder },
          false
        );
        for (Database.SaveResult sr : archiveResults) {
          if (!sr.isSuccess()) {
            String errMsg = '';
            for (Database.Error err : sr.getErrors()) {
              errMsg += err.getMessage() + ' ';
            }
            throw new AuraHandledException(
              'Previous order archive failed: ' + errMsg.trim()
            );
          }
        }
      }

      List<Database.SaveResult> activateResults = Database.update(
        new List<Order>{ draftOrder },
        false
      );
      for (Database.SaveResult sr : activateResults) {
        if (!sr.isSuccess()) {
          String errMsg = '';
          for (Database.Error err : sr.getErrors()) {
            errMsg += err.getMessage() + ' ';
          }
          throw new AuraHandledException(
            'Draft order activation failed: ' + errMsg.trim()
          );
        }
      }

      if (contractNeedsUpdate) {
        update con;
      }

      // Safety net: lines that still have no payments after activation (e.g. added mid-draft without trigger path).
      if (!skipActivatePaymentBackfill) {
        backfillMissingMonthlyPaymentsForOrderItems(orderId, null);
      }

      publishEvent();
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error activating draft order: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
    }
  }

  /**
   * Past-start split replacement delete: access-type flag or quantity split heuristic
   * (same product, parent Removed, parent start in past, child start after parent, same access type).
   */
  @TestVisible
  public static Boolean isPastStartSplitReplacementForUndo(
    OrderItem replacement,
    OrderItem replacedParent
  ) {
    if (replacement == null || replacedParent == null) {
      return false;
    }
    if (replacement.Changed_Access_Type__c == true) {
      return true;
    }
    if (replacedParent.Change_Type__c != 'Removed') {
      return false;
    }
    if (
      replacement.ServiceDate == null ||
      replacedParent.ServiceDate == null ||
      replacement.ServiceDate <= replacedParent.ServiceDate
    ) {
      return false;
    }
    if (replacedParent.ServiceDate >= Date.today()) {
      return false;
    }
    if (
      replacement.PricebookEntryId != null &&
      replacedParent.PricebookEntryId != null &&
      replacement.PricebookEntryId != replacedParent.PricebookEntryId
    ) {
      return false;
    }
    String childAccessType = replacement.Access_Type__c;
    String parentAccessType = replacedParent.Access_Type__c;
    if (String.isBlank(childAccessType) || String.isBlank(parentAccessType)) {
      return false;
    }
    return childAccessType.equalsIgnoreCase(parentAccessType.trim());
  }

  @TestVisible
  private static Date resolveReplacedEndDateOnReplacementDelete(
    Date replacementEnd,
    Date activeEnd,
    Boolean undoPastStartSplit,
    String replacedAccessType,
    Boolean undoAccessTypeChangeReplacement
  ) {
    if (
      undoPastStartSplit == true &&
      String.isNotBlank(replacedAccessType) &&
      'Monthly'.equalsIgnoreCase(replacedAccessType.trim())
    ) {
      return null;
    }
    if (undoAccessTypeChangeReplacement == true && replacementEnd == null) {
      return activeEnd;
    }
    if (replacementEnd == null) {
      return null;
    }
    if (activeEnd == null) {
      return replacementEnd;
    }
    return replacementEnd > activeEnd ? replacementEnd : activeEnd;
  }

  /**
   * Extends draft Order/Contract end for visible bounded lines. Soft-deleted lines are excluded
   * because archive-on-delete clears live ServiceDate/EndDate before rollups run.
   */
  @TestVisible
  public static void prepareDraftOrderEndForLineSave(
    Id orderId,
    Date targetOrderEnd
  ) {
    if (orderId == null || targetOrderEnd == null) {
      return;
    }
    PackageEndDateRollupService.applyContractThenOrderEndForPackage(
      orderId,
      targetOrderEnd
    );
  }

  /**
   * Before Package Builder line DML: extend draft Order/Contract end for visible bounded lines,
   * including Termination_Reason-only saves.
   */
  public static void reconcileDraftOrderEndBeforeLineItemSave(
    List<SObject> concreteItems,
    Map<Id, OrderItem> existingOrderItemsById
  ) {
    if (
      concreteItems == null ||
      concreteItems.isEmpty() ||
      existingOrderItemsById == null ||
      existingOrderItemsById.isEmpty()
    ) {
      return;
    }

    Set<Id> draftOrderIds = new Set<Id>();
    Map<Id, Date> maxIncomingEndByOrderId = new Map<Id, Date>();
    Map<Id, Date> currentOrderEndByOrderId = new Map<Id, Date>();

    for (SObject item : concreteItems) {
      if (item == null) {
        continue;
      }
      Id oiId = (Id) item.get('Id');
      OrderItem existing = existingOrderItemsById.get(oiId);
      if (
        existing == null ||
        existing.OrderId == null ||
        existing.Order == null
      ) {
        continue;
      }
      if (
        existing.Order.Status == 'Cancelled' ||
        existing.Order.Status == 'Archived'
      ) {
        continue;
      }
      if (
        existing.Order.Status != 'Draft' &&
        existing.Order.Status != 'Negotiation'
      ) {
        continue;
      }

      Id orderId = existing.OrderId;
      draftOrderIds.add(orderId);
      currentOrderEndByOrderId.put(orderId, existing.Order.EndDate);

      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      if (!fields.containsKey('EndDate')) {
        continue;
      }
      Date incomingEnd = (Date) item.get('EndDate');
      if (incomingEnd == null) {
        continue;
      }
      Date currentMax = maxIncomingEndByOrderId.get(orderId);
      if (currentMax == null || incomingEnd > currentMax) {
        maxIncomingEndByOrderId.put(orderId, incomingEnd);
      }
    }

    if (draftOrderIds.isEmpty()) {
      return;
    }

    for (AggregateResult ar : [
      SELECT OrderId oid, MAX(EndDate) maxEnd
      FROM OrderItem
      WHERE
        OrderId IN :draftOrderIds
        AND EndDate != NULL
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      GROUP BY OrderId
    ]) {
      Id oid = (Id) ar.get('oid');
      Date persistedMax = (Date) ar.get('maxEnd');
      if (oid == null || persistedMax == null) {
        continue;
      }
      Date prior = maxIncomingEndByOrderId.get(oid);
      if (prior == null || persistedMax > prior) {
        maxIncomingEndByOrderId.put(oid, persistedMax);
      }
    }

    for (Id orderId : draftOrderIds) {
      Date targetEnd = maxIncomingEndByOrderId.get(orderId);
      if (targetEnd == null) {
        continue;
      }
      Date currentOrderEnd = currentOrderEndByOrderId.get(orderId);
      if (currentOrderEnd != null && targetEnd <= currentOrderEnd) {
        continue;
      }
      prepareDraftOrderEndForLineSave(orderId, targetEnd);
    }
  }

  /**
   * Extends draft Order.EndDate (and Contract when linked) so pending line EndDate(s)
   * pass platform validation, including when the order was previously open-ended (EndDate null).
   */
  @TestVisible
  private static Date ensureDraftOrderEndCoversLineEndDates(
    Id orderId,
    Iterable<OrderItem> lines
  ) {
    return ensureDraftOrderEndCoversLineEndDates(orderId, lines, null);
  }

  @TestVisible
  private static Date ensureDraftOrderEndCoversLineEndDates(
    Id orderId,
    Iterable<OrderItem> lines,
    Map<Id, OrderItem> originalsById
  ) {
    if (orderId == null || lines == null) {
      return null;
    }
    Date maxLineEnd = null;
    for (OrderItem oi : lines) {
      if (oi == null || oi.EndDate == null) {
        continue;
      }
      if (!isLineVisible(oi)) {
        continue;
      }
      if (originalsById != null) {
        OrderItem before = originalsById.get(oi.Id);
        if (before != null && before.EndDate == oi.EndDate) {
          continue;
        }
      }
      if (maxLineEnd == null || oi.EndDate > maxLineEnd) {
        maxLineEnd = oi.EndDate;
      }
    }

    if (maxLineEnd != null) {
      for (AggregateResult ar : [
        SELECT MAX(EndDate) maxEnd
        FROM OrderItem
        WHERE
          OrderId = :orderId
          AND EndDate != NULL
          AND (Is_Line_Deleted__c = FALSE
          OR Is_Line_Deleted__c = NULL)
          AND (Product2.Type__c = NULL
          OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
      ]) {
        Date persistedMax = (Date) ar.get('maxEnd');
        if (
          persistedMax != null &&
          (maxLineEnd == null ||
          persistedMax > maxLineEnd)
        ) {
          maxLineEnd = persistedMax;
        }
      }
    }

    if (maxLineEnd == null) {
      return null;
    }

    List<Order> orders = [
      SELECT Id, Status, EndDate, ContractId
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (orders.isEmpty()) {
      return null;
    }
    Order ord = orders[0];
    if (ord.Status == 'Cancelled' || ord.Status == 'Archived') {
      return ord.EndDate;
    }
    if (ord.EndDate != null && maxLineEnd <= ord.EndDate) {
      return ord.EndDate;
    }

    prepareDraftOrderEndForLineSave(orderId, maxLineEnd);
    return maxLineEnd;
  }

  /**
   * Full-termination cleanup: hard-delete future-start standard lines. CT future-start replacements
   * are hard-deleted by {@link #reconcileContractTermsForCutoff} before this sweep runs.
   */
  @TestVisible
  private static void sweepOrderItemsForFullTermination(
    Id draftOrderId,
    Date exitDate
  ) {
    if (draftOrderId == null || exitDate == null) {
      return;
    }

    List<OrderItem> allItems = [
      SELECT
        Id,
        ServiceDate,
        EndDate,
        Original_Start_Date__c,
        Original_End_Date__c,
        Is_Line_Deleted__c,
        Replaced_Order_Product__c,
        Original_Order_Product__c,
        Change_Type__c,
        Access_Type__c,
        PricebookEntryId,
        Changed_Access_Type__c,
        OrderId,
        Product2.Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrderId
    ];

    List<OrderItem> toHardDelete = new List<OrderItem>();

    for (OrderItem oi : allItems) {
      Date lineStart = effectiveArchivedLineStart(oi);

      if (oi.Is_Line_Deleted__c == true) {
        if (
          lineStart != null &&
          lineStart > exitDate &&
          !isContractTermsLineItem(oi)
        ) {
          toHardDelete.add(oi);
        }
        continue;
      }

      Boolean futureStart = lineStart != null && lineStart > exitDate;
      if (futureStart) {
        if (isContractTermsLineItem(oi)) {
          continue;
        }
        toHardDelete.add(oi);
      }
    }

    if (toHardDelete.isEmpty()) {
      return;
    }

    List<OrderItem> parentRestores = new List<OrderItem>();
    if (!toHardDelete.isEmpty()) {
      Set<Id> replacedIds = new Set<Id>();
      Map<Id, Date> replacementEndDateByReplacedId = new Map<Id, Date>();
      Map<Id, Boolean> pastStartSplitUndoByReplacedId = new Map<Id, Boolean>();
      Map<Id, Boolean> accessTypeChangeUndoByReplacedId = new Map<Id, Boolean>();
      for (OrderItem oi : toHardDelete) {
        if (oi.Replaced_Order_Product__c != null) {
          replacedIds.add(oi.Replaced_Order_Product__c);
          replacementEndDateByReplacedId.put(
            oi.Replaced_Order_Product__c,
            oi.EndDate
          );
          if (oi.Changed_Access_Type__c == true) {
            accessTypeChangeUndoByReplacedId.put(
              oi.Replaced_Order_Product__c,
              true
            );
          }
        }
      }
      Map<Id, OrderItem> replacedParentsById = new Map<Id, OrderItem>();
      if (!replacedIds.isEmpty()) {
        replacedParentsById = new Map<Id, OrderItem>(
          [
            SELECT
              Id,
              Change_Type__c,
              EndDate,
              ServiceDate,
              Original_Order_Product__c,
              OrderId,
              Access_Type__c,
              PricebookEntryId
            FROM OrderItem
            WHERE Id IN :replacedIds
          ]
        );
        for (OrderItem oi : toHardDelete) {
          if (oi.Replaced_Order_Product__c == null) {
            continue;
          }
          OrderItem replacedParent = replacedParentsById.get(
            oi.Replaced_Order_Product__c
          );
          if (isPastStartSplitReplacementForUndo(oi, replacedParent)) {
            pastStartSplitUndoByReplacedId.put(
              oi.Replaced_Order_Product__c,
              true
            );
          }
        }
      }
      if (!replacedParentsById.isEmpty()) {
        List<OrderItem> replacedItems = replacedParentsById.values();
        Set<Id> activeLineIds = new Set<Id>();
        for (OrderItem replaced : replacedItems) {
          if (replaced.Original_Order_Product__c != null) {
            activeLineIds.add(replaced.Original_Order_Product__c);
          }
        }
        Map<Id, OrderItem> activeLinesById = new Map<Id, OrderItem>();
        if (!activeLineIds.isEmpty()) {
          activeLinesById = new Map<Id, OrderItem>(
            [
              SELECT Id, EndDate
              FROM OrderItem
              WHERE Id IN :activeLineIds
            ]
          );
        }
        for (OrderItem replaced : replacedItems) {
          replaced.Change_Type__c = null;
          Date replacementEnd = replacementEndDateByReplacedId.get(replaced.Id);
          Date activeEnd = null;
          if (replaced.Original_Order_Product__c != null) {
            OrderItem activeLine = activeLinesById.get(
              replaced.Original_Order_Product__c
            );
            if (activeLine != null) {
              activeEnd = activeLine.EndDate;
            }
          }
          Date resolvedEnd = resolveReplacedEndDateOnReplacementDelete(
            replacementEnd,
            activeEnd,
            pastStartSplitUndoByReplacedId.get(replaced.Id) == true,
            replaced.Access_Type__c,
            accessTypeChangeUndoByReplacedId.get(replaced.Id) == true
          );
          replaced.put('EndDate', resolvedEnd);
          parentRestores.add(replaced);
        }
      }
    }

    Boolean prevSkipDateSync = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMpSuppress = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    OrderItemTriggerHandler.enterContractTermMeterEndDateNormalizeSuppress();
    try {
      if (!parentRestores.isEmpty()) {
        Map<Id, List<OrderItem>> pendingByOrderId = new Map<Id, List<OrderItem>>();
        for (OrderItem replaced : parentRestores) {
          if (replaced == null || replaced.OrderId == null) {
            continue;
          }
          if (!pendingByOrderId.containsKey(replaced.OrderId)) {
            pendingByOrderId.put(replaced.OrderId, new List<OrderItem>());
          }
          pendingByOrderId.get(replaced.OrderId).add(replaced);
        }
        for (Id pendingOrderId : pendingByOrderId.keySet()) {
          ensureDraftOrderEndCoversLineEndDates(
            pendingOrderId,
            pendingByOrderId.get(pendingOrderId),
            null
          );
        }
        update parentRestores;
      }
      if (!toHardDelete.isEmpty()) {
        List<Database.DeleteResult> deleteResults = Database.delete(
          toHardDelete,
          false
        );
        for (Database.DeleteResult dr : deleteResults) {
          if (!dr.isSuccess()) {
            String errMsg = '';
            for (Database.Error err : dr.getErrors()) {
              errMsg += err.getMessage() + ' ';
            }
            throw new AuraHandledException(
              'Full termination line cleanup failed: ' + errMsg.trim()
            );
          }
        }
      }
    } finally {
      OrderItemTriggerHandler.exitContractTermMeterEndDateNormalizeSuppress();
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkipDateSync;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMpSuppress;
    }
  }

  /**
   * Finalizes a "terminate all" operation by recalculating parent EndDates using the special rule:
   * - Contract Terms (Product2.Type__c == 'Contract Terms') with blank EndDate do NOT force open-ended parents.
   * - Bounded Contract Terms still contribute to MAX EndDate.
   *
   * Then activates the draft order when the business "exit" date is today-or-future OR the derived max product end
   * date is today-or-future (relative to today in the running org).
   *
   * Note: if the draft is effectively open-ended (maxEndDate is null because of included blank EndDate lines),
   * we do not auto-activate here unless an Exit Date is provided (bounded exit intent) — otherwise activation
   * can violate platform parent/child rules.
   */
  @AuraEnabled
  public static void finalizeTerminateAll(
    Id contractId,
    Id draftOrderId,
    String terminationReason,
    Date exitDate
  ) {
    if (contractId == null || draftOrderId == null) {
      throw new AuraHandledException(
        'ContractId and DraftOrderId are required.'
      );
    }

    Date today = Date.today();
    Order draftOrder = [
      SELECT Id, Status, EffectiveDate, Order_Start_Date__c, EndDate, ContractId
      FROM Order
      WHERE Id = :draftOrderId
      LIMIT 1
    ];
    if (draftOrder.ContractId != contractId) {
      throw new AuraHandledException(
        'Draft order does not belong to the given contract.'
      );
    }
    if (draftOrder.Status != 'Draft' && draftOrder.Status != 'Negotiation') {
      return;
    }

    if (exitDate != null) {
      reconcileContractTermsForCutoff(draftOrderId, exitDate);
      sweepOrderItemsForFullTermination(draftOrderId, exitDate);
      draftOrder = [
        SELECT
          Id,
          Status,
          EffectiveDate,
          Order_Start_Date__c,
          EndDate,
          ContractId
        FROM Order
        WHERE Id = :draftOrderId
        LIMIT 1
      ];
    }

    List<OrderItem> items = [
      SELECT Id, EndDate, Is_Line_Deleted__c, Product2.Type__c
      FROM OrderItem
      WHERE OrderId = :draftOrderId
    ];
    Date maxEndDate = deriveMaxOrderEndDateFromItems(items, draftOrder.EndDate);
    if (maxEndDate == null && exitDate != null) {
      for (OrderItem oi : items) {
        if (
          !isLineVisible(oi) ||
          !isPackageRollupLine(oi) ||
          oi.EndDate == null
        ) {
          continue;
        }
        if (maxEndDate == null || oi.EndDate > maxEndDate) {
          maxEndDate = oi.EndDate;
        }
      }
      if (maxEndDate == null && exitDate >= Date.today()) {
        maxEndDate = exitDate;
      }
    }

    Contract con = [
      SELECT
        Id,
        Status,
        EndDate,
        Contract_Termination_Date__c,
        Contract_Termination_Reason__c
      FROM Contract
      WHERE Id = :contractId
      LIMIT 1
      FOR UPDATE
    ];

    // Ensure Contract.EndDate is never shorter than any non-cancelled/archived Order EndDate on the contract.
    // Otherwise downstream automation (e.g. Contract After Save) can try to align Order/OrderItem dates to a
    // termination date while other Orders still have a later Customer Package End Date than Contract.EndDate.
    Date maxOrderEndAcrossContract = null;
    for (AggregateResult ar : [
      SELECT MAX(EndDate) maxEnd
      FROM Order
      WHERE
        ContractId = :contractId
        AND Status NOT IN ('Cancelled', 'Archived')
        AND EndDate != NULL
    ]) {
      maxOrderEndAcrossContract = (Date) ar.get('maxEnd');
    }

    Date targetContractEndDate = maxEndDate;
    if (
      maxOrderEndAcrossContract != null &&
      (targetContractEndDate == null ||
      maxOrderEndAcrossContract > targetContractEndDate)
    ) {
      targetContractEndDate = maxOrderEndAcrossContract;
    }
    if (
      con.EndDate != null &&
      (targetContractEndDate == null ||
      con.EndDate > targetContractEndDate)
    ) {
      targetContractEndDate = con.EndDate;
    }
    // Exit date represents a bounded business intent even when line ends lag behind (e.g. user terminated
    // products to yesterday but exits tomorrow). Ensure parent Contract.EndDate can legally cover that intent
    // before we bump OrderItem ends / Order.EndDate.
    if (
      exitDate != null &&
      (targetContractEndDate == null ||
      exitDate > targetContractEndDate)
    ) {
      targetContractEndDate = exitDate;
    }

    // When exit date is after the current max line end, extend Order.EndDate only. Line-item updates are
    // handled by Package Builder saveLineItems (products ending before exit date are intentionally skipped).
    if (exitDate != null && maxEndDate != null && exitDate > maxEndDate) {
      Date desiredOrderEnd = draftOrder.EndDate;
      if (desiredOrderEnd == null || exitDate > desiredOrderEnd) {
        desiredOrderEnd = exitDate;
      }
      if (draftOrder.EndDate != desiredOrderEnd) {
        draftOrder.put('EndDate', desiredOrderEnd);
        update draftOrder;
      }
      // Keep maxEndDate derived from visible product ends; exit date alone must not extend
      // Contract_Termination_Date__c when lines still end earlier (UI bumps lines first).
    }

    List<SObject> toUpdate = new List<SObject>();
    // Align draft Customer Package End Date to derived max line end (shrink or extend).
    // Extend-only logic left order end ahead of curtailed products and activation then failed
    // with "Customer Package End Date can't be earlier than its products' end dates."
    if (maxEndDate != null && draftOrder.EndDate != maxEndDate) {
      draftOrder.put('EndDate', maxEndDate);
      toUpdate.add(draftOrder);
    }
    if (con.EndDate != targetContractEndDate) {
      con.put('EndDate', targetContractEndDate);
    }
    if (con.Contract_Termination_Date__c != maxEndDate) {
      con.Contract_Termination_Date__c = maxEndDate;
    }
    if (
      !String.isBlank(terminationReason) &&
      con.Contract_Termination_Reason__c != terminationReason
    ) {
      con.Contract_Termination_Reason__c = terminationReason;
    }

    Boolean fullTermination = isFullTerminationDraft(items);

    Boolean hasBoundedMaxEnd = maxEndDate != null;
    Boolean boundedExitIntent =
      exitDate != null && (maxEndDate == null || exitDate >= maxEndDate);
    Boolean shouldActivate =
      (hasBoundedMaxEnd &&
      (maxEndDate >= today || (exitDate != null && exitDate >= today))) ||
      (!hasBoundedMaxEnd &&
      boundedExitIntent &&
      exitDate >= today);
    if (fullTermination) {
      if (maxEndDate != null) {
        applyFullTerminationContractStatus(con, maxEndDate);
      }
    } else if (shouldActivate) {
      reactivateTerminatedContractIfApplicable(con, maxEndDate);
    }

    toUpdate.add(con);
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }

    if (shouldActivate) {
      Date replacementStart = draftOrder.Order_Start_Date__c != null
        ? draftOrder.Order_Start_Date__c
        : draftOrder.EffectiveDate;
      activateDraftOrder(draftOrderId, replacementStart);
    }
  }

  // Backward-compatible overload for existing internal Apex callers/tests.
  public static void finalizeTerminateAll(Id contractId, Id draftOrderId) {
    finalizeTerminateAll(contractId, draftOrderId, null, null);
  }

  public static void finalizeTerminateAll(
    Id contractId,
    Id draftOrderId,
    String terminationReason
  ) {
    finalizeTerminateAll(contractId, draftOrderId, terminationReason, null);
  }

  /**
   * Updates an Order's Status between Draft and Negotiation.
   * Intended for Package Builder status path transitions only.
   */
  @AuraEnabled
  public static void setOrderStatus(Id orderId, String newStatus) {
    try {
      if (orderId == null) {
        throw new AuraHandledException('Order Id is required.');
      }
      if (String.isBlank(newStatus)) {
        throw new AuraHandledException('New status is required.');
      }
      String normalized = newStatus.trim();
      if (normalized != 'Draft' && normalized != 'Negotiation') {
        throw new AuraHandledException(
          'Only Draft or Negotiation status is allowed.'
        );
      }

      Order ord = [
        SELECT Id, Status
        FROM Order
        WHERE Id = :orderId
        LIMIT 1
      ];
      if (ord.Status == 'Activated' || ord.Status == 'Archived') {
        throw new AuraHandledException(
          'Cannot change status for Activated or Archived orders.'
        );
      }
      if (ord.Status != 'Draft' && ord.Status != 'Negotiation') {
        throw new AuraHandledException(
          'Only Draft/Negotiation orders can be updated from Package Builder.'
        );
      }

      if (ord.Status != normalized) {
        ord.Status = normalized;
        update ord;
      }
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error updating order status: ' + e.getMessage()
      );
    }
  }

  /**
   * Soft-removes a draft order from Package Builder by setting Status to Cancelled.
   */
  public static void cancelDraftOrder(Id draftOrderId) {
    try {
      if (draftOrderId == null) {
        throw new AuraHandledException('Draft order Id is required.');
      }
      List<Order> orders = [
        SELECT Id, Status, ContractId
        FROM Order
        WHERE Id = :draftOrderId
        LIMIT 1
      ];
      if (orders.isEmpty()) {
        throw new AuraHandledException('Draft order not found.');
      }
      Order draftOrder = orders[0];
      if (draftOrder.Status != 'Draft' && draftOrder.Status != 'Negotiation') {
        throw new AuraHandledException(
          'Order must be in Draft or Negotiation status. Only working orders can be cancelled.'
        );
      }
      if (draftOrder.ContractId == null) {
        throw new AuraHandledException('Order must belong to a contract.');
      }
      draftOrder.Status = 'Cancelled';
      update draftOrder;
      publishEvent();
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error cancelling draft order: ' + e.getMessage()
      );
    }
  }

  /**
   * Returns KPI summary metrics for the given order.
   */
  @AuraEnabled(cacheable=true)
  public static OrderSummary getOrderSummary(Id orderId) {
    try {
      if (orderId == null)
        return new OrderSummary();

      List<Order> orders = [
        SELECT Id
        FROM Order
        WHERE Id = :orderId
        LIMIT 1
      ];
      if (orders.isEmpty()) {
        return new OrderSummary();
      }
      List<OrderItem> items = [
        SELECT
          Id,
          Is_Line_Deleted__c,
          Temporary__c,
          EndDate,
          Product2.Type__c,
          Product2.Sub_Type__c,
          UnitPrice,
          Quantity,
          TotalPrice,
          Adjusted_Total_Price__c
        FROM OrderItem
        WHERE OrderId = :orderId
      ];

      Decimal deskRevenue = 0;
      Decimal parkingRevenue = 0;
      Integer deskCount = 0;
      Integer parkingCount = 0;
      Decimal sumEffectiveAll = 0;

      for (OrderItem item : items) {
        if (!isIncludedInOrderSummary(item)) {
          continue;
        }
        Decimal lineEffective = item.Adjusted_Total_Price__c != null
          ? item.Adjusted_Total_Price__c
          : (item.TotalPrice != null ? item.TotalPrice : 0);
        sumEffectiveAll += lineEffective;
        if (item.Product2 == null) {
          continue;
        }
        String productType = item.Product2.Type__c;
        String subType = item.Product2.Sub_Type__c;

        if (productType == 'Standard Products' && subType != 'Parking') {
          deskRevenue += lineEffective;
          deskCount += 0;
        }

        if (subType == 'Parking') {
          parkingRevenue += lineEffective;
          parkingCount += (item.Quantity != null
            ? Integer.valueOf(item.Quantity)
            : 0);
        }
      }

      OrderSummary summary = new OrderSummary();
      // Always derive from filtered lines so Temporary / ended products are never counted.
      summary.totalMonthlyRevenue = sumEffectiveAll;
      summary.deskRevenue = deskRevenue;
      summary.deskCount = deskCount;
      summary.avgDeskPrice = (deskCount > 0)
        ? (deskRevenue / deskCount).setScale(2)
        : 0;
      summary.parkingRevenue = parkingRevenue;
      summary.parkingCount = parkingCount;
      summary.avgParkingPrice = (parkingCount > 0)
        ? (parkingRevenue / parkingCount).setScale(2)
        : 0;
      return summary;
    } catch (Exception e) {
      throw new AuraHandledException(
        'Error fetching order summary: ' + e.getMessage()
      );
    }
  }

  /**
   * Wrapper class for order summary KPI metrics.
   */
  public class OrderSummary {
    @AuraEnabled
    public Decimal totalMonthlyRevenue = 0;
    @AuraEnabled
    public Decimal deskRevenue = 0;
    @AuraEnabled
    public Integer deskCount = 0;
    @AuraEnabled
    public Decimal avgDeskPrice = 0;
    @AuraEnabled
    public Decimal parkingRevenue = 0;
    @AuraEnabled
    public Integer parkingCount = 0;
    @AuraEnabled
    public Decimal avgParkingPrice = 0;
  }

  // ─── Account Monthly Payment Summary (for Account record page LWC) ───

  /** Column definition: order item id, display label, contract id and name for links. */
  public class OrderItemColumnDto {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String contractId;
    @AuraEnabled
    public String contractName;
  }

  /** One row in the table: month label, amounts per column (same order as orderItemColumns), row total. */
  public class MonthRowDto {
    @AuraEnabled
    public Integer month;
    @AuraEnabled
    public String monthLabel;
    @AuraEnabled
    public List<Decimal> values;
    @AuraEnabled
    public Decimal rowTotal;
  }

  /** One year block: list of month rows plus year subtotals per column and grand total. */
  public class YearGroupDto {
    @AuraEnabled
    public Integer year;
    @AuraEnabled
    public List<MonthRowDto> monthRows;
    @AuraEnabled
    public List<Decimal> yearSubtotals;
    @AuraEnabled
    public Decimal yearGrandTotal;
  }

  /** Root DTO for account monthly payment summary. */
  public class AccountMonthlyPaymentSummaryDto {
    @AuraEnabled
    public List<OrderItemColumnDto> orderItemColumns;
    @AuraEnabled
    public List<YearGroupDto> yearGroups;
    /** When empty summary: number of activated contracts for the account (0 = none). Used to show "Activate an order" message. */
    @AuraEnabled
    public Integer activeContractCount;
    /** When empty summary: number of activated orders (on those contracts) with same filter as order items query. If > 0 but no items, order has no products. */
    @AuraEnabled
    public Integer activatedOrderCount;
  }

  /**
   * Returns monthly payment summary for an account: active contracts → active orders → order items → monthly payments.
   * Columns = order items, rows = months grouped by year, with row totals and year subtotals.
   */
  @AuraEnabled(cacheable=true)
  public static AccountMonthlyPaymentSummaryDto getAccountMonthlyPaymentSummary(
    Id accountId
  ) {
    AccountMonthlyPaymentSummaryDto dto = new AccountMonthlyPaymentSummaryDto();
    dto.orderItemColumns = new List<OrderItemColumnDto>();
    dto.yearGroups = new List<YearGroupDto>();

    if (accountId == null) {
      return dto;
    }

    // Get all order items where the related contract is activated so we show all products, not only those with payment records
    List<OrderItem> orderItems = [
      SELECT
        Id,
        Product2Id,
        Product2.Name,
        Contract__c,
        Contract__r.ContractNumber,
        Contract__r.Name
      FROM OrderItem
      WHERE
        Order.Contract.AccountId = :accountId
        AND Order.Contract.Status = 'Activated'
      ORDER BY OrderId, CreatedDate
    ];

    if (orderItems.isEmpty()) {
      // So the LWC can show a helpful message when account has active contracts but no activated order / no products
      List<AggregateResult> contractCount = [
        SELECT COUNT(Id) cnt
        FROM Contract
        WHERE AccountId = :accountId AND Status = 'Activated'
      ];
      dto.activeContractCount = (contractCount.size() == 1 &&
        contractCount[0].get('cnt') != null)
        ? Integer.valueOf(contractCount[0].get('cnt'))
        : 0;

      List<AggregateResult> orderCount = [
        SELECT COUNT(Id) cnt
        FROM Order
        WHERE Contract.AccountId = :accountId AND Contract.Status = 'Activated'
      ];
      dto.activatedOrderCount = (orderCount.size() == 1 &&
        orderCount[0].get('cnt') != null)
        ? Integer.valueOf(orderCount[0].get('cnt'))
        : 0;
      return dto;
    }

    dto.activeContractCount = 0;
    dto.activatedOrderCount = 0;

    // Build ordered list of columns grouped by product so the same product
    // (across multiple order items or contracts) appears only once.
    List<String> columnOrder = new List<String>();
    Map<String, String> labelByKey = new Map<String, String>();
    Map<String, Id> contractIdByKey = new Map<String, Id>();
    Map<String, String> contractNameByKey = new Map<String, String>();
    Map<Id, String> keyByOrderItemId = new Map<Id, String>();

    for (OrderItem oi : orderItems) {
      if (oi.Id == null || oi.Product2Id == null)
        continue;
      String key = String.valueOf(oi.Product2Id);

      if (!labelByKey.containsKey(key)) {
        String name = (oi.Product2 != null &&
          String.isNotBlank(oi.Product2.Name))
          ? oi.Product2.Name.trim()
          : 'Order Item';
        if (name.length() > 80)
          name = name.substring(0, 77) + '...';
        labelByKey.put(key, name);

        if (oi.Contract__c != null) {
          contractIdByKey.put(key, oi.Contract__c);
          String cName = String.isNotBlank(oi.Contract__r.ContractNumber)
            ? oi.Contract__r.ContractNumber
            : (String.isNotBlank(oi.Contract__r.Name)
                ? oi.Contract__r.Name
                : 'Contract');
          contractNameByKey.put(key, cName);
        }

        columnOrder.add(key);
      }

      keyByOrderItemId.put(oi.Id, key);
    }

    for (String key : columnOrder) {
      OrderItemColumnDto col = new OrderItemColumnDto();
      col.id = key;
      col.label = labelByKey.get(key);
      col.contractId = contractIdByKey.get(key);
      col.contractName = contractNameByKey.get(key);
      dto.orderItemColumns.add(col);
    }

    Set<Id> orderItemIdSet = new Set<Id>(keyByOrderItemId.keySet());

    List<MonthlyPayment__c> payments = [
      SELECT Id, OrderItem__c, Start_date__c, Price__c, Discount__c
      FROM MonthlyPayment__c
      WHERE
        OrderItem__r.Order.Contract.AccountId = :accountId
        AND OrderItem__r.Order.Contract.Status = 'Activated'
        AND Start_date__c != NULL
        AND OrderItem__c IN :orderItemIdSet
      ORDER BY Start_date__c ASC
    ];

    // Map column index by product key
    Map<String, Integer> columnIndexByKey = new Map<String, Integer>();
    for (Integer i = 0; i < columnOrder.size(); i++) {
      columnIndexByKey.put(columnOrder[i], i);
    }

    // Aggregate by (year, month, product key): same Apex math as syncOrderItemPriceRollups (not FinalPrice__c).
    Map<Integer, Map<Integer, Map<String, Decimal>>> amountByYearMonthKey = new Map<Integer, Map<Integer, Map<String, Decimal>>>();
    for (MonthlyPayment__c p : payments) {
      if (p.OrderItem__c == null || p.Start_date__c == null)
        continue;
      String key = keyByOrderItemId.get(p.OrderItem__c);
      if (key == null)
        continue;
      Integer y = p.Start_date__c.year();
      Integer m = p.Start_date__c.month();
      Decimal effective = monthlyLinePayableAmount(p.Price__c, p.Discount__c);

      if (!amountByYearMonthKey.containsKey(y)) {
        amountByYearMonthKey.put(y, new Map<Integer, Map<String, Decimal>>());
      }
      if (!amountByYearMonthKey.get(y).containsKey(m)) {
        amountByYearMonthKey.get(y).put(m, new Map<String, Decimal>());
      }
      Map<String, Decimal> cell = amountByYearMonthKey.get(y).get(m);
      Decimal existing = cell.containsKey(key) ? cell.get(key) : 0;
      cell.put(key, existing + effective);
    }

    // Build year groups with sorted months and subtotals
    List<Integer> years = new List<Integer>(amountByYearMonthKey.keySet());
    years.sort();
    String[] monthNames = new List<String>{
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

    for (Integer year : years) {
      YearGroupDto yg = new YearGroupDto();
      yg.year = year;
      yg.monthRows = new List<MonthRowDto>();
      yg.yearSubtotals = new List<Decimal>();
      for (Integer i = 0; i < columnOrder.size(); i++) {
        yg.yearSubtotals.add(0);
      }
      yg.yearGrandTotal = 0;

      Map<Integer, Map<String, Decimal>> monthData = amountByYearMonthKey.get(
        year
      );
      List<Integer> months = new List<Integer>(monthData.keySet());
      months.sort();

      for (Integer m : months) {
        MonthRowDto row = new MonthRowDto();
        row.month = m;
        row.monthLabel = monthNames[m - 1] + ' ' + year;
        row.values = new List<Decimal>();
        Decimal rowTotal = 0;
        for (String key : columnOrder) {
          Decimal amt = monthData.get(m).containsKey(key)
            ? monthData.get(m).get(key)
            : 0;
          row.values.add(amt.setScale(2, RoundingMode.HALF_UP));
          rowTotal += amt;
          yg.yearSubtotals.set(
            columnIndexByKey.get(key),
            yg.yearSubtotals.get(columnIndexByKey.get(key)) + amt
          );
        }
        row.rowTotal = rowTotal.setScale(2, RoundingMode.HALF_UP);
        yg.yearGrandTotal += rowTotal;
        yg.monthRows.add(row);
      }

      for (Integer i = 0; i < yg.yearSubtotals.size(); i++) {
        yg.yearSubtotals.set(
          i,
          yg.yearSubtotals.get(i).setScale(2, RoundingMode.HALF_UP)
        );
      }
      yg.yearGrandTotal = yg.yearGrandTotal.setScale(2, RoundingMode.HALF_UP);
      dto.yearGroups.add(yg);
    }

    return dto;
  }

  /**
   * Sum of payable monthly line amounts (same rules as monthlyPaymentLineAmount) per
   * OpportunityLineItem or OrderItem for Package Builder KPIs.
   *
   * @param parentRecordId Opportunity Id or Order Id
   * @return Map of line item Id to sum of monthly payment line amounts (empty when parent is null or unsupported type)
   */
  public static Map<Id, Decimal> getMonthlyPaymentPayableSumsForParentRecord(
    Id parentRecordId
  ) {
    Map<Id, Decimal> sums = new Map<Id, Decimal>();
    if (parentRecordId == null) {
      return sums;
    }
    String objName = parentRecordId.getSobjectType().getDescribe().getName();
    if ('Opportunity'.equals(objName)) {
      for (MonthlyPayment__c mp : [
        SELECT
          OpportunityLineItem__c,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE
          OpportunityLineItem__c IN (
            SELECT Id
            FROM OpportunityLineItem
            WHERE OpportunityId = :parentRecordId
          )
      ]) {
        if (mp.OpportunityLineItem__c == null) {
          continue;
        }
        Id oli = mp.OpportunityLineItem__c;
        Decimal amt = monthlyPaymentLineAmount(mp);
        sums.put(oli, (sums.containsKey(oli) ? sums.get(oli) : 0) + amt);
      }
    } else if ('Order'.equals(objName)) {
      for (MonthlyPayment__c mp : [
        SELECT
          OrderItem__c,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE
          OrderItem__c IN (
            SELECT Id
            FROM OrderItem
            WHERE OrderId = :parentRecordId
          )
      ]) {
        if (mp.OrderItem__c == null) {
          continue;
        }
        Id oi = mp.OrderItem__c;
        Decimal amt = monthlyPaymentLineAmount(mp);
        sums.put(oi, (sums.containsKey(oi) ? sums.get(oi) : 0) + amt);
      }
    }
    return sums;
  }

  /**
   * Sum of monthly line payables per OpportunityLineItem or OrderItem for Package Builder
   * "Total Calculated Revenue of periodic Rooms" KPI: Price__c * (1 + rate), where rate uses the same rule as
   * {@link #monthlyLinePayableAmount} (|Discount__c| &lt; 1 = fraction, else percent points / 100).
   * This is the historical one-minus KPI with the sign flipped to (1 + rate) only.
   *
   * @param parentRecordId Opportunity Id or Order Id
   */
  public static Map<Id, Decimal> getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
    Id parentRecordId
  ) {
    Map<Id, Decimal> sums = new Map<Id, Decimal>();
    if (parentRecordId == null) {
      return sums;
    }
    String objName = parentRecordId.getSobjectType().getDescribe().getName();
    if ('Opportunity'.equals(objName)) {
      for (MonthlyPayment__c mp : [
        SELECT
          OpportunityLineItem__c,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE
          OpportunityLineItem__c IN (
            SELECT Id
            FROM OpportunityLineItem
            WHERE OpportunityId = :parentRecordId
          )
      ]) {
        if (mp.OpportunityLineItem__c == null) {
          continue;
        }
        Id oli = mp.OpportunityLineItem__c;
        Decimal amt = monthlyPaymentLineAmount(mp);
        sums.put(oli, (sums.containsKey(oli) ? sums.get(oli) : 0) + amt);
      }
    } else if ('Order'.equals(objName)) {
      for (MonthlyPayment__c mp : [
        SELECT
          OrderItem__c,
          Price__c,
          Discount__c,
          ListPrice__c,
          Access_Type__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE
          OrderItem__c IN (
            SELECT Id
            FROM OrderItem
            WHERE OrderId = :parentRecordId
          )
      ]) {
        if (mp.OrderItem__c == null) {
          continue;
        }
        Id oi = mp.OrderItem__c;
        Decimal amt = monthlyPaymentLineAmount(mp);
        sums.put(oi, (sums.containsKey(oi) ? sums.get(oi) : 0) + amt);
      }
    }
    return sums;
  }
}
