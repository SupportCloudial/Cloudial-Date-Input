public with sharing class OrderTriggerHandler extends TriggerHandler {
  /**
   * When replacement start clamps order start, Contract.StartDate may need to move earlier.
   * Populate during before insert/update; do not DML here (before triggers) — flush in after insert/update.
   */
  private static Map<Id, Date> contractStartDateSyncByContractId = new Map<Id, Date>();

  /** Test-only override; null uses custom label Order_Trigger_Handler_Enabled. */
  @TestVisible
  private static Boolean orderTriggerHandlerEnabledOverride;

  public OrderTriggerHandler() {
    super('OrderTriggerHandler');
  }

  public override void beforeInsert(List<SObject> triggerNew) {
    List<Order> orders = (List<Order>) triggerNew;
    copyContractFieldsToOrder(orders, null);
    applyOrderStartDateRules(orders);
  }

  public override void afterInsert(Map<Id, SObject> newMap) {
    flushContractStartDateSyncFromReplacementClamp();
    syncReplacementOrderItems((Map<Id, Order>) newMap, null);
    // Seed global credit lines (Extra for all products: Credits/Prints/Deposit) for Closed Won orders even
    // when no package lines exist yet. Match flow-created orders by Opportunity link and/or Order Origin;
    // do not rely on Order_Origin__c alone (picklist / automation differences).
    Set<Id> originalFlowOrderIds = new Set<Id>();
    for (SObject so : newMap.values()) {
      Order o = (Order) so;
      if (o == null || o.ContractId == null || o.Previous_Order__c != null) {
        continue;
      }
      // Flow sets custom Opportunity__c; tests and some UIs use standard OpportunityId.
      Boolean linkedToOpp = o.Opportunity__c != null || o.OpportunityId != null;
      Boolean closedWonStyle =
        linkedToOpp || o.Order_Origin__c == 'Original Order';
      if (closedWonStyle) {
        originalFlowOrderIds.add(o.Id);
      }
    }
    ExtraCreditOrderItemService.ensureExtraCreditLinesForOrderIds(
      originalFlowOrderIds
    );
  }

  public override void beforeUpdate(
    Map<Id, SObject> newMap,
    Map<Id, SObject> oldMap
  ) {
    List<Order> newOrders = new List<Order>();
    for (SObject so : newMap.values()) {
      newOrders.add((Order) so);
    }

    // Trigger.old/Trigger.new are typed as Map<Id, SObject>, but our helper expects Map<Id, Order>.
    // Convert without relying on runtime generic type casts.
    Map<Id, Order> oldOrders = new Map<Id, Order>();
    if (oldMap != null) {
      for (Id keyId : oldMap.keySet()) {
        oldOrders.put(keyId, (Order) oldMap.get(keyId));
      }
    }
    copyContractFieldsToOrder(newOrders, oldOrders);
    applyOrderStartDateRules(newOrders);
  }

  public override void afterUpdate(
    Map<Id, SObject> newMap,
    Map<Id, SObject> oldMap
  ) {
    flushContractStartDateSyncFromReplacementClamp();
    syncDraftOrderItemDatesOnOrderStartChange(
      (Map<Id, Order>) newMap,
      (Map<Id, Order>) oldMap
    );

    // Sync replacement order items when Order_Start_Date__c / replacement floor changes
    syncReplacementOrderItems((Map<Id, Order>) newMap, (Map<Id, Order>) oldMap);

    // On draft activation, do not mutate previous active order or its items.
    // Previous order archival/status handling is owned by PackageBuilderService.

    // Write Order renewal/agreement fields back to Contract when Order activates
    syncOrderFieldsToContractOnActivation(
      (Map<Id, Order>) newMap,
      (Map<Id, Order>) oldMap
    );
  }

  /**
   * When an Order transitions to Activated and has a ContractId, copy the Order's
   * renewal/agreement fields to the related Contract.
   */
  private void syncOrderFieldsToContractOnActivation(
    Map<Id, Order> newMap,
    Map<Id, Order> oldMap
  ) {
    Set<Id> orderIdsWithContract = new Set<Id>();
    for (Id id : newMap.keySet()) {
      Order newOrder = newMap.get(id);
      Order oldOrder = oldMap.get(id);
      if (
        newOrder.Status == 'Activated' &&
        oldOrder.Status != 'Activated' &&
        newOrder.ContractId != null
      ) {
        orderIdsWithContract.add(id);
      }
    }
    if (orderIdsWithContract.isEmpty())
      return;

    List<Order> orders = [
      SELECT
        Id,
        ContractId,
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
        External_ID__c,
        EndDate,
        Depusit_Amount_DM__c,
        Lease_Termination_Notice_Months__c,
        Number_of_members__c,
        Payment_Method__c,
        Track_CPI__c,
        Track_CPI_Date__c
      FROM Order
      WHERE Id IN :orderIdsWithContract
    ];
    Set<Id> contractIds = new Set<Id>();
    Map<Id, Order> orderByContractId = new Map<Id, Order>();
    for (Order o : orders) {
      if (o.ContractId != null) {
        contractIds.add(o.ContractId);
        orderByContractId.put(o.ContractId, o);
      }
    }
    if (contractIds.isEmpty())
      return;

    List<Contract> contracts = [
      SELECT
        Id,
        Agreement_language__c,
        Credits_for_MR__c,
        Prints_Color__c,
        Prints_B_W__c,
        EndDate,
        Auto_Renewal__c,
        Renewal_Status__c,
        Renewal_Total_Iterations__c,
        Last_Status_Change_Date__c,
        Non_Renewal_Reason__c,
        Renewal_Period_Months__c,
        Description,
        External_ID__c,
        Depusit_Amount_DM__c,
        Lease_Termination_Notice_Months__c,
        Number_of_members__c,
        Payment_Method__c,
        Track_CPI__c,
        Track_CPI_Date__c
      FROM Contract
      WHERE Id IN :contractIds
    ];
    List<Contract> toUpdate = new List<Contract>();
    for (Contract c : contracts) {
      Order ord = orderByContractId.get(c.Id);
      if (ord == null)
        continue;
      c.Agreement_language__c = ord.Agreement_language__c;
      c.Credits_for_MR__c = ord.Credits_for_MR__c;
      c.Prints_Color__c = ord.Prints_Color__c;
      c.Prints_B_W__c = ord.Prints_B_W__c;
      c.Auto_Renewal__c = ord.Auto_Renewal__c;
      c.Renewal_Status__c = ord.Renewal_Status__c;
      c.Renewal_Total_Iterations__c = ord.Renewal_Total_Iterations__c;
      c.Last_Status_Change_Date__c = ord.Last_Status_Change_Date__c;
      c.Non_Renewal_Reason__c = ord.Non_Renewal_Reason__c;
      c.Renewal_Period_Months__c = ord.Renewal_Period_Months__c;
      c.Description = ord.Description;
      c.External_ID__c = ord.External_ID__c;
      c.Depusit_Amount_DM__c = ord.Depusit_Amount_DM__c;
      c.Lease_Termination_Notice_Months__c = ord.Lease_Termination_Notice_Months__c;
      c.Number_of_members__c = ord.Number_of_members__c;
      c.Payment_Method__c = ord.Payment_Method__c;
      c.Track_CPI__c = ord.Track_CPI__c;
      c.Track_CPI_Date__c = ord.Track_CPI_Date__c;
      c.put('EndDate', ord.EndDate);
      toUpdate.add(c);
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
  }

  public static Boolean isOrderTriggerHandlerEnabled() {
    if (orderTriggerHandlerEnabledOverride != null) {
      return orderTriggerHandlerEnabledOverride;
    }
    String v = Label.Order_Trigger_Handler_Enabled;
    return String.isBlank(v) || 'true'.equalsIgnoreCase(v.trim());
  }

  /**
   * When an Order is created or linked to a Contract (ContractId set), copy the Contract's
   * renewal/agreement fields to the Order so the order section and modal show current Contract values.
   * On insert only, also sets Order.EffectiveDate from Contract.StartDate (not updated on later ContractId changes).
   */
  private void copyContractFieldsToOrder(
    List<Order> newOrders,
    Map<Id, Order> oldMap
  ) {
    Set<Id> contractIds = new Set<Id>();
    for (Order o : newOrders) {
      if (o.ContractId == null)
        continue;
      if (oldMap == null) {
        contractIds.add(o.ContractId);
      } else {
        Order oldOrder = oldMap.get(o.Id);
        if (oldOrder == null || oldOrder.ContractId != o.ContractId) {
          contractIds.add(o.ContractId);
        }
      }
    }
    if (contractIds.isEmpty())
      return;

    Map<Id, Contract> contractMap = new Map<Id, Contract>(
      [
        SELECT
          Id,
          StartDate,
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
          External_ID__c,
          Depusit_Amount_DM__c,
          Lease_Termination_Notice_Months__c,
          Number_of_members__c,
          Payment_Method__c,
          Track_CPI__c,
          Track_CPI_Date__c
        FROM Contract
        WHERE Id IN :contractIds
      ]
    );
    for (Order o : newOrders) {
      if (o.ContractId == null)
        continue;
      Contract c = contractMap.get(o.ContractId);
      if (c == null)
        continue;
      Boolean shouldCopy =
        (oldMap == null) ||
        (oldMap.get(o.Id) != null &&
        oldMap.get(o.Id).ContractId != o.ContractId);
      if (!shouldCopy)
        continue;
      o.Agreement_language__c = c.Agreement_language__c;
      o.Credits_for_MR__c = c.Credits_for_MR__c;
      o.Prints_Color__c = c.Prints_Color__c;
      o.Prints_B_W__c = c.Prints_B_W__c;
      o.Auto_Renewal__c = c.Auto_Renewal__c;
      o.Renewal_Status__c = c.Renewal_Status__c;
      o.Renewal_Total_Iterations__c = c.Renewal_Total_Iterations__c;
      o.Last_Status_Change_Date__c = c.Last_Status_Change_Date__c;
      o.Non_Renewal_Reason__c = c.Non_Renewal_Reason__c;
      o.Renewal_Period_Months__c = c.Renewal_Period_Months__c;
      o.Description = c.Description;
      o.External_ID__c = c.External_ID__c;
      // Do not clear  when Contract has no location (Order may require it on insert).
      o.Depusit_Amount_DM__c = c.Depusit_Amount_DM__c;
      o.Lease_Termination_Notice_Months__c = c.Lease_Termination_Notice_Months__c;
      o.Number_of_members__c = c.Number_of_members__c;
      o.Payment_Method__c = c.Payment_Method__c;
      o.Track_CPI__c = c.Track_CPI__c;
      o.Track_CPI_Date__c = c.Track_CPI_Date__c;
      if (oldMap == null && c.StartDate != null) {
        o.EffectiveDate = c.StartDate;
      }
    }
  }

  private void syncReplacementOrderItems(
    Map<Id, Order> newOrders,
    Map<Id, Order> oldOrders
  ) {
    Set<Id> previousOrderIds = new Set<Id>();
    Set<Id> currentOrderIds = new Set<Id>();
    Map<Id, Order> replacementOrdersByPrevId = new Map<Id, Order>();
    Map<Id, Order> currentOrdersById = new Map<Id, Order>();

    for (Order newOrder : newOrders.values()) {
      Boolean shouldProcess = false;

      if (newOrder.Previous_Order__c != null) {
        if (oldOrders == null) {
          // afterInsert: Always process
          shouldProcess = true;
        } else {
          Order oldOrder = oldOrders.get(newOrder.Id);
          Boolean activationTransition =
            oldOrder != null &&
            oldOrder.Status != 'Activated' &&
            newOrder.Status == 'Activated';
          if (
            newOrder.Replacement_Start_Date__c !=
            oldOrder.Replacement_Start_Date__c ||
            orderStartForBusiness(newOrder) != orderStartForBusiness(oldOrder)
          ) {
            shouldProcess = true;
          }
          // On Draft/Negotiation -> Activated, handleOrderSwitchOver will curtail old lines and
          // activation service aligns current lines; skip this pass to avoid duplicate OrderItem DML.
          if (activationTransition) {
            shouldProcess = false;
          }
        }
      }

      // Only sync replacement items when the replacement order is activated.
      // Do not sync while cancelling/archiving status transitions.
      if (shouldProcess && newOrder.Status == 'Activated') {
        previousOrderIds.add(newOrder.Previous_Order__c);
        currentOrderIds.add(newOrder.Id);
        replacementOrdersByPrevId.put(newOrder.Previous_Order__c, newOrder);
        currentOrdersById.put(newOrder.Id, newOrder);
      }
    }

    if (previousOrderIds.isEmpty() && currentOrderIds.isEmpty())
      return;

    // Query both previous order items AND current order items
    List<OrderItem> allItemsToUpdate = [
      SELECT
        Id,
        OrderId,
        ServiceDate,
        EndDate,
        Access_Type__c,
        Change_Action_Type__c,
        Change_Action_Effective_End_Date__c,
        Original_Order_Product__c,
        Replaced_Order_Product__c
      FROM OrderItem
      WHERE OrderId IN :previousOrderIds OR OrderId IN :currentOrderIds
    ];

    List<OrderItem> itemsToUpdate = new List<OrderItem>();
    for (OrderItem oi : allItemsToUpdate) {
      Boolean changed = false;
      if (previousOrderIds.contains(oi.OrderId)) {
        // Handle Old Order Items (Curtailment)
        Order replacementOrder = replacementOrdersByPrevId.get(oi.OrderId);
        Date orderStart = orderStartForBusiness(replacementOrder);
        Date replacementFloor = replacementOrder.Replacement_Start_Date__c !=
          null
          ? replacementOrder.Replacement_Start_Date__c
          : orderStart;

        String targetType = 'Removed';
        Date targetEffectiveEnd = (replacementFloor != null
            ? replacementFloor
            : Date.today())
          .addDays(-1);
        if (oi.Change_Action_Type__c != targetType) {
          oi.Change_Action_Type__c = targetType;
          changed = true;
        }
        if (oi.Change_Action_Effective_End_Date__c != targetEffectiveEnd) {
          oi.Change_Action_Effective_End_Date__c = targetEffectiveEnd;
          changed = true;
        }
      } else if (currentOrderIds.contains(oi.OrderId)) {
        // Handle New Order Items (Start Date Sync)
        Order currentOrder = currentOrdersById.get(oi.OrderId);
        Order oldOrder = (oldOrders != null)
          ? oldOrders.get(currentOrder.Id)
          : null;

        Date currentOrderStart = orderStartForBusiness(currentOrder);
        Date rawReplacementFloor = currentOrder.Replacement_Start_Date__c;

        // ServiceDate cannot be earlier than business order start (Order_Start_Date__c, else EffectiveDate legacy).
        Date replacementFloor = rawReplacementFloor != null
          ? (rawReplacementFloor < currentOrderStart
              ? currentOrderStart
              : rawReplacementFloor)
          : currentOrderStart;

        Date oldOrderStart = (oldOrder != null)
          ? orderStartForBusiness(oldOrder)
          : null;
        Date oldRawFloor = (oldOrder != null)
          ? oldOrder.Replacement_Start_Date__c
          : null;
        Date oldFloor = (oldOrder != null)
          ? (oldRawFloor != null
              ? (oldRawFloor < oldOrderStart ? oldOrderStart : oldRawFloor)
              : oldOrderStart)
          : null;

        // Carry-over lines (draft clone) keep inherited product start; product-swap lines still sync.
        Boolean isCarryOverLine =
          oi.Original_Order_Product__c != null &&
          oi.Replaced_Order_Product__c == null;

        if (
          !isCarryOverLine &&
          (oi.ServiceDate == null ||
          oi.ServiceDate < replacementFloor ||
          (oldFloor != null &&
          oi.ServiceDate == oldFloor) ||
          (oldOrderStart != null &&
          oi.ServiceDate == oldOrderStart))
        ) {
          if (oi.ServiceDate != replacementFloor) {
            oi.ServiceDate = replacementFloor;
            changed = true;
          }
        }

        // Ensure End Date is not earlier than Start Date (standard validation).
        // "Modify Contract" cloning/sync should preserve monthly products' empty end-date.
        // - If EndDate is null and Access_Type__c = 'Monthly' => keep it null.
        // - If EndDate is provided and is earlier than ServiceDate => clamp to ServiceDate.
        Boolean isMonthly = (oi.Access_Type__c == 'Monthly');
        if (!isMonthly) {
          // For non-monthly access types, ensure a non-null end date and clamp if needed.
          if (oi.EndDate == null || oi.EndDate < oi.ServiceDate) {
            Date targetEnd = currentOrder.EndDate != null
              ? currentOrder.EndDate
              : oi.ServiceDate;
            if (oi.EndDate != targetEnd) {
              oi.put('EndDate', targetEnd);
              changed = true;
            }
          }
        } else {
          // For monthly access types, preserve empty end date.
          if (oi.EndDate != null && oi.EndDate < oi.ServiceDate) {
            if (oi.EndDate != oi.ServiceDate) {
              oi.put('EndDate', oi.ServiceDate);
              changed = true;
            }
          }
        }

        // IMPORTANT: Ensure we clear any stale Curtailment/Removal fields if we are re-syncing this item
        // as an active part of a replacement order.
        if (oi.Change_Action_Type__c != null) {
          oi.Change_Action_Type__c = null;
          changed = true;
        }
        if (oi.Change_Action_Effective_End_Date__c != null) {
          oi.Change_Action_Effective_End_Date__c = null;
          changed = true;
        }
      }
      if (changed) {
        itemsToUpdate.add(oi);
      }
    }

    if (!itemsToUpdate.isEmpty()) {
      update itemsToUpdate;
    }
  }

  /**
   * Canonical business start: Order_Start_Date__c when set; otherwise EffectiveDate (contract anchor on insert, legacy API).
   */
  private static Date orderStartForBusiness(Order o) {
    if (o == null) {
      return null;
    }
    return o.Order_Start_Date__c != null
      ? o.Order_Start_Date__c
      : o.EffectiveDate;
  }

  /**
   * Clamp Order_Start_Date__c vs Replacement_Start_Date__c; may queue Contract.StartDate sync (after trigger).
   * Does not read or write Order.EffectiveDate (set once from Contract on insert in copyContractFieldsToOrder).
   */
  private void applyOrderStartDateRules(List<Order> newOrders) {
    if (newOrders == null || newOrders.isEmpty()) {
      return;
    }
    // One queue per trigger invocation (insert/update). Avoids stale entries when tests call before* only.
    contractStartDateSyncByContractId.clear();

    for (Order o : newOrders) {
      if (o.Replacement_Start_Date__c != null) {
        if (
          o.Order_Start_Date__c == null ||
          o.Order_Start_Date__c > o.Replacement_Start_Date__c
        ) {
          o.Order_Start_Date__c = o.Replacement_Start_Date__c;
          if (o.ContractId != null) {
            Date desired = o.Order_Start_Date__c;
            Date existing = contractStartDateSyncByContractId.get(o.ContractId);
            if (existing == null || desired < existing) {
              contractStartDateSyncByContractId.put(o.ContractId, desired);
            }
          }
        }
      }
    }
  }

  private static void flushContractStartDateSyncFromReplacementClamp() {
    if (contractStartDateSyncByContractId.isEmpty()) {
      return;
    }
    Set<Id> contractIds = new Set<Id>(
      contractStartDateSyncByContractId.keySet()
    );
    Map<Id, Contract> contracts = new Map<Id, Contract>(
      [SELECT Id, StartDate FROM Contract WHERE Id IN :contractIds]
    );
    List<Contract> toUpdate = new List<Contract>();
    for (Id cid : contractIds) {
      Date desired = contractStartDateSyncByContractId.get(cid);
      Contract con = contracts.get(cid);
      if (
        con != null &&
        desired != null &&
        (con.StartDate == null ||
        con.StartDate > desired)
      ) {
        con.StartDate = desired;
        toUpdate.add(con);
      }
    }
    contractStartDateSyncByContractId.clear();
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
  }

  private void syncDraftOrderItemDatesOnOrderStartChange(
    Map<Id, Order> newOrders,
    Map<Id, Order> oldOrders
  ) {
    if (newOrders == null || newOrders.isEmpty() || oldOrders == null) {
      return;
    }

    for (Id orderId : newOrders.keySet()) {
      Order newOrder = newOrders.get(orderId);
      Order oldOrder = oldOrders.get(orderId);
      if (newOrder == null || oldOrder == null) {
        continue;
      }
      if (newOrder.Status != 'Draft') {
        continue;
      }
      Date newStart = orderStartForBusiness(newOrder);
      Date oldStart = orderStartForBusiness(oldOrder);
      if (newStart == null || newStart == oldStart) {
        continue;
      }
      Boolean isBackdate = oldStart != null && newStart < oldStart;
      Boolean alignNewLines = !isBackdate;
      PackageBuilderController.alignOrderItemDatesForStartDateChangeCore(
        orderId,
        newStart,
        alignNewLines,
        false
      );
    }
  }
}
