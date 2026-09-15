public with sharing class PackageBuilderMonthPriceService {
  public class LinePriceResult {
    @AuraEnabled
    public Decimal totalPrice { get; set; }
    @AuraEnabled
    public Decimal unitPrice { get; set; }
    @AuraEnabled
    public Boolean usedFallback { get; set; }
    @AuraEnabled
    public Boolean missing { get; set; }
    @AuraEnabled
    public String infoTooltip { get; set; }
    @AuraEnabled
    public Date sourceStartDate { get; set; }
  }

  /** Resolves the price projection without SOQL so tests and callers can supply a known payment set. */
  public static Map<Id, LinePriceResult> resolveFromPayments(
    List<MonthlyPayment__c> payments,
    Map<Id, Decimal> quantityByLineId,
    Map<Id, Date> productEndDateByLineId,
    Date effectiveTargetDate,
    Boolean orderIsActivated
  ) {
    Map<Id, LinePriceResult> results = new Map<Id, LinePriceResult>();
    if (quantityByLineId == null || quantityByLineId.isEmpty()) {
      return results;
    }

    Map<Id, List<MonthlyPayment__c>> paymentsByLineId = new Map<Id, List<MonthlyPayment__c>>();
    if (payments != null) {
      for (MonthlyPayment__c payment : payments) {
        if (
          payment == null ||
          payment.OrderItem__c == null ||
          !quantityByLineId.containsKey(payment.OrderItem__c)
        ) {
          continue;
        }
        if (!paymentsByLineId.containsKey(payment.OrderItem__c)) {
          paymentsByLineId.put(
            payment.OrderItem__c,
            new List<MonthlyPayment__c>()
          );
        }
        paymentsByLineId.get(payment.OrderItem__c).add(payment);
      }
    }

    for (Id lineId : quantityByLineId.keySet()) {
      List<MonthlyPayment__c> linePayments = paymentsByLineId.containsKey(
          lineId
        )
        ? paymentsByLineId.get(lineId)
        : new List<MonthlyPayment__c>();
      results.put(
        lineId,
        resolveLine(
          linePayments,
          quantityByLineId.get(lineId),
          productEndDateByLineId != null
            ? productEndDateByLineId.get(lineId)
            : null,
          effectiveTargetDate
        )
      );
    }
    return results;
  }

  /** Resolves each OrderItem using today's month for activated Orders and business start month otherwise. */
  public static Map<Id, LinePriceResult> resolveForOrderItems(
    List<OrderItem> items
  ) {
    Map<Id, LinePriceResult> empty = new Map<Id, LinePriceResult>();
    if (items == null || items.isEmpty()) {
      return empty;
    }

    Set<Id> orderIds = new Set<Id>();
    Set<Id> lineIds = new Set<Id>();
    for (OrderItem item : items) {
      if (item != null && item.Id != null) {
        lineIds.add(item.Id);
      }
      if (item != null && item.OrderId != null) {
        orderIds.add(item.OrderId);
      }
    }
    Map<Id, Order> ordersById = orderIds.isEmpty()
      ? new Map<Id, Order>()
      : new Map<Id, Order>(
          [
            SELECT Id, Status, Order_Start_Date__c, EffectiveDate
            FROM Order
            WHERE Id IN :orderIds
          ]
        );

    Map<Id, Decimal> quantityByLineId = new Map<Id, Decimal>();
    Map<Id, Date> productEndDateByLineId = new Map<Id, Date>();
    Map<Id, Date> targetByLineId = new Map<Id, Date>();
    Map<Id, Boolean> activatedByLineId = new Map<Id, Boolean>();
    for (OrderItem item : items) {
      if (item == null || item.Id == null) {
        continue;
      }
      quantityByLineId.put(item.Id, item.Quantity);
      productEndDateByLineId.put(item.Id, item.EndDate);
      Order order = ordersById.get(item.OrderId);
      Boolean activated = order != null && order.Status == 'Activated';
      activatedByLineId.put(item.Id, activated);
      targetByLineId.put(
        item.Id,
        activated
          ? Date.today()
          : (order != null &&
              order.Order_Start_Date__c != null
              ? order.Order_Start_Date__c
              : (order != null ? order.EffectiveDate : null))
      );
    }

    List<MonthlyPayment__c> payments = lineIds.isEmpty()
      ? new List<MonthlyPayment__c>()
      : [
          SELECT
            OrderItem__c,
            FinalPrice__c,
            Monthly_Units__c,
            Access_Type__c,
            Start_date__c,
            End_date__c,
            Stat_Date_Trigger__c,
            End_Date_trigger__c
          FROM MonthlyPayment__c
          WHERE OrderItem__c IN :lineIds
        ];

    Map<Id, LinePriceResult> results = new Map<Id, LinePriceResult>();
    for (Id lineId : quantityByLineId.keySet()) {
      List<MonthlyPayment__c> linePayments = new List<MonthlyPayment__c>();
      for (MonthlyPayment__c payment : payments) {
        if (payment.OrderItem__c == lineId) {
          linePayments.add(payment);
        }
      }
      results.put(
        lineId,
        resolveLine(
          linePayments,
          quantityByLineId.get(lineId),
          productEndDateByLineId.get(lineId),
          targetByLineId.get(lineId)
        )
      );
    }
    return results;
  }

  private static LinePriceResult resolveLine(
    List<MonthlyPayment__c> payments,
    Decimal quantity,
    Date productEndDate,
    Date targetDate
  ) {
    LinePriceResult result = new LinePriceResult();
    result.usedFallback = false;
    result.missing = false;
    if (payments == null || payments.isEmpty()) {
      result.missing = true;
      result.infoTooltip = missingPaymentTooltip(targetDate);
      return result;
    }

    MonthlyPayment__c selected;
    for (MonthlyPayment__c payment : payments) {
      Date startDate = paymentStartDate(payment);
      Date endDate = paymentEndDate(payment);
      if (
        targetDate != null &&
        startDate != null &&
        startDate <= targetDate &&
        (endDate == null ||
        endDate >= targetDate)
      ) {
        selected = laterPayment(selected, payment);
      }
    }
    if (selected == null && targetDate != null) {
      for (MonthlyPayment__c payment : payments) {
        Date startDate = paymentStartDate(payment);
        if (
          startDate != null &&
          startDate.year() == targetDate.year() &&
          startDate.month() == targetDate.month()
        ) {
          selected = laterPayment(selected, payment);
        }
      }
    }
    if (selected == null && targetDate != null) {
      for (MonthlyPayment__c payment : payments) {
        Date startDate = paymentStartDate(payment);
        if (startDate != null && startDate <= targetDate) {
          selected = laterPayment(selected, payment);
        }
      }
      if (selected != null) {
        result.usedFallback = true;
      }
    }

    if (selected == null) {
      result.missing = true;
      result.infoTooltip = missingPaymentTooltip(targetDate);
      return result;
    }

    result.sourceStartDate = paymentStartDate(selected);
    // Full-month commercial display: Final ÷ Monthly Units (partial mid-month start/end).
    result.totalPrice = fullMonthTotalFromPayment(selected);
    if (quantity != null && quantity > 0 && result.totalPrice != null) {
      result.unitPrice = (result.totalPrice / quantity).setScale(2);
    }
    if (result.usedFallback) {
      String sourceMonth = formatMonthYear(result.sourceStartDate);
      result.infoTooltip = productEndDate != null &&
        productEndDate < Date.today()
        ? 'Product ended; prices from last payment ' + sourceMonth + '.'
        : 'No payment for ' +
          formatMonthYear(targetDate) +
          '; showing last payment ' +
          sourceMonth +
          '.';
    }
    return result;
  }

  /**
   * Product's Price for the table: full-month amount = FinalPrice ÷ Monthly Units.
   * When Monthly_Units__c is blank, recompute with the same rules as that formula field.
   */
  public static Decimal fullMonthTotalFromPayment(MonthlyPayment__c payment) {
    if (payment == null || payment.FinalPrice__c == null) {
      return null;
    }
    Decimal units = payment.Monthly_Units__c;
    if (units == null || units == 0) {
      units = PackageBuilderService.monthlyUnitsForAccessAndDates(
        payment.Access_Type__c,
        paymentStartDate(payment),
        paymentEndDate(payment)
      );
    }
    if (units == null || units == 0) {
      return payment.FinalPrice__c.setScale(2);
    }
    if (units == 1) {
      return payment.FinalPrice__c.setScale(2);
    }
    return snapNearNextInteger((payment.FinalPrice__c / units).setScale(2));
  }

  /** Division leftover like 7199.99 / 1.99 → next whole amount (7200 / 2). */
  private static Decimal snapNearNextInteger(Decimal value) {
    if (value == null) {
      return null;
    }
    Decimal floored = value.setScale(0, System.RoundingMode.DOWN);
    if (value - floored >= 0.99) {
      return floored + 1;
    }
    return value;
  }

  private static MonthlyPayment__c laterPayment(
    MonthlyPayment__c current,
    MonthlyPayment__c candidate
  ) {
    if (current == null) {
      return candidate;
    }
    Date currentStart = paymentStartDate(current);
    Date candidateStart = paymentStartDate(candidate);
    return candidateStart != null &&
      (currentStart == null ||
      candidateStart > currentStart)
      ? candidate
      : current;
  }

  private static Date paymentStartDate(MonthlyPayment__c payment) {
    return payment.Start_date__c != null
      ? payment.Start_date__c
      : payment.Stat_Date_Trigger__c;
  }

  private static Date paymentEndDate(MonthlyPayment__c payment) {
    return payment.End_date__c != null
      ? payment.End_date__c
      : payment.End_Date_trigger__c;
  }

  private static String missingPaymentTooltip(Date targetDate) {
    if (targetDate == null) {
      return 'No Monthly Payment found.';
    }
    return 'No payments found for ' + formatMonthYear(targetDate) + '.';
  }

  private static String formatMonthYear(Date value) {
    if (value == null) {
      return 'the selected month';
    }
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
}
