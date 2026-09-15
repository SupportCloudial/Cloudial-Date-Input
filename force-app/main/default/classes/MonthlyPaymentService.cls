/**
 * @description       : The MonthlyPaymentService class manages updates to the Aggregated_Price_Adjustment__c field on OpportunityLineItem and OrderItem records based on related
 *                      monthly payments
 * @author            : LAURIE CS
 * @group             :
 * @last modified on  : 2024-11-07
 **/
public with sharing class MonthlyPaymentService {
  public MonthlyPaymentService() {
  }

  /**
   * @description : Updates the field Aggregated_Price_Adjustment__c on oppLineItem object
   * @param oppLineItemsUpdatedNew : Map of updated OpportunityLineItem Ids to new OpportunityLineItem records.
   **/
  public static void updateAggregatedPriceAdjustmentForLineItem(
    Map<Id, MonthlyPayment__c> mpMap
  ) {
    Map<Id, Decimal> lineItemAdjustments = new Map<Id, Decimal>();
    Map<Id, Decimal> oppLineItemAggregatePrice = new Map<Id, Decimal>();
    Set<Id> oppLineItemIds = new Set<Id>();

    List<MonthlyPayment__c> seedOppPayments = [
      SELECT OpportunityLineItem__c, Calculated_Price_Adjutment__c
      FROM MonthlyPayment__c
      WHERE Id IN :mpMap.keySet()
    ];
    for (MonthlyPayment__c mp : seedOppPayments) {
      if (mp.OpportunityLineItem__c != null) {
        oppLineItemIds.add(mp.OpportunityLineItem__c);
      }
    }

    if (!oppLineItemIds.isEmpty()) {
      List<MonthlyPayment__c> allPayments = [
        SELECT
          OpportunityLineItem__c,
          Calculated_Price_Adjutment__c,
          List_Price_Adjustment__c
        FROM MonthlyPayment__c
        WHERE OpportunityLineItem__c IN :oppLineItemIds
      ];

      for (MonthlyPayment__c payment : allPayments) {
        if (payment.OpportunityLineItem__c != null) {
          Id lineItemId = payment.OpportunityLineItem__c;
          Decimal adjustment = payment.Calculated_Price_Adjutment__c != null
            ? payment.Calculated_Price_Adjutment__c
            : 0;
          Decimal listPriceAdj = payment.List_Price_Adjustment__c != null
            ? payment.List_Price_Adjustment__c
            : 0;

          if (oppLineItemAggregatePrice.containsKey(lineItemId)) {
            oppLineItemAggregatePrice.put(
              lineItemId,
              oppLineItemAggregatePrice.get(lineItemId) + listPriceAdj
            );
          } else {
            oppLineItemAggregatePrice.put(lineItemId, listPriceAdj);
          }

          if (lineItemAdjustments.containsKey(lineItemId)) {
            lineItemAdjustments.put(
              lineItemId,
              lineItemAdjustments.get(lineItemId) + adjustment
            );
          } else {
            lineItemAdjustments.put(lineItemId, adjustment);
          }
        }
      }

      List<OpportunityLineItem> oppLineItems = [
        SELECT
          Id,
          Aggregated_Price_Adjustment__c,
          Aggregated_List_Price_Adjustment__c
        FROM OpportunityLineItem
        WHERE Id IN :oppLineItemIds
      ];

      for (OpportunityLineItem lineItem : oppLineItems) {
        lineItem.Aggregated_Price_Adjustment__c = lineItemAdjustments.containsKey(
            lineItem.Id
          )
          ? lineItemAdjustments.get(lineItem.Id)
          : 0;
        lineItem.Aggregated_List_Price_Adjustment__c = oppLineItemAggregatePrice.containsKey(
            lineItem.Id
          )
          ? oppLineItemAggregatePrice.get(lineItem.Id)
          : 0;
      }
      if (!oppLineItems.isEmpty()) {
        update oppLineItems;
      }
    }
  }

  /**
   * @description : Updates the field Aggregated_Price_Adjustment__c on orderItem object
   * @param orderItemsUpdatedNew : Map of updated OrderItem Ids to new OrderItem records.
   **/
  public static void updateAggregatedPriceAdjustmentForOrderItem(
    Map<Id, MonthlyPayment__c> mpMap
  ) {
    Map<Id, Decimal> orderItemAdjustments = new Map<Id, Decimal>();
    Map<Id, Decimal> orderItemListPriceAdjustments = new Map<Id, Decimal>();
    Set<Id> orderItemIds = new Set<Id>();

    List<MonthlyPayment__c> seedOrderPayments = [
      SELECT OrderItem__c
      FROM MonthlyPayment__c
      WHERE Id IN :mpMap.keySet()
    ];
    for (MonthlyPayment__c mp : seedOrderPayments) {
      if (mp.OrderItem__c != null) {
        orderItemIds.add(mp.OrderItem__c);
      }
    }

    if (!orderItemIds.isEmpty()) {
      List<MonthlyPayment__c> allPayments = [
        SELECT
          OrderItem__c,
          Calculated_Price_Adjutment__c,
          List_Price_Adjustment__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c IN :orderItemIds
      ];

      for (MonthlyPayment__c payment : allPayments) {
        if (payment.OrderItem__c == null)
          continue;

        Id orderItemId = payment.OrderItem__c;
        Decimal priceAdj = payment.Calculated_Price_Adjutment__c != null
          ? payment.Calculated_Price_Adjutment__c
          : 0;
        Decimal listPriceAdj = payment.List_Price_Adjustment__c != null
          ? payment.List_Price_Adjustment__c
          : 0;
        System.debug('@@priceAdj' + priceAdj);
        orderItemAdjustments.put(
          orderItemId,
          orderItemAdjustments.containsKey(orderItemId)
            ? orderItemAdjustments.get(orderItemId) + priceAdj
            : priceAdj
        );
        System.debug('@@orderItemAdjustments' + orderItemAdjustments);
        orderItemListPriceAdjustments.put(
          orderItemId,
          orderItemListPriceAdjustments.containsKey(orderItemId)
            ? orderItemListPriceAdjustments.get(orderItemId) + listPriceAdj
            : listPriceAdj
        );
      }

      List<OrderItem> orderItemsToUpdate = [
        SELECT
          Id,
          Aggregated_Price_Adjustment__c,
          Aggregated_List_Price_Adjustment__c
        FROM OrderItem
        WHERE Id IN :orderItemIds
      ];

      for (OrderItem oi : orderItemsToUpdate) {
        oi.Aggregated_Price_Adjustment__c = orderItemAdjustments.get(oi.Id) !=
          null
          ? orderItemAdjustments.get(oi.Id)
          : 0;

        oi.Aggregated_List_Price_Adjustment__c = orderItemListPriceAdjustments.get(
            oi.Id
          ) != null
          ? orderItemListPriceAdjustments.get(oi.Id)
          : 0;
      }

      if (!orderItemsToUpdate.isEmpty()) {
        update orderItemsToUpdate;
      }
    }
  }

  /* -------------------------------------------------- ROOM25-179 -------------------------------------------------- */

  public static void updateListPriceAggregatedAdjustmentForLineItem(
    Map<Id, MonthlyPayment__c> mpMap
  ) {
  }

  /*public static void updateListPriceAggregatedAdjustmentForOrderItem(
     Map<Id, MonthlyPayment__c> mpMap
   ) {
     Map<Id, Decimal> orderItemAdjustments = new Map<Id, Decimal>();
     Set<Id> orderItemIds = new Set<Id>();
     for (MonthlyPayment__c mp : [
       SELECT OrderItem__c, OrderItem__r.Aggregated_List_Price_Adjustment__c
       FROM MonthlyPayment__c
       WHERE Id IN :mpMap.keySet()
     ]) {
       orderItemIds.add(mp.OrderItem__c);
    }
    List<MonthlyPayment__c> allPayments = [
      SELECT OrderItem__c, OrderItem__r.Aggregated_List_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :orderItemIds
    ];
    for (MonthlyPayment__c payment : allPayments) {
      if (payment.OrderItem__c != null) {
        Id orderItemId = payment.OrderItem__c;
        Decimal adjustment = payment.OrderItem__r.Aggregated_List_Price_Adjustment__c !=
          null
          ? payment.OrderItem__r.Aggregated_List_Price_Adjustment__c
          : 0;
        if (orderItemAdjustments.containsKey(orderItemId)) {
          orderItemAdjustments.put(
            orderItemId,
            orderItemAdjustments.get(orderItemId) + adjustment
          );
        } else {
          orderItemAdjustments.put(orderItemId, adjustment);
        }
      }
    }
    if (!orderItemIds.isEmpty()) {
      List<OrderItem> orderItems = [
        SELECT Id, Aggregated_List_Price_Adjustment__c
        FROM OrderItem
        WHERE Id IN :orderItemIds
      ];
      for (OrderItem orderItem : orderItems) {
        orderItem.Aggregated_List_Price_Adjustment__c = orderItemAdjustments.containsKey(
            orderItem.Id
          )
          ? orderItemAdjustments.get(orderItem.Id)
          : 0;
      }
      if (!orderItems.isEmpty()) {
        update orderItems;
      }
    }
  }*/
}