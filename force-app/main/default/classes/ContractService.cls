/**
 * @description       :The ContractService class manages creating, updating, and deleting monthly payments
 *                      for OrderItem records based on contract details. It recalculates payments and triggers events when new payments are added.
 * @author            : LAURIE CS
 * @group             :
 * @last modified on  : 2024-10-13
 **/
public with sharing class ContractService {
  private static final String PRODUCT_TYPE_CONTRACT_TERMS = 'Contract Terms';
  public static final Integer ROLLING_FORWARD_MONTHS = 24;
  /** Batch top-up when latest payment ends before asOf + this many months (aligned with forward horizon). */
  public static final Integer ROLLING_BUFFER_MONTHS = ROLLING_FORWARD_MONTHS;
  public static final Integer DATAFIX_FORWARD_MONTHS = 48;
  private static Set<Id> recalculatedOrderItemsInTxn = new Set<Id>();

  private static Boolean isContractTermsProduct2Type(String productType) {
    return PRODUCT_TYPE_CONTRACT_TERMS.equals(productType);
  }

  private class RenewalPriceAdjustmentInterval {
    public Date startDate;
    public Date endDate;
    public Decimal discount;

    public RenewalPriceAdjustmentInterval(
      Date startDate,
      Date endDate,
      Decimal discount
    ) {
      this.startDate = startDate;
      this.endDate = endDate;
      this.discount = discount;
    }
  }

  private static Map<Id, List<RenewalPriceAdjustmentInterval>> orderItemRenewalIntervals;

  /**
   * @description Inclusive count of calendar months from the entry month through {@code throughDate}'s month.
   *              Example: entry 12 Jan 2026 and through 6 Apr 2026 → 4 (Jan–Apr).
   */
  public static Integer monthsFromEntryThroughCalendarMonth(
    Date entryDate,
    Date throughDate
  ) {
    if (entryDate == null || throughDate == null) {
      return 0;
    }
    Date entryStart = entryDate.toStartOfMonth();
    Date throughStart = throughDate.toStartOfMonth();
    if (entryStart > throughStart) {
      return 1;
    }
    Integer m =
      (throughStart.year() - entryStart.year()) * 12 +
      (throughStart.month() - entryStart.month()) +
      1;
    return m > 0 ? m : 1;
  }

  /**
   * @description Order start for payment visibility: Order_Start_Date__c, else EffectiveDate.
   */
  public static Date resolveOrderStartDate(OrderItem oi) {
    if (oi == null || oi.Order == null) {
      return null;
    }
    return oi.Order.Order_Start_Date__c != null
      ? oi.Order.Order_Start_Date__c
      : oi.Order.EffectiveDate;
  }

  private static Date safeContractEndDate(OrderItem oi) {
    if (oi == null) {
      return null;
    }
    SObject contract = oi.getSObject('Contract__r');
    if (contract == null) {
      return null;
    }
    if (!contract.getPopulatedFieldsAsMap().containsKey('EndDate')) {
      return null;
    }
    return (Date) contract.get('EndDate');
  }

  private static Id safeContractLocationId(OrderItem oi) {
    if (oi == null) {
      return null;
    }
    SObject contract = oi.getSObject('Contract__r');
    if (contract == null) {
      return null;
    }
    return null;
  }

  private static Id safeOrderOpportunityId(OrderItem oi) {
    if (oi == null || oi.Order == null) {
      return null;
    }
    if (!oi.Order.getPopulatedFieldsAsMap().containsKey('OpportunityId')) {
      return null;
    }
    return oi.Order.OpportunityId;
  }

  /**
   * @description Target end for open-ended Monthly: rolling forward months from today, or from
   *              product ServiceDate when that date is in the future. Contract and order end dates
   *              do not cap Monthly payment generation.
   */
  public static Date resolveOpenEndedMonthlyTargetEnd(
    OrderItem oi,
    Date asOfDate
  ) {
    Date asOf = asOfDate != null ? asOfDate : Date.today();
    Date horizonAnchor = asOf;
    if (oi != null && oi.ServiceDate != null && oi.ServiceDate > asOf) {
      horizonAnchor = oi.ServiceDate;
    }
    return horizonAnchor.addMonths(ROLLING_FORWARD_MONTHS);
  }

  /**
   * @description Max MonthIndex so payments cover product start (ServiceDate) through targetEnd.
   */
  public static Integer resolveOpenEndedMonthlyHorizonMonthCount(
    OrderItem oi,
    Date targetEnd,
    Date asOfDate
  ) {
    if (oi == null || oi.ServiceDate == null || targetEnd == null) {
      return 0;
    }
    Date effectiveEntry = resolveEffectiveServiceDateForMonthly(oi);
    if (effectiveEntry == null) {
      return 0;
    }
    Integer maxIndex = 0;
    for (Integer i = 1; i <= 600; i++) {
      Date statD = monthlyStatDateForOrderItemMonth(effectiveEntry, i);
      Date endD = monthlyEndDateForOrderItemMonth(effectiveEntry, i);
      if (statD == null || endD == null) {
        break;
      }
      Date coveredMonthStart = endD.toStartOfMonth();
      if (coveredMonthStart > targetEnd.toStartOfMonth()) {
        break;
      }
      maxIndex = i;
      if (endD >= targetEnd) {
        break;
      }
    }
    return maxIndex;
  }

  public static Boolean isOpenEndedMonthlyOrderItem(OrderItem oi) {
    if (oi == null || oi.Access_Type__c != 'Monthly' || oi.EndDate != null) {
      return false;
    }
    return !isContractTermsProduct2Type(
      oi.Product2 != null ? oi.Product2.Type__c : null
    );
  }

  /**
   * @description Number of MonthlyPayment rows to create on initial generation for OrderItem Monthly.
   *              Both dates → inclusive months from entry through end.
   *              EndDate null → rolling horizon (today+24, or ServiceDate+24 when start is future).
   */
  public static Integer monthlyPaymentCountForOrderItem(OrderItem oi) {
    if (
      oi == null ||
      oi.Access_Type__c != 'Monthly' ||
      oi.ServiceDate == null
    ) {
      return 0;
    }
    if (oi.EndDate == null) {
      Date targetEnd = resolveOpenEndedMonthlyTargetEnd(oi, Date.today());
      return resolveOpenEndedMonthlyHorizonMonthCount(
        oi,
        targetEnd,
        Date.today()
      );
    }
    Integer monthsDiff =
      (oi.EndDate.year() - oi.ServiceDate.year()) * 12 +
      (oi.EndDate.month() - oi.ServiceDate.month()) +
      1;
    if (oi.EndDate.day() < oi.ServiceDate.day()) {
      monthsDiff--;
    }
    return monthsDiff > 0 ? monthsDiff : 0;
  }

  /**
   * Term-based monthly payment row count for OrderItem Monthly, Usage Based, and Rent.
   * Aligns contract activation/rebuild with Package Builder order-item rules.
   */
  public static Integer orderItemTermMonthlyPaymentCount(OrderItem oi) {
    if (oi == null || oi.ServiceDate == null) {
      return 0;
    }
    if ('Monthly'.equals(oi.Access_Type__c)) {
      return monthlyPaymentCountForOrderItem(oi);
    }
    if (
      PackageBuilderAccessTypePolicy.isUsageBased(oi.Access_Type__c) ||
      PackageBuilderAccessTypePolicy.isRent(oi.Access_Type__c)
    ) {
      if (oi.EndDate != null) {
        Integer monthsDiff =
          (oi.EndDate.year() - oi.ServiceDate.year()) * 12 +
          (oi.EndDate.month() - oi.ServiceDate.month()) +
          1;
        if (oi.EndDate.day() < oi.ServiceDate.day()) {
          monthsDiff--;
        }
        return monthsDiff > 0 ? monthsDiff : 0;
      }
      String orderStatus = oi.Order != null ? oi.Order.Status : null;
      if ('Draft'.equals(orderStatus) || 'Negotiation'.equals(orderStatus)) {
        return monthsFromEntryThroughCalendarMonth(
          oi.ServiceDate,
          Date.today()
        );
      }
      return 1;
    }
    return 0;
  }

  private static Integer resolveInitialMonthCount(
    OrderItem orderItem,
    Integer metadataMonthCount
  ) {
    if (orderItem == null) {
      return 0;
    }
    if ('Monthly'.equals(orderItem.Access_Type__c)) {
      return monthlyPaymentCountForOrderItem(orderItem);
    }
    if (PackageBuilderAccessTypePolicy.isUsageBased(orderItem.Access_Type__c)) {
      return orderItemTermMonthlyPaymentCount(orderItem);
    }
    return metadataMonthCount != null ? metadataMonthCount : 0;
  }

  /** Month 1: entry date; month 2+: day before first day of covered month. */
  public static Date monthlyStatDateForOrderItemMonth(
    Date effectiveEntry,
    Integer monthIndex
  ) {
    if (effectiveEntry == null || monthIndex == null || monthIndex < 1) {
      return null;
    }
    if (monthIndex == 1) {
      return effectiveEntry;
    }
    Date coveredMonthStart = effectiveEntry.toStartOfMonth()
      .addMonths(monthIndex - 1);
    return coveredMonthStart.addDays(-1);
  }

  public static Date monthlyEndDateForOrderItemMonth(
    Date effectiveEntry,
    Integer monthIndex
  ) {
    if (effectiveEntry == null || monthIndex == null || monthIndex < 1) {
      return null;
    }
    if (monthIndex == 1) {
      return getLastDayOfMonth(effectiveEntry);
    }
    Date coveredMonthStart = effectiveEntry.toStartOfMonth()
      .addMonths(monthIndex - 1);
    return getLastDayOfMonth(coveredMonthStart);
  }

  /**
   * @description Effective date for batch (sandbox override via CMDT As_of_Date__c).
   */
  public static Date monthlyPaymentBatchEffectiveDate() {
    List<MonthlyPayment_Batch_Settings__mdt> rows = [
      SELECT As_of_Date__c
      FROM MonthlyPayment_Batch_Settings__mdt
      LIMIT 1
    ];
    if (!rows.isEmpty() && rows[0].As_of_Date__c != null) {
      return rows[0].As_of_Date__c;
    }
    return Date.today();
  }

  /**
   * @description Returns true when CMDT is enabled and today's effective date matches label rooms_MonthlyPaymentBatch_RunDay (LAST_DAY or 1-31).
   */
  public static Boolean shouldRunMonthlyPaymentBatchToday() {
    List<MonthlyPayment_Batch_Settings__mdt> rows = [
      SELECT Enabled__c, As_of_Date__c
      FROM MonthlyPayment_Batch_Settings__mdt
      LIMIT 1
    ];
    if (rows.isEmpty() || !rows[0].Enabled__c) {
      return false;
    }
    Date asOf = monthlyPaymentBatchEffectiveDate();
    String dayRule = System.Label.cp_MonthlyPaymentBatch_RunDay;
    if (String.isBlank(dayRule)) {
      return false;
    }
    dayRule = dayRule.trim().toUpperCase();
    if (dayRule == 'LAST_DAY') {
      return asOf.day() == Date.daysInMonth(asOf.year(), asOf.month());
    }
    try {
      Integer d = Integer.valueOf(dayRule);
      return asOf.day() == d;
    } catch (Exception e) {
      return false;
    }
  }

  /**
   * @description Add-only sync for open-ended Monthly lines through targetEnd (default rolling horizon).
   */
  public static void syncOpenEndedMonthlyPaymentsAddOnly(
    List<OrderItem> items
  ) {
    Date asOf = monthlyPaymentBatchEffectiveDate();
    syncOpenEndedMonthlyPaymentsAddOnly(
      items,
      asOf.addMonths(ROLLING_FORWARD_MONTHS),
      asOf
    );
  }

  public static Integer syncOpenEndedMonthlyPaymentsAddOnly(
    List<OrderItem> items,
    Date targetEndOverride,
    Date asOfDate
  ) {
    if (items == null || items.isEmpty()) {
      return 0;
    }
    List<OrderItem> work = new List<OrderItem>();
    for (OrderItem oi : items) {
      if (isOpenEndedMonthlyOrderItem(oi)) {
        work.add(oi);
      }
    }
    if (work.isEmpty()) {
      return 0;
    }

    Set<Id> ids = new Set<Id>();
    for (OrderItem oi : work) {
      ids.add(oi.Id);
    }
    populateOrderItemRenewalIntervals(ids);

    Map<Id, List<MonthlyPayment__c>> byOi = new Map<Id, List<MonthlyPayment__c>>();
    List<MonthlyPayment__c> existingOpenEndedPayments = [
      SELECT
        Id,
        OrderItem__c,
        MonthIndex__c,
        Stat_Date_Trigger__c,
        Start_date__c,
        End_date__c,
        End_Date_trigger__c,
        Discount__c,
        OrderItem__r.Original_Order_Product__c,
        OrderItem__r.Replaced_Order_Product__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :ids
      ORDER BY MonthIndex__c ASC
    ];
    for (MonthlyPayment__c mp : existingOpenEndedPayments) {
      if (!byOi.containsKey(mp.OrderItem__c)) {
        byOi.put(mp.OrderItem__c, new List<MonthlyPayment__c>());
      }
      byOi.get(mp.OrderItem__c).add(mp);
    }
    Map<String, Decimal> oldDiscountBySourceAndMonth = getOldDiscountBySourceAndMonth(
      existingOpenEndedPayments
    );

    Date asOf = asOfDate != null ? asOfDate : Date.today();
    List<MonthlyPayment__c> toInsert = new List<MonthlyPayment__c>();

    for (OrderItem oi : work) {
      Date targetEnd = targetEndOverride != null
        ? targetEndOverride
        : resolveOpenEndedMonthlyTargetEnd(oi, asOf);

      Integer maxIndex = resolveOpenEndedMonthlyHorizonMonthCount(
        oi,
        targetEnd,
        asOf
      );
      if (maxIndex <= 0) {
        continue;
      }

      List<MonthlyPayment__c> existing = byOi.containsKey(oi.Id)
        ? byOi.get(oi.Id)
        : new List<MonthlyPayment__c>();
      List<MonthlyPayment__c> workingExisting = new List<MonthlyPayment__c>(
        existing
      );

      Set<Integer> existingIndices = new Set<Integer>();
      Integer lastFilledIndex = 0;
      for (MonthlyPayment__c mp : existing) {
        if (mp.MonthIndex__c != null) {
          Integer idx = mp.MonthIndex__c.intValue();
          existingIndices.add(idx);
          if (idx > lastFilledIndex) {
            lastFilledIndex = idx;
          }
        }
      }

      Date effectiveEntry = resolveEffectiveServiceDateForMonthly(oi);
      if (effectiveEntry == null) {
        continue;
      }
      Date orderStartDate = resolveOrderStartDate(oi);
      Map<Date, Decimal> preStartDiscountByDate = buildPreStartDiscountByDate(
        existing,
        orderStartDate
      );
      Decimal listPrice = (oi.ListPrice != null) ? oi.ListPrice : 0;

      for (Integer monthIndex = 1; monthIndex <= maxIndex; monthIndex++) {
        if (existingIndices.contains(monthIndex)) {
          continue;
        }

        Date statD = monthlyStatDateForOrderItemMonth(
          effectiveEntry,
          monthIndex
        );
        Date endD = monthlyEndDateForOrderItemMonth(effectiveEntry, monthIndex);
        Boolean isNextSequential = monthIndex == lastFilledIndex + 1;
        if (
          !isNextSequential &&
          paymentCalendarMonthOverlapsExisting(statD, endD, workingExisting)
        ) {
          continue;
        }

        Decimal discount = resolveAddOnlyMonthDiscount(
          oi,
          monthIndex,
          workingExisting,
          oldDiscountBySourceAndMonth,
          statD,
          endD,
          orderStartDate,
          preStartDiscountByDate
        );
        MonthlyPayment__c newPayment = createPayment(
          oi,
          listPrice,
          monthIndex,
          discount,
          statD,
          endD
        );
        toInsert.add(newPayment);
        workingExisting.add(newPayment);
        lastFilledIndex = monthIndex;
      }
    }

    if (!toInsert.isEmpty()) {
      insert toInsert;
      PackageBuilderService.syncOrderItemPriceRollups(ids);
    }
    return toInsert.size();
  }

  @TestVisible
  private static Map<Date, Decimal> buildDiscountByMonthStart(
    List<MonthlyPayment__c> existingRows
  ) {
    Map<Date, Decimal> byMonth = new Map<Date, Decimal>();
    if (existingRows == null) {
      return byMonth;
    }
    for (MonthlyPayment__c mp : existingRows) {
      if (mp.Stat_Date_Trigger__c == null) {
        continue;
      }
      Date monthStart = Date.newInstance(
        mp.Stat_Date_Trigger__c.year(),
        mp.Stat_Date_Trigger__c.month(),
        1
      );
      byMonth.put(monthStart, mp.Discount__c);
    }
    return byMonth;
  }

  private static Map<Date, MonthlyPayment__c> buildPaymentByMonthStart(
    List<MonthlyPayment__c> existingRows
  ) {
    Map<Date, MonthlyPayment__c> byMonth = new Map<Date, MonthlyPayment__c>();
    if (existingRows == null) {
      return byMonth;
    }
    for (MonthlyPayment__c mp : existingRows) {
      if (mp == null || mp.Stat_Date_Trigger__c == null) {
        continue;
      }
      Date monthStart = Date.newInstance(
        mp.Stat_Date_Trigger__c.year(),
        mp.Stat_Date_Trigger__c.month(),
        1
      );
      byMonth.put(monthStart, mp);
    }
    return byMonth;
  }

  @TestVisible
  private static Map<Date, Decimal> buildPreStartDiscountByDate(
    List<MonthlyPayment__c> existingRows,
    Date orderStartDate
  ) {
    Map<Date, Decimal> preStartDiscountByDate = new Map<Date, Decimal>();
    if (existingRows == null || orderStartDate == null) {
      return preStartDiscountByDate;
    }
    for (MonthlyPayment__c existingMp : existingRows) {
      if (
        existingMp.Stat_Date_Trigger__c != null &&
        existingMp.Stat_Date_Trigger__c < orderStartDate
      ) {
        preStartDiscountByDate.put(
          existingMp.Stat_Date_Trigger__c,
          existingMp.Discount__c
        );
      }
    }
    return preStartDiscountByDate;
  }

  @TestVisible
  private static Boolean paymentCalendarMonthOverlapsExisting(
    Date statD,
    Date endD,
    List<MonthlyPayment__c> existing
  ) {
    if (endD == null || existing == null || existing.isEmpty()) {
      return false;
    }
    Date candidateMonth = endD.toStartOfMonth();
    for (MonthlyPayment__c mp : existing) {
      Date existEnd = mp.End_date__c != null
        ? mp.End_date__c
        : mp.End_Date_trigger__c;
      if (existEnd == null && mp.Stat_Date_Trigger__c != null) {
        existEnd = getLastDayOfMonth(mp.Stat_Date_Trigger__c);
      }
      if (existEnd == null) {
        continue;
      }
      if (candidateMonth == existEnd.toStartOfMonth()) {
        return true;
      }
    }
    return false;
  }

  @TestVisible
  private static Decimal resolveAddOnlyMonthDiscount(
    OrderItem oi,
    Integer monthIndex,
    List<MonthlyPayment__c> workingExisting,
    Map<String, Decimal> oldDiscountBySourceAndMonth,
    Date statD,
    Date endD,
    Date orderStartDate,
    Map<Date, Decimal> preStartDiscountByDate
  ) {
    if (
      statD != null &&
      orderStartDate != null &&
      statD < orderStartDate &&
      preStartDiscountByDate.containsKey(statD)
    ) {
      return preStartDiscountByDate.get(statD);
    }
    // Active recurring rule wins over carry-forward for newly topped-up months.
    Decimal intervalAdjustment = getRenewalDiscountForDate(
      oi.Id,
      consultMonthStart(statD, endD)
    );
    if (intervalAdjustment != null) {
      return intervalAdjustment;
    }
    if (monthIndex > 1) {
      MonthlyPayment__c prevMonthPayment = null;
      for (MonthlyPayment__c mp : workingExisting) {
        if (
          mp.MonthIndex__c != null &&
          mp.MonthIndex__c.intValue() == monthIndex - 1
        ) {
          prevMonthPayment = mp;
          break;
        }
      }
      if (prevMonthPayment != null) {
        return deriveCarryForwardDiscount(
          oi,
          prevMonthPayment,
          oldDiscountBySourceAndMonth
        );
      }
    }
    return 0;
  }

  public static Boolean shouldUseOpenEndedMonthlyAddOnlySync(
    OrderItem lineItem,
    OrderItem oldLineItem
  ) {
    if (!isOpenEndedMonthlyOrderItem(lineItem)) {
      return false;
    }
    if (oldLineItem == null) {
      return true;
    }
    if (oldLineItem.Access_Type__c != 'Monthly') {
      return false;
    }
    if (oldLineItem.EndDate != lineItem.EndDate) {
      return false;
    }
    if (oldLineItem.Access_Type__c != lineItem.Access_Type__c) {
      return false;
    }
    return true;
  }

  public static Date latestPaymentEndDate(List<MonthlyPayment__c> payments) {
    Date latest = null;
    if (payments == null) {
      return null;
    }
    for (MonthlyPayment__c mp : payments) {
      Date endD = mp.End_date__c != null
        ? mp.End_date__c
        : mp.End_Date_trigger__c;
      if (endD != null && (latest == null || endD > latest)) {
        latest = endD;
      }
    }
    return latest;
  }

  /**
   * @description For Monthly + null EndDate: top up payments through rolling horizon (batch path).
   */
  public static void insertNextOpenEndedMonthlyPayments(List<OrderItem> items) {
    if (items == null || items.isEmpty()) {
      return;
    }
    Date asOf = monthlyPaymentBatchEffectiveDate();
    syncOpenEndedMonthlyPaymentsAddOnly(
      items,
      asOf.addMonths(ROLLING_FORWARD_MONTHS),
      asOf
    );
  }

  private static Map<String, Decimal> getOldDiscountBySourceAndMonth(
    List<MonthlyPayment__c> existingOpenEndedPayments
  ) {
    Map<String, Decimal> oldDiscountBySourceAndMonth = new Map<String, Decimal>();
    if (
      existingOpenEndedPayments == null || existingOpenEndedPayments.isEmpty()
    ) {
      return oldDiscountBySourceAndMonth;
    }

    Set<Id> sourceOrderItemIds = new Set<Id>();
    Set<Date> monthStarts = new Set<Date>();
    for (MonthlyPayment__c mp : existingOpenEndedPayments) {
      if (mp == null) {
        continue;
      }
      Date normalizedMonthStart = normalizedMonthStart(
        mp.Start_date__c,
        mp.Stat_Date_Trigger__c
      );
      if (normalizedMonthStart != null) {
        monthStarts.add(normalizedMonthStart);
      }
      Id sourceOrderItemId = mp.OrderItem__r != null &&
        mp.OrderItem__r.Original_Order_Product__c != null
        ? mp.OrderItem__r.Original_Order_Product__c
        : (mp.OrderItem__r != null
            ? mp.OrderItem__r.Replaced_Order_Product__c
            : null);
      if (sourceOrderItemId != null) {
        sourceOrderItemIds.add(sourceOrderItemId);
      }
    }

    if (sourceOrderItemIds.isEmpty() || monthStarts.isEmpty()) {
      return oldDiscountBySourceAndMonth;
    }

    for (MonthlyPayment__c oldMp : [
      SELECT OrderItem__c, Start_date__c, Stat_Date_Trigger__c, Discount__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :sourceOrderItemIds
    ]) {
      Date oldMpMonthStart = normalizedMonthStart(
        oldMp.Start_date__c,
        oldMp.Stat_Date_Trigger__c
      );
      if (
        oldMp.OrderItem__c == null ||
        oldMpMonthStart == null ||
        !monthStarts.contains(oldMpMonthStart)
      ) {
        continue;
      }
      oldDiscountBySourceAndMonth.put(
        String.valueOf(oldMp.OrderItem__c) +
          '|' +
          String.valueOf(oldMpMonthStart),
        oldMp.Discount__c
      );
    }
    return oldDiscountBySourceAndMonth;
  }

  private static Decimal deriveCarryForwardDiscount(
    OrderItem orderItem,
    MonthlyPayment__c prevMonthPayment,
    Map<String, Decimal> oldDiscountBySourceAndMonth
  ) {
    Decimal fallback = prevMonthPayment != null &&
      prevMonthPayment.Discount__c != null
      ? prevMonthPayment.Discount__c
      : 0;
    if (orderItem == null || prevMonthPayment == null) {
      return fallback;
    }

    Date monthStart = normalizedMonthStart(
      prevMonthPayment.Start_date__c,
      prevMonthPayment.Stat_Date_Trigger__c
    );
    Date monthEnd = prevMonthPayment.End_date__c != null
      ? prevMonthPayment.End_date__c
      : getLastDayOfMonth(monthStart);
    Date orderStart = orderItem.Order != null
      ? (orderItem.Order.Order_Start_Date__c != null
          ? orderItem.Order.Order_Start_Date__c
          : orderItem.Order.EffectiveDate)
      : null;
    if (
      monthStart == null ||
      monthEnd == null ||
      orderStart == null ||
      !(monthStart < orderStart &&
      orderStart <= monthEnd)
    ) {
      return fallback;
    }

    Integer totalDays = monthStart.daysBetween(monthEnd) + 1;
    Integer preDays = monthStart.daysBetween(orderStart);
    Integer postDays = orderStart.daysBetween(monthEnd) + 1;
    if (totalDays <= 0 || preDays < 0 || postDays <= 0) {
      return fallback;
    }

    Id sourceOrderItemId = prevMonthPayment.OrderItem__r != null &&
      prevMonthPayment.OrderItem__r.Original_Order_Product__c != null
      ? prevMonthPayment.OrderItem__r.Original_Order_Product__c
      : (prevMonthPayment.OrderItem__r != null
          ? prevMonthPayment.OrderItem__r.Replaced_Order_Product__c
          : null);
    Decimal oldDiscount = null;
    if (
      sourceOrderItemId != null &&
      monthStart != null &&
      oldDiscountBySourceAndMonth != null
    ) {
      oldDiscount = oldDiscountBySourceAndMonth.get(
        String.valueOf(sourceOrderItemId) + '|' + String.valueOf(monthStart)
      );
    }
    if (oldDiscount == null) {
      oldDiscount = fallback;
    }

    Decimal effectiveDiscount = fallback;
    Decimal enteredDiscount =
      ((effectiveDiscount * totalDays) - (oldDiscount * preDays)) / postDays;
    return enteredDiscount.setScale(6, System.RoundingMode.HALF_UP);
  }

  private static Date normalizedMonthStart(
    Date startDate,
    Date statDateTrigger
  ) {
    if (statDateTrigger != null) {
      return statDateTrigger.toStartOfMonth();
    }
    if (startDate != null) {
      return startDate.toStartOfMonth();
    }
    return null;
  }

  private static Date resolveEffectiveServiceDateForMonthly(
    OrderItem orderItem
  ) {
    return orderItem.ServiceDate;
  }

  private static void populateOrderItemRenewalIntervals(Set<Id> orderItemIds) {
    orderItemRenewalIntervals = new Map<Id, List<RenewalPriceAdjustmentInterval>>();
    RecurringPriceIncreaseService.preloadLines(orderItemIds);
  }

  /**
   * @description : Generates monthly payments for the OrderItems provided in the map.
   * @param orderItemsMap : Map of OrderItem Ids to OrderItem records.
   **/
  public static void generateMonthlyPaymentsRelatedToOrderItems(
    Map<Id, OrderItem> orderItemsMap
  ) {
    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings.isEmpty() ||
      mpSettings[0].NumberOfMonths__c == null
      ? 0
      : Integer.valueOf(mpSettings[0].NumberOfMonths__c);

    List<OrderItem> orderItemRetrieve = [
      SELECT
        Id,
        ServiceDate,
        Opportunity_Product__c,
        EndDate,
        ListPrice,
        Access_Type__c,
        Contract__c,
        Contract__r.StartDate,
        Contract__r.EndDate,
        Product2Id,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.Previous_Order__c,
        Order.Replacement_Start_Date__c,
        Order.OpportunityId,
        Order.Status,
        Change_Action_Type__c,
        Period_In_Months__c,
        Product2.Type__c,
        Original_Order_Product__c
      FROM OrderItem
      WHERE Id IN :orderItemsMap.keySet()
    ];

    Map<Id, List<MonthlyPayment__c>> orderItemToMonthlyPaymentsMap = buildOrderItemMonthlyPaymentsCopyMap(
      orderItemRetrieve
    );

    Set<Id> orderItemIds = new Set<Id>();
    for (OrderItem oi : orderItemRetrieve) {
      orderItemIds.add(oi.Id);
    }
    populateOrderItemRenewalIntervals(orderItemIds);

    List<MonthlyPayment__c> allPayments = new List<MonthlyPayment__c>();
    for (OrderItem orderItem : orderItemRetrieve) {
      Integer monthCount = resolveInitialMonthCount(orderItem, numberOfMonths);
      List<MonthlyPayment__c> newPayments = new List<MonthlyPayment__c>();
      if (orderItemToMonthlyPaymentsMap.containsKey(orderItem.Id)) {
        List<MonthlyPayment__c> paymentsToCopy = orderItemToMonthlyPaymentsMap.get(
          orderItem.Id
        );
        newPayments = generateMonthlyPaymentsForOrderItem(
          orderItem,
          orderItem.ServiceDate,
          true,
          monthCount,
          paymentsToCopy
        );
      } else {
        newPayments = generateMonthlyPaymentsForOrderItem(
          orderItem,
          orderItem.ServiceDate,
          true,
          monthCount,
          null
        );
      }

      allPayments.addAll(newPayments);
    }

    System.debug('allPayments = ' + allPayments);

    if (!allPayments.isEmpty()) {
      insert allPayments;
      PackageBuilderService.syncOrderItemPriceRollups(orderItemIds);
    }
    syncOpenEndedMonthlyPaymentsAddOnly(orderItemRetrieve);
  }

  /**
   * Builds per–draft/new OrderItem lists of MonthlyPayment rows to copy discounts from.
   * OLI payments apply when Opportunity_Product__c is set; active-order payments from
   * Original_Order_Product__c take precedence (Package Builder draft clone path).
   */
  @TestVisible
  private static Map<Id, List<MonthlyPayment__c>> buildOrderItemMonthlyPaymentsCopyMap(
    List<OrderItem> orderItems
  ) {
    Map<Id, List<MonthlyPayment__c>> orderItemToMonthlyPaymentsMap = new Map<Id, List<MonthlyPayment__c>>();
    if (orderItems == null || orderItems.isEmpty()) {
      return orderItemToMonthlyPaymentsMap;
    }

    List<Id> oppProductList = new List<Id>();
    for (OrderItem orderItem : orderItems) {
      if (orderItem.Opportunity_Product__c != null) {
        oppProductList.add(orderItem.Opportunity_Product__c);
      }
    }

    if (!oppProductList.isEmpty()) {
      List<MonthlyPayment__c> sourceOppPayments = [
        SELECT
          Id,
          OpportunityLineItem__c,
          Discount__c,
          ListPrice__c,
          Final_Adjusted_Price__c,
          Stat_Date_Trigger__c,
          End_Date_trigger__c,
          MonthIndex__c
        FROM MonthlyPayment__c
        WHERE OpportunityLineItem__c IN :oppProductList
        ORDER BY MonthIndex__c ASC
      ];
      for (MonthlyPayment__c mp : sourceOppPayments) {
        for (OrderItem orderItem : orderItems) {
          if (orderItem.Opportunity_Product__c == mp.OpportunityLineItem__c) {
            if (!orderItemToMonthlyPaymentsMap.containsKey(orderItem.Id)) {
              orderItemToMonthlyPaymentsMap.put(
                orderItem.Id,
                new List<MonthlyPayment__c>()
              );
            }
            orderItemToMonthlyPaymentsMap.get(orderItem.Id).add(mp);
          }
        }
      }
    }

    Set<Id> sourceOrderItemIds = new Set<Id>();
    Map<Id, Id> draftItemIdToSourceOrderItemId = new Map<Id, Id>();
    for (OrderItem orderItem : orderItems) {
      if (orderItem.Original_Order_Product__c != null) {
        sourceOrderItemIds.add(orderItem.Original_Order_Product__c);
        draftItemIdToSourceOrderItemId.put(
          orderItem.Id,
          orderItem.Original_Order_Product__c
        );
      }
    }

    if (!sourceOrderItemIds.isEmpty()) {
      Map<Id, List<MonthlyPayment__c>> paymentsBySourceOrderItemId = new Map<Id, List<MonthlyPayment__c>>();
      for (MonthlyPayment__c mp : [
        SELECT
          Id,
          OrderItem__c,
          Discount__c,
          ListPrice__c,
          Final_Adjusted_Price__c,
          Stat_Date_Trigger__c,
          End_Date_trigger__c,
          MonthIndex__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c IN :sourceOrderItemIds
        ORDER BY MonthIndex__c ASC
      ]) {
        if (!paymentsBySourceOrderItemId.containsKey(mp.OrderItem__c)) {
          paymentsBySourceOrderItemId.put(
            mp.OrderItem__c,
            new List<MonthlyPayment__c>()
          );
        }
        paymentsBySourceOrderItemId.get(mp.OrderItem__c).add(mp);
      }

      for (Id draftItemId : draftItemIdToSourceOrderItemId.keySet()) {
        Id sourceOrderItemId = draftItemIdToSourceOrderItemId.get(draftItemId);
        if (paymentsBySourceOrderItemId.containsKey(sourceOrderItemId)) {
          orderItemToMonthlyPaymentsMap.put(
            draftItemId,
            paymentsBySourceOrderItemId.get(sourceOrderItemId)
          );
        }
      }
    }

    return orderItemToMonthlyPaymentsMap;
  }

  /**
   * @deprecated Monthly OrderItem accrual is handled by MonthlyOrderItemPaymentsBatch (open-ended lines).
   */
  public static void generateMonthlyPaymentsForYearFromCrntDate(
    List<OrderItem> orderItems
  ) {
  }

  public static Integer getCustomPaymentMonthCount(
    Date startDate,
    Date terminationDate
  ) {
    Date limitDate = Date.today().addMonths(24);
    Date endDate = (terminationDate != null &&
      terminationDate < limitDate)
      ? terminationDate
      : limitDate;
    if (endDate < startDate) {
      return 0;
    }
    Integer months =
      (endDate.year() - startDate.year()) * 12 +
      (endDate.month() - startDate.month()) +
      1;
    if (endDate.day() < startDate.day()) {
      months--;
    }
    return months > 0 ? months : 0;
  }

  /**
   * @description : Generates monthly payments for a single OrderItem.
   * @param orderItem : OrderItem record.
   * @param startDate : Date to start generating payments from.
   * @param isInsert : Boolean indicating if the operation is an insert or update.
   * @return : List of MonthlyPayment__c records.
   **/
  public static List<MonthlyPayment__c> generateMonthlyPaymentsForOrderItem(
    OrderItem orderItem,
    Date startDate,
    Boolean isInsert,
    Integer numberOfMonths,
    List<MonthlyPayment__c> paymentsToCopy
  ) {
    List<MonthlyPayment__c> payments = new List<MonthlyPayment__c>();
    if (
      isContractTermsProduct2Type(
        orderItem.Product2 != null ? orderItem.Product2.Type__c : null
      )
    ) {
      return payments;
    }
    Date currentStart = isInsert
      ? orderItem.ServiceDate
      : getFirstDayOfMonth(startDate);

    // NPE Fix: Ensure currentStart is never null
    if (currentStart == null) {
      currentStart = (startDate != null)
        ? getFirstDayOfMonth(startDate)
        : Date.today();
    }

    Integer monthIndex = 0;
    Decimal listPrice = (orderItem.ListPrice != null) ? orderItem.ListPrice : 0;

    Date endDate = (orderItem.EndDate != null)
      ? getLastDayOfMonth(orderItem.EndDate)
      : currentStart.addMonths(1);
    Boolean isFirstMonth = true;

    if (
      PackageBuilderAccessTypePolicy.isPeriodicLike(orderItem.Access_Type__c)
    ) {
      if (isInsert) {
        Integer totalDaysInMonth = Date.daysInMonth(
          currentStart.year(),
          currentStart.month()
        );
        Integer remainingDays = totalDaysInMonth - currentStart.day() + 1;
        listPrice = (orderItem.ListPrice / totalDaysInMonth) * remainingDays;
      }
      while (currentStart <= endDate) {
        monthIndex++;
        // Use the Stat_Date_Trigger__c (currentStart) to find the applicable renewal adjustment
        Decimal intervalAdjustment = getRenewalDiscountForDate(
          orderItem.Id,
          currentStart
        );
        Decimal baseDiscount = getDiscountFromCopy(paymentsToCopy, monthIndex);
        Decimal effectiveDiscount = intervalAdjustment != null
          ? intervalAdjustment
          : baseDiscount;
        Date payEnd = PackageBuilderService.paymentEndClampedToLineEnd(
          currentStart,
          orderItem.EndDate
        );
        Date payStart = PackageBuilderService.clampPayStartToModifyOrderStart(
          orderItem,
          currentStart,
          payEnd
        );
        payments.add(
          createPayment(
            orderItem,
            listPrice,
            monthIndex,
            effectiveDiscount,
            payStart,
            payEnd
          )
        );
        currentStart = getFirstDayOfMonth(currentStart.addMonths(1));
        listPrice = orderItem.ListPrice;
        isFirstMonth = false;
      }
    } else if ('Monthly'.equals(orderItem.Access_Type__c)) {
      Integer loopCount = (numberOfMonths == null ||
        numberOfMonths < 0)
        ? 0
        : numberOfMonths;
      Date effectiveEntry = currentStart;
      for (Integer i = 0; i < loopCount; i++) {
        monthIndex++;
        Date statD = monthlyStatDateForOrderItemMonth(
          effectiveEntry,
          monthIndex
        );
        Date endD = monthlyEndDateForOrderItemMonth(effectiveEntry, monthIndex);
        statD = PackageBuilderService.clampPayStartToModifyOrderStart(
          orderItem,
          statD,
          endD
        );
        Decimal intervalAdjustment = getRenewalDiscountForDate(
          orderItem.Id,
          consultMonthStart(statD, endD)
        );
        Decimal baseDiscount = getDiscountFromCopy(paymentsToCopy, monthIndex);
        Decimal effectiveDiscount = intervalAdjustment != null
          ? intervalAdjustment
          : baseDiscount;
        payments.add(
          createPayment(
            orderItem,
            listPrice,
            monthIndex,
            effectiveDiscount,
            statD,
            endD
          )
        );
      }
    } else if (
      PackageBuilderAccessTypePolicy.isUsageBased(orderItem.Access_Type__c)
    ) {
      Integer loopCount = orderItemTermMonthlyPaymentCount(orderItem);
      Date effectiveEntry = currentStart;
      for (Integer i = 0; i < loopCount; i++) {
        monthIndex++;
        Date statD = monthlyStatDateForOrderItemMonth(
          effectiveEntry,
          monthIndex
        );
        Date endD = monthlyEndDateForOrderItemMonth(effectiveEntry, monthIndex);
        Decimal intervalAdjustment = getRenewalDiscountForDate(
          orderItem.Id,
          consultMonthStart(statD, endD)
        );
        Decimal baseDiscount = getDiscountFromCopy(paymentsToCopy, monthIndex);
        Decimal effectiveDiscount = intervalAdjustment != null
          ? intervalAdjustment
          : baseDiscount;
        MonthlyPayment__c payment = createPayment(
          orderItem,
          listPrice,
          monthIndex,
          effectiveDiscount,
          statD,
          endD
        );
        Decimal copiedListPrice = getListPriceFromCopy(
          paymentsToCopy,
          monthIndex
        );
        if (copiedListPrice != null) {
          payment.ListPrice__c = copiedListPrice;
        }
        payments.add(payment);
      }
    } else {
      Decimal intervalAdjustment = getRenewalDiscountForDate(
        orderItem.Id,
        currentStart
      );
      Decimal baseDiscount = getDiscountFromCopy(paymentsToCopy, 1);
      Decimal effectiveDiscount = intervalAdjustment != null
        ? intervalAdjustment
        : baseDiscount;
      payments.add(
        createPayment(orderItem, listPrice, 1, effectiveDiscount, currentStart)
      );
    }
    applyCopiedFinalAdjustedPrices(
      payments,
      paymentsToCopy,
      orderItem.Access_Type__c
    );
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
      PackageBuilderService.applyCopiedFinalAdjustedPriceIfSameSpan(
        neu,
        paymentsToCopy[idx - 1],
        accessType,
        copiedFap
      );
    }
  }

  private static Decimal getListPriceFromCopy(
    List<MonthlyPayment__c> paymentsToCopy,
    Integer monthIndex
  ) {
    return (paymentsToCopy != null &&
      monthIndex <= paymentsToCopy.size())
      ? paymentsToCopy[monthIndex - 1].ListPrice__c
      : null;
  }

  /**
   * @description : Finds the renewal adjustment (if any) that applies to the given
   *                date for the specified OrderItem.
   */
  /**
   * Covered calendar month for consult. Monthly Stat_Date_Trigger__c for index >= 2
   * is the day before the covered month; staircase math must use the covered month.
   */
  private static Date consultMonthStart(Date statDate, Date endDateTrigger) {
    if (endDateTrigger != null) {
      return endDateTrigger.toStartOfMonth();
    }
    return statDate == null ? null : statDate.toStartOfMonth();
  }

  private static Decimal getRenewalDiscountForDate(
    Id orderItemId,
    Date targetDate
  ) {
    // Consult active recurring price-increase rule (user layer = 0 on create).
    return RecurringPriceIncreaseService.resolveDiscount(
      orderItemId,
      targetDate,
      0
    );
  }

  /**
   * @description : Returns the first day of the month for a given date.
   * @param inputDate : The date to get the first day of the month for.
   * @return : Date representing the first day of the month.
   **/
  public static Date getFirstDayOfMonth(Date inputDate) {
    return Date.newInstance(inputDate.year(), inputDate.month(), 1);
  }

  /**
   * @description : Returns the last day of the month for a given date.
   * @param inputDate : The date to get the last day of the month for.
   * @return : Date representing the last day of the month.
   **/
  public static Date getLastDayOfMonth(Date inputDate) {
    return inputDate.toStartOfMonth().addMonths(1).addDays(-1);
  }

  /**
   * @description : Creates a MonthlyPayment__c record based on provided parameters.
   * @param statDate : Stat_Date_Trigger__c value.
   * @param endDateTrigger : End_Date_trigger__c value (covered period end).
   **/
  private static MonthlyPayment__c createPayment(
    OrderItem orderItem,
    Decimal listPrice,
    Integer monthIndex,
    Decimal discount,
    Date statDate,
    Date endDateTrigger
  ) {
    MonthlyPayment__c payment = new MonthlyPayment__c();
    payment.monthIndex__c = monthIndex;
    payment.OrderItem__c = orderItem.Id;
    payment.Contract__c = orderItem.Contract__c;
    payment.User_Price_Adjustment__c = 0;
    payment.Discount__c = discount;
    payment.Opportunity__c = safeOrderOpportunityId(orderItem);

    payment.Stat_Date_Trigger__c = statDate;
    payment.End_Date_trigger__c = endDateTrigger;

    return payment;
  }

  /** End date defaults to last day of month of stat date. */
  private static MonthlyPayment__c createPayment(
    OrderItem orderItem,
    Decimal listPrice,
    Integer monthIndex,
    Decimal discount,
    Date statDate
  ) {
    return createPayment(
      orderItem,
      listPrice,
      monthIndex,
      discount,
      statDate,
      getLastDayOfMonth(statDate)
    );
  }

  /**
   * @description : Deletes all MonthlyPayment__c records related to the provided OrderItems.
   * @param orderItemsToDelete : Map of OrderItem Ids to OrderItem records to delete payments for.
   **/
  public static void deleteAllMonthlyPaymentRelatedToOrderItem(
    Map<Id, OrderItem> orderItemsToDelete
  ) {
    System.debug(
      '@@@ Deleting payments for items: ' + orderItemsToDelete.keySet()
    );
    List<MonthlyPayment__c> paymentsToDelete = new List<MonthlyPayment__c>();
    List<MonthlyPayment__c> candidatePayments = [
      SELECT Id, Stat_Date_Trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :orderItemsToDelete.keyset()
    ];
    for (MonthlyPayment__c mp : candidatePayments) {
      System.debug(
        '@@@ Checking payment: ' +
          mp.Id +
          ' with Date: ' +
          mp.Stat_Date_Trigger__c
      );
      if (
        mp.Stat_Date_Trigger__c != null &&
        mp.Stat_Date_Trigger__c >= Date.today()
      ) {
        System.debug('@@@ Marked for deletion: ' + mp.Id);
        paymentsToDelete.add(mp);
      } else {
        System.debug('@@@ Sparing payment (past or null): ' + mp.Id);
      }
    }
    if (!paymentsToDelete.isEmpty()) {
      delete paymentsToDelete;
    }
  }

  /**
   * @description : Deletes and re-generates monthly payments for updated OrderItems based on new and old data.
   * @param orderItemsUpdatedNew : Map of updated OrderItem Ids to new OrderItem records.
   * @param orderItemsUpdatedOld : Map of updated OrderItem Ids to old OrderItem records.
   **/
  public static void deleteAllMonthlyPaymentAndRecalculate(
    Map<Id, OrderItem> orderItemsUpdatedNew,
    Map<Id, OrderItem> orderItemsUpdatedOld
  ) {
    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer numberOfMonths = mpSettings[0] != null &&
      mpSettings[0].NumberOfMonths__c != null
      ? Integer.valueOf(mpSettings[0].NumberOfMonths__c)
      : 0;
    List<MonthlyPayment__c> paymentsToInsert = new List<MonthlyPayment__c>();
    deleteAllMonthlyPaymentRelatedToOrderItem(orderItemsUpdatedNew);

    // Re-query to get Order relationship for pivot logic
    List<OrderItem> orderItemsWithOrder = [
      SELECT
        Id,
        ServiceDate,
        ListPrice,
        Access_Type__c,
        EndDate,
        Period_In_Months__c,
        Contract__c,
        Product2Id,
        Opportunity_Product__c,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.Previous_Order__c,
        Order.OpportunityId,
        Order.Status,
        Product2.Type__c
      FROM OrderItem
      WHERE Id IN :orderItemsUpdatedNew.keySet()
    ];

    for (OrderItem orderItem : orderItemsWithOrder) {
      Integer monthCount = resolveInitialMonthCount(orderItem, numberOfMonths);
      paymentsToInsert.addAll(
        generateMonthlyPaymentsForOrderItem(
          orderItem,
          orderItem.ServiceDate,
          false,
          monthCount,
          null
        )
      );
    }
    if (!paymentsToInsert.isEmpty()) {
      insert paymentsToInsert;
    }
  }

  /**
   * @description : Process updates to OrderItems to adjust Monthly Payments.
   *                Handles:
   *                1. Re-calculating payments when dates/prices change.
   *                2. Logical Removals (Change_Action_Type__c = 'Remove').
   *                3. Pivot Logic: Respects Previous_Order__c to handle replacement orders.
   *                4. Deletion Fallback: If Flow blocks partial curtailment, deletes the payment to prevent overcharging.
   * @author Batya Hudja | 2025-04-03
   * @param orderLineItemsUpdatedNew : Map of updated OrderItem Ids to new OrderItem records.
   * @param orderLineItemsUpdatedOld : Map of updated OrderItem Ids to old OrderItem records.
   **/
  public static void deleteAllMonthlyPaymentNotRelevant(
    Map<Id, OrderItem> orderLineItemsUpdatedNew,
    Map<Id, OrderItem> orderLineItemsUpdatedOld
  ) {
    if (
      orderLineItemsUpdatedNew == null || orderLineItemsUpdatedNew.isEmpty()
    ) {
      return;
    }

    Set<Id> itemIds = new Set<Id>(orderLineItemsUpdatedNew.keySet());
    itemIds.removeAll(recalculatedOrderItemsInTxn);
    if (itemIds.isEmpty()) {
      return;
    }
    Map<Id, OrderItem> fullNewMap = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          OrderId,
          ServiceDate,
          EndDate,
          Termination_Reason__c,
          Access_Type__c,
          ListPrice,
          UnitPrice,
          Quantity,
          Change_Action_Type__c,
          Change_Action_Effective_End_Date__c,
          Contract__c,
          Contract__r.EndDate,
          Order.EffectiveDate,
          Order.Order_Start_Date__c,
          Order.Previous_Order__c,
          Order.Replacement_Start_Date__c,
          Order.OpportunityId,
          Order.Status,
          Product2Id,
          Opportunity_Product__c,
          Product2.Type__c
        FROM OrderItem
        WHERE Id IN :itemIds
      ]
    );

    for (Id oid : fullNewMap.keySet()) {
      OrderItem input = orderLineItemsUpdatedNew.get(oid);
      OrderItem full = fullNewMap.get(oid);
      full.Change_Action_Type__c = input.Change_Action_Type__c;
      if (input.ServiceDate != null)
        full.ServiceDate = input.ServiceDate;
      if (
        input.getPopulatedFieldsAsMap().containsKey('Access_Type__c') &&
        input.Access_Type__c != null
      ) {
        full.Access_Type__c = input.Access_Type__c;
      }
      // Preserve explicit date / termination clears from trigger context.
      full.EndDate = input.EndDate;
      if (
        input.getPopulatedFieldsAsMap().containsKey('Termination_Reason__c')
      ) {
        full.Termination_Reason__c = input.Termination_Reason__c;
      }
      full.Change_Action_Effective_End_Date__c = input.Change_Action_Effective_End_Date__c;
    }

    Map<Id, OrderItem> relevantOrderItems = getRelevantOrderItems(
      fullNewMap.values(),
      orderLineItemsUpdatedOld
    );
    if (relevantOrderItems.isEmpty()) {
      return;
    }

    List<MPbyMonths__mdt> mpSettings = [
      SELECT NumberOfMonths__c
      FROM MPbyMonths__mdt
      LIMIT 1
    ];
    Integer defaultMonthCount = mpSettings.isEmpty() ||
      mpSettings[0].NumberOfMonths__c == null
      ? 0
      : Integer.valueOf(mpSettings[0].NumberOfMonths__c);

    Set<Id> relevantIds = relevantOrderItems.keySet();
    recalculatedOrderItemsInTxn.addAll(relevantIds);
    Map<Id, List<MonthlyPayment__c>> existingByOrderItemId = new Map<Id, List<MonthlyPayment__c>>();
    List<MonthlyPayment__c> existingPayments = [
      SELECT
        Id,
        OrderItem__c,
        Discount__c,
        ListPrice__c,
        Final_Adjusted_Price__c,
        MonthIndex__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :relevantIds
      ORDER BY MonthIndex__c ASC
    ];
    for (MonthlyPayment__c mp : existingPayments) {
      if (!existingByOrderItemId.containsKey(mp.OrderItem__c)) {
        existingByOrderItemId.put(
          mp.OrderItem__c,
          new List<MonthlyPayment__c>()
        );
      }
      existingByOrderItemId.get(mp.OrderItem__c).add(mp);
    }

    populateOrderItemRenewalIntervals(relevantIds);
    List<MonthlyPayment__c> toDelete = new List<MonthlyPayment__c>();
    List<MonthlyPayment__c> toInsert = new List<MonthlyPayment__c>();
    List<OrderItem> addOnlyMonthlyLines = new List<OrderItem>();

    for (Id lineItemId : relevantIds) {
      OrderItem lineItem = fullNewMap.get(lineItemId);
      if (lineItem == null)
        continue;
      OrderItem oldLineItem = orderLineItemsUpdatedOld != null
        ? orderLineItemsUpdatedOld.get(lineItemId)
        : null;
      List<MonthlyPayment__c> existingRows = existingByOrderItemId.containsKey(
          lineItemId
        )
        ? existingByOrderItemId.get(lineItemId)
        : new List<MonthlyPayment__c>();

      if (
        isContractTermsProduct2Type(
          lineItem.Product2 != null ? lineItem.Product2.Type__c : null
        )
      ) {
        if (!existingRows.isEmpty()) {
          toDelete.addAll(existingRows);
        }
        continue;
      }

      if (shouldUseOpenEndedMonthlyAddOnlySync(lineItem, oldLineItem)) {
        addOnlyMonthlyLines.add(lineItem);
        continue;
      }

      if (!existingRows.isEmpty()) {
        toDelete.addAll(existingRows);
      }

      Date orderStartDate = resolveOrderStartDate(lineItem);
      Map<Date, Decimal> preStartDiscountByDate = buildPreStartDiscountByDate(
        existingRows,
        orderStartDate
      );

      Integer monthCount = resolveRebuildMonthCount(
        lineItem,
        lineItem.Order != null ? lineItem.Order.Status : null,
        defaultMonthCount,
        existingRows.size()
      );

      toInsert.addAll(
        generateMonthlyPaymentsForOrderItemRebuild(
          lineItem,
          monthCount,
          existingRows,
          orderStartDate,
          preStartDiscountByDate
        )
      );
    }

    if (!addOnlyMonthlyLines.isEmpty()) {
      syncOpenEndedMonthlyPaymentsAddOnly(addOnlyMonthlyLines);
    }

    if (!toDelete.isEmpty()) {
      delete toDelete;
    }
    if (!toInsert.isEmpty()) {
      insert toInsert;
    }
    PackageBuilderService.syncOrderItemPriceRollups(relevantIds);
  }

  private static Integer resolveRebuildMonthCount(
    OrderItem lineItem,
    String orderStatus,
    Integer defaultMonthCount,
    Integer existingRowsCount
  ) {
    if (lineItem == null)
      return 0;
    if ('Monthly'.equals(lineItem.Access_Type__c)) {
      return monthlyPaymentCountForOrderItem(lineItem);
    }
    if (
      PackageBuilderAccessTypePolicy.isUsageBased(lineItem.Access_Type__c) ||
      PackageBuilderAccessTypePolicy.isRent(lineItem.Access_Type__c)
    ) {
      return orderItemTermMonthlyPaymentCount(lineItem);
    }
    if ('Periodic'.equals(lineItem.Access_Type__c)) {
      Date effectiveEndDate = lineItem.Change_Action_Effective_End_Date__c !=
        null
        ? lineItem.Change_Action_Effective_End_Date__c
        : lineItem.EndDate;
      if (lineItem.ServiceDate != null && effectiveEndDate != null) {
        Integer months =
          (effectiveEndDate.year() - lineItem.ServiceDate.year()) * 12 +
          (effectiveEndDate.month() - lineItem.ServiceDate.month()) +
          1;
        return months > 0 ? months : 0;
      }
    }
    return defaultMonthCount != null ? defaultMonthCount : 0;
  }

  @TestVisible
  private static List<MonthlyPayment__c> generateMonthlyPaymentsForOrderItemRebuild(
    OrderItem lineItem,
    Integer monthCount,
    List<MonthlyPayment__c> paymentsToCopy,
    Date orderStartDate,
    Map<Date, Decimal> preStartDiscountByDate
  ) {
    List<MonthlyPayment__c> regenerated = generateMonthlyPaymentsForOrderItem(
      lineItem,
      lineItem.ServiceDate,
      true,
      monthCount,
      paymentsToCopy
    );
    if (regenerated.isEmpty()) {
      return regenerated;
    }
    // Curtail/rebuild: keep Discount for calendar months that still exist.
    // Only months that did not exist before fall through to renewal / 0.
    Map<Date, Decimal> existingDiscountByMonth = buildDiscountByMonthStart(
      paymentsToCopy
    );
    Map<Date, MonthlyPayment__c> existingByMonth = buildPaymentByMonthStart(
      paymentsToCopy
    );
    for (MonthlyPayment__c mp : regenerated) {
      if (mp.Stat_Date_Trigger__c == null) {
        continue;
      }
      Date monthStart = Date.newInstance(
        mp.Stat_Date_Trigger__c.year(),
        mp.Stat_Date_Trigger__c.month(),
        1
      );
      if (existingDiscountByMonth.containsKey(monthStart)) {
        mp.Discount__c = existingDiscountByMonth.get(monthStart);
        MonthlyPayment__c src = existingByMonth.get(monthStart);
        if (src != null) {
          Map<String, Object> srcFields = src.getPopulatedFieldsAsMap();
          Decimal srcFap = srcFields.containsKey('Final_Adjusted_Price__c')
            ? src.Final_Adjusted_Price__c
            : null;
          PackageBuilderService.applyCopiedFinalAdjustedPriceIfSameSpan(
            mp,
            src,
            lineItem.Access_Type__c,
            srcFap
          );
        }
        continue;
      }
      if (orderStartDate == null) {
        continue;
      }
      if (
        mp.Stat_Date_Trigger__c < orderStartDate &&
        preStartDiscountByDate.containsKey(mp.Stat_Date_Trigger__c)
      ) {
        mp.Discount__c = preStartDiscountByDate.get(mp.Stat_Date_Trigger__c);
      } else if (
        mp.Stat_Date_Trigger__c >= orderStartDate &&
        !('Monthly'.equals(lineItem.Access_Type__c) && monthCount == 0)
      ) {
        Decimal intervalDiscount = getRenewalDiscountForDate(
          lineItem.Id,
          consultMonthStart(mp.Stat_Date_Trigger__c, mp.End_Date_trigger__c)
        );
        mp.Discount__c = intervalDiscount != null ? intervalDiscount : 0;
      }
    }
    return regenerated;
  }

  private static Map<Id, OrderItem> getRelevantOrderItems(
    List<OrderItem> newItems,
    Map<Id, OrderItem> oldItems
  ) {
    Map<Id, OrderItem> relevantOrderItems = new Map<Id, OrderItem>();

    for (OrderItem lineItem : newItems) {
      OrderItem oldLineItem = oldItems != null
        ? oldItems.get(lineItem.Id)
        : null;

      Date newEntryDate = lineItem.ServiceDate;
      Date oldEntryDate = oldLineItem != null ? oldLineItem.ServiceDate : null;

      Date newEndDate = lineItem.EndDate;
      Date oldEndDate = oldLineItem != null ? oldLineItem.EndDate : null;

      String newAccessType = lineItem.Access_Type__c;
      String oldAccessType = oldLineItem != null
        ? oldLineItem.Access_Type__c
        : null;

      Boolean terminationReasonChanged = terminationReasonChanged(
        lineItem,
        oldLineItem
      );

      if (newAccessType == 'Periodic') {
        System.debug('@@@ Checking Periodic Item: ' + lineItem.Id);
        System.debug(
          '@@@ Old Type: ' +
            (oldLineItem != null ? oldLineItem.Change_Action_Type__c : 'null') +
            ' New Type: ' +
            lineItem.Change_Action_Type__c
        );
        System.debug(
          '@@@ Old Effective: ' +
            (oldLineItem != null
              ? String.valueOf(oldLineItem.Change_Action_Effective_End_Date__c)
              : 'null') +
            ' New Effective: ' +
            String.valueOf(lineItem.Change_Action_Effective_End_Date__c)
        );
        if (
          newEntryDate != null &&
          newEndDate != null &&
          newAccessType != null &&
          (oldLineItem == null ||
          newEntryDate != oldEntryDate ||
          newEndDate != oldEndDate ||
          newAccessType != oldAccessType ||
          lineItem.Change_Action_Type__c != oldLineItem.Change_Action_Type__c ||
          lineItem.Change_Action_Effective_End_Date__c !=
          oldLineItem.Change_Action_Effective_End_Date__c)
        ) {
          System.debug('@@@ Adding to relevant map (Periodic): ' + lineItem.Id);
          relevantOrderItems.put(lineItem.Id, lineItem);
        }
      } else {
        System.debug('@@@ Checking Monthly Item: ' + lineItem.Id);
        if (
          newEntryDate != null &&
          newAccessType != null &&
          (oldLineItem == null ||
          newEntryDate != oldEntryDate ||
          newEndDate != oldEndDate ||
          newAccessType != oldLineItem.Access_Type__c ||
          terminationReasonChanged ||
          lineItem.Change_Action_Type__c != oldLineItem.Change_Action_Type__c ||
          lineItem.Change_Action_Effective_End_Date__c !=
          oldLineItem.Change_Action_Effective_End_Date__c)
        ) {
          System.debug('@@@ Adding to relevant map (Monthly): ' + lineItem.Id);
          relevantOrderItems.put(lineItem.Id, lineItem);
        }
      }
    }

    return relevantOrderItems;
  }

  private static Boolean terminationReasonChanged(
    OrderItem lineItem,
    OrderItem oldLineItem
  ) {
    if (oldLineItem == null) {
      return String.isNotBlank(lineItem.Termination_Reason__c);
    }
    if (
      !oldLineItem.getPopulatedFieldsAsMap()
        .containsKey('Termination_Reason__c')
    ) {
      return false;
    }
    return lineItem.Termination_Reason__c != oldLineItem.Termination_Reason__c;
  }

  public static void publishEvent() {
    MonthlyPaymentAdded__e event = new MonthlyPaymentAdded__e();

    Database.SaveResult result = EventBus.publish(event);

    if (!result.isSuccess()) {
      System.debug(
        'the publish of the event failed: ' + result.getErrors()[0].getMessage()
      );
    }
  }
}
