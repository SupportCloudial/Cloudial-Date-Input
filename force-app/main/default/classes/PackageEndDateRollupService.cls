/**
 * @description Computes rolled-up package end dates from OrderItems (same rules as OrderItemTriggerHandler)
 *              and applies Contract.EndDate then Order.EndDate so the order never exceeds the contract.
 */
public with sharing class PackageEndDateRollupService {
  /** Package Builder contract terms: Product2.Type__c value for Contract Terms lines. */
  public static final String PRODUCT_TYPE_CONTRACT_TERMS = 'Contract Terms';

  /**
   * Rollup state for one Order: whether any included (non–meter-extra) line has blank EndDate (open-ended),
   * and the max EndDate across bounded lines (may be null if no bounded ends).
   */
  public class OrderEndRollupState {
    public Boolean openEndedIncluded;
    public Date maxBoundedEnd;
  }

  /**
   * Same semantics as {@link OrderItemTriggerHandler#syncParentOrderEndDates} aggregates for one order.
   * Visible non–Contract-Terms lines only; blank EndDate on those lines means open-ended package.
   */
  public static OrderEndRollupState computeOrderEndRollupState(Id orderId) {
    OrderEndRollupState state = new OrderEndRollupState();
    state.openEndedIncluded = false;
    state.maxBoundedEnd = null;
    if (orderId == null) {
      return state;
    }

    for (AggregateResult ar : [
      SELECT COUNT(Id) totalCount, COUNT(EndDate) endCount
      FROM OrderItem
      WHERE
        OrderId = :orderId
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
        AND (Product2.Type__c = NULL
        OR Product2.Type__c != :PRODUCT_TYPE_CONTRACT_TERMS)
    ]) {
      Integer totalCount = (Integer) ar.get('totalCount');
      Integer endCount = (Integer) ar.get('endCount');
      if (
        totalCount != null &&
        endCount != null &&
        totalCount > 0 &&
        endCount < totalCount
      ) {
        state.openEndedIncluded = true;
        break;
      }
    }

    if (state.openEndedIncluded) {
      return state;
    }

    for (AggregateResult ar2 : [
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
      state.maxBoundedEnd = (Date) ar2.get('maxEnd');
    }
    return state;
  }

  /**
   * In-memory rollup for visible non–Contract-Terms lines (Package Builder item lists).
   */
  public static OrderEndRollupState computeOrderEndRollupStateFromLines(
    List<OrderItem> items
  ) {
    OrderEndRollupState state = new OrderEndRollupState();
    state.openEndedIncluded = false;
    state.maxBoundedEnd = null;
    if (items == null || items.isEmpty()) {
      return state;
    }
    Integer includedCount = 0;
    Integer endCount = 0;
    for (OrderItem oi : items) {
      if (!isRollupIncludedLine(oi)) {
        continue;
      }
      includedCount++;
      if (oi.EndDate == null) {
        state.openEndedIncluded = true;
      } else {
        endCount++;
        if (state.maxBoundedEnd == null || oi.EndDate > state.maxBoundedEnd) {
          state.maxBoundedEnd = oi.EndDate;
        }
      }
    }
    if (includedCount == 0) {
      state.openEndedIncluded = false;
      state.maxBoundedEnd = null;
    }
    return state;
  }

  /** Package end date from in-memory lines; null when open-ended or no included lines. */
  public static Date derivePackageEndDateFromLines(List<OrderItem> items) {
    OrderEndRollupState state = computeOrderEndRollupStateFromLines(items);
    return state.openEndedIncluded ? null : state.maxBoundedEnd;
  }

  public static Date derivePackageEndDateFromLines(
    List<OrderItem> items,
    Date fallbackEndDate
  ) {
    if (items == null || items.isEmpty()) {
      return fallbackEndDate;
    }
    OrderEndRollupState state = computeOrderEndRollupStateFromLines(items);
    if (state.openEndedIncluded) {
      return null;
    }
    if (state.maxBoundedEnd != null) {
      return state.maxBoundedEnd;
    }
    Boolean anyRollupLine = false;
    for (OrderItem oi : items) {
      if (isRollupIncludedLine(oi)) {
        anyRollupLine = true;
        break;
      }
    }
    if (!anyRollupLine) {
      return null;
    }
    return fallbackEndDate;
  }

  public static Date targetOrderEndFromRollupState(OrderEndRollupState state) {
    if (state == null) {
      return null;
    }
    return state.openEndedIncluded ? null : state.maxBoundedEnd;
  }

  private static Boolean isRollupIncludedLine(OrderItem oi) {
    return PackageBuilderService.isPackageRollupLine(oi);
  }

  /**
   * Merges existing line rollup with a proposed add/replace line.
   * @param proposedOpenEnded true when the new line is intentionally open-ended (e.g. replacement with no end).
   */
  public static Date mergeProposedIntoTargetOrderEnd(
    OrderEndRollupState state,
    Date proposedStart,
    Date proposedEnd,
    Boolean proposedOpenEnded
  ) {
    if (proposedOpenEnded == true) {
      return null;
    }
    if (state != null && state.openEndedIncluded == true) {
      return null;
    }
    Date d = state == null ? null : state.maxBoundedEnd;
    if (proposedStart != null) {
      d = (d == null) ? proposedStart : (proposedStart > d ? proposedStart : d);
    }
    if (proposedEnd != null) {
      d = (d == null) ? proposedEnd : (proposedEnd > d ? proposedEnd : d);
    }
    return d;
  }

  /**
   * Updates Contract.EndDate first (when extension is required), then updates Order.EndDate.
   * When targetOrderEnd is null, only the order is cleared; call {@link #alignContractEndsToOrderPackageRollups}
   * after line rollups so Contract.EndDate follows open-ended vs bounded orders.
   */
  public static void applyContractThenOrderEndForPackage(
    Id orderId,
    Date targetOrderEnd
  ) {
    if (orderId == null) {
      return;
    }
    List<Order> ordRows = [
      SELECT Id, ContractId, EndDate, Status
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (ordRows.isEmpty()) {
      return;
    }
    Order ord = ordRows[0];
    if (ord.Status == 'Cancelled' || ord.Status == 'Archived') {
      return;
    }

    if (targetOrderEnd == null) {
      if (ord.EndDate != null) {
        ord.put('EndDate', null);
        update ord;
      }
      return;
    }

    if (ord.EndDate == targetOrderEnd) {
      if (ord.ContractId != null) {
        extendContractsToCoverOrderEndDates(
          new List<Order>{
            new Order(
              Id = ord.Id,
              ContractId = ord.ContractId,
              EndDate = ord.EndDate
            )
          }
        );
      }
      return;
    }

    Order stub = new Order(
      Id = ord.Id,
      ContractId = ord.ContractId,
      EndDate = targetOrderEnd
    );
    extendContractsToCoverOrderEndDates(new List<Order>{ stub });
    ord.put('EndDate', targetOrderEnd);
    update ord;
  }

  /**
   * Platform rule: Order EndDate cannot exceed Contract.EndDate.
   * Extends bounded contracts before callers update orders (same logic as OrderItemTriggerHandler).
   */
  public static void extendContractsToCoverOrderEndDates(
    List<Order> ordersToUpdate
  ) {
    if (ordersToUpdate == null || ordersToUpdate.isEmpty()) {
      return;
    }
    Set<Id> updatingOrderIds = new Set<Id>();
    Map<Id, Date> maxIncomingEndByContractId = new Map<Id, Date>();
    for (Order ord : ordersToUpdate) {
      if (
        ord == null ||
        ord.Id == null ||
        ord.ContractId == null ||
        ord.EndDate == null
      ) {
        continue;
      }
      updatingOrderIds.add(ord.Id);
      Date prior = maxIncomingEndByContractId.get(ord.ContractId);
      if (prior == null || ord.EndDate > prior) {
        maxIncomingEndByContractId.put(ord.ContractId, ord.EndDate);
      }
    }
    if (maxIncomingEndByContractId.isEmpty()) {
      return;
    }
    Set<Id> contractIds = maxIncomingEndByContractId.keySet();
    Map<Id, Date> maxOtherOrderEndByContractId = new Map<Id, Date>();
    for (AggregateResult ar : [
      SELECT ContractId cid, MAX(EndDate) mx
      FROM Order
      WHERE
        ContractId IN :contractIds
        AND Id NOT IN :updatingOrderIds
        AND Status NOT IN ('Cancelled', 'Archived')
        AND EndDate != NULL
      GROUP BY ContractId
    ]) {
      Id cid = (Id) ar.get('cid');
      Date mx = (Date) ar.get('mx');
      if (cid != null && mx != null) {
        maxOtherOrderEndByContractId.put(cid, mx);
      }
    }
    List<Contract> contracts = [
      SELECT Id, EndDate
      FROM Contract
      WHERE Id IN :contractIds
    ];
    List<Contract> contractUpdates = new List<Contract>();
    for (Contract c : contracts) {
      if (c == null) {
        continue;
      }
      Date incoming = maxIncomingEndByContractId.get(c.Id);
      Date otherMax = maxOtherOrderEndByContractId.get(c.Id);
      Date requiredEnd = incoming;
      if (otherMax != null && (requiredEnd == null || otherMax > requiredEnd)) {
        requiredEnd = otherMax;
      }
      if (requiredEnd == null) {
        continue;
      }
      if (c.EndDate != null && requiredEnd > c.EndDate) {
        c.put('EndDate', requiredEnd);
        contractUpdates.add(c);
      }
    }
    if (!contractUpdates.isEmpty()) {
      update contractUpdates;
    }
  }

  /**
   * After Order.EndDate rollups, align Contract.EndDate to package reality:
   * if any non-cancelled/archived order on the contract has a blank EndDate, contract is open-ended (null);
   * otherwise contract end is the latest bounded order end (may shrink below a previously extended contract).
   */
  public static void alignContractEndsToOrderPackageRollups(
    Set<Id> contractIds
  ) {
    if (contractIds == null || contractIds.isEmpty()) {
      return;
    }
    Map<Id, Boolean> anyOpenOrderByContractId = new Map<Id, Boolean>();
    for (AggregateResult ar : [
      SELECT ContractId cid, COUNT(Id) totalOrders, COUNT(EndDate) ordersWithEnd
      FROM Order
      WHERE
        ContractId IN :contractIds
        AND Status NOT IN ('Cancelled', 'Archived')
      GROUP BY ContractId
    ]) {
      Id cid = (Id) ar.get('cid');
      if (cid == null) {
        continue;
      }
      Integer totalOrders = (Integer) ar.get('totalOrders');
      Integer ordersWithEnd = (Integer) ar.get('ordersWithEnd');
      if (
        totalOrders != null &&
        ordersWithEnd != null &&
        totalOrders > 0 &&
        ordersWithEnd < totalOrders
      ) {
        anyOpenOrderByContractId.put(cid, true);
      }
    }
    Map<Id, Date> maxBoundedOrderEndByContractId = new Map<Id, Date>();
    for (AggregateResult ar2 : [
      SELECT ContractId cid, MAX(EndDate) mx
      FROM Order
      WHERE
        ContractId IN :contractIds
        AND Status NOT IN ('Cancelled', 'Archived')
        AND EndDate != NULL
      GROUP BY ContractId
    ]) {
      Id cid = (Id) ar2.get('cid');
      Date mx = (Date) ar2.get('mx');
      if (cid != null) {
        maxBoundedOrderEndByContractId.put(cid, mx);
      }
    }
    List<Contract> contracts = [
      SELECT Id, EndDate
      FROM Contract
      WHERE Id IN :contractIds
    ];
    List<Contract> contractUpdates = new List<Contract>();
    for (Contract c : contracts) {
      if (c == null) {
        continue;
      }
      Date targetEnd = anyOpenOrderByContractId.containsKey(c.Id)
        ? null
        : maxBoundedOrderEndByContractId.get(c.Id);
      if (c.EndDate != targetEnd) {
        c.put('EndDate', targetEnd);
        contractUpdates.add(c);
      }
    }
    if (!contractUpdates.isEmpty()) {
      update contractUpdates;
    }
  }
}
