/**
 * @description       : trigger handler for MonthlyPayment Object
 * @author            : LAURIE CS
 * @last modified on  : 2024-11-07
 * @created on  : 2024-10-28
 * @last modified by  : LAURIE CS
 **/
public with sharing class MonthlyPaymentTriggerHandler extends TriggerHandler {
  public MonthlyPaymentTriggerHandler() {
    super('MonthlyPaymentTriggerHandler');
  }

  public override void beforeInsert(List<SObject> triggerNew) {
    PackageBuilderService.applyFinalAdjustedPriceBeforeSave(
      (List<MonthlyPayment__c>) triggerNew,
      null
    );
  }

  public override void beforeUpdate(
    Map<Id, SObject> triggerNewMap,
    Map<Id, SObject> triggerOldMap
  ) {
    PackageBuilderService.applyFinalAdjustedPriceBeforeSave(
      (List<MonthlyPayment__c>) triggerNewMap.values(),
      (Map<Id, MonthlyPayment__c>) triggerOldMap
    );
  }

  /**
   * MonthlyPayment after-update aggregation (OrderItem / OpportunityLineItem rollups) only needs to run
   * when fields that feed those rollups change. Date-only updates (e.g. flow "Order Item- Sync Dates
   * with Monthly Payments") must not run it — each batch costs several SOQL plus OrderItem DML, which
   * stacks with flows and can hit the 100 SOQL synchronous limit on draft activation.
   */
  private static Boolean aggregatesNeedRecalcForLineItem(
    MonthlyPayment__c newMp,
    MonthlyPayment__c oldMp
  ) {
    if (oldMp == null) {
      return true;
    }
    return newMp.OpportunityLineItem__c != oldMp.OpportunityLineItem__c ||
      newMp.Calculated_Price_Adjutment__c !=
      oldMp.Calculated_Price_Adjutment__c ||
      newMp.List_Price_Adjustment__c != oldMp.List_Price_Adjustment__c ||
      finalAdjustedPriceChangedForAggregate(
        newMp.Final_Adjusted_Price__c,
        oldMp.Final_Adjusted_Price__c
      );
  }

  private static Boolean aggregatesNeedRecalcForOrderItem(
    MonthlyPayment__c newMp,
    MonthlyPayment__c oldMp
  ) {
    if (oldMp == null) {
      return true;
    }
    return newMp.OrderItem__c != oldMp.OrderItem__c ||
      newMp.Calculated_Price_Adjutment__c !=
      oldMp.Calculated_Price_Adjutment__c ||
      newMp.List_Price_Adjustment__c != oldMp.List_Price_Adjustment__c ||
      finalAdjustedPriceChangedForAggregate(
        newMp.Final_Adjusted_Price__c,
        oldMp.Final_Adjusted_Price__c
      );
  }

  /**
   * Date-sync clears FAP to unset so FinalPrice can derive. That must not fan out
   * OrderItem rollups (each batch is several SOQL + DML and re-enters date flows).
   */
  private static Boolean finalAdjustedPriceChangedForAggregate(
    Decimal newFap,
    Decimal oldFap
  ) {
    Boolean newUsable = PackageBuilderService.isUsableFinalAdjustedPrice(
      newFap
    );
    Boolean oldUsable = PackageBuilderService.isUsableFinalAdjustedPrice(
      oldFap
    );
    if (!newUsable && oldUsable) {
      return false;
    }
    return newFap != oldFap;
  }

  public override void afterInsert(Map<Id, SObject> monthlyPaymentNMap) {
    Map<Id, MonthlyPayment__c> mpMap = (Map<Id, MonthlyPayment__c>) monthlyPaymentNMap;
    PackageBuilderService.ensureFinalAdjustedPriceAfterInsert(mpMap.values());
    MonthlyPaymentService.updateAggregatedPriceAdjustmentForLineItem(mpMap);
    MonthlyPaymentService.updateAggregatedPriceAdjustmentForOrderItem(mpMap);
    MonthlyPaymentService.updateListPriceAggregatedAdjustmentForLineItem(mpMap);
  }

  public override void afterUpdate(
    Map<Id, SObject> triggerNewMap,
    Map<Id, SObject> triggerOldMap
  ) {
    Map<Id, MonthlyPayment__c> newMap = (Map<Id, MonthlyPayment__c>) triggerNewMap;
    Map<Id, MonthlyPayment__c> oldMap = (Map<Id, MonthlyPayment__c>) triggerOldMap;

    Set<Id> fapRefreshIds = new Set<Id>();
    for (Id mpId : newMap.keySet()) {
      MonthlyPayment__c newMp = newMap.get(mpId);
      MonthlyPayment__c oldMp = oldMap.get(mpId);
      if (newMp == null || oldMp == null) {
        continue;
      }
      if (newMp.Discount__c != oldMp.Discount__c) {
        fapRefreshIds.add(mpId);
      }
    }
    if (!fapRefreshIds.isEmpty()) {
      PackageBuilderService.refreshFinalAdjustedPriceForPaymentIds(
        fapRefreshIds
      );
    }

    Map<Id, MonthlyPayment__c> lineItemRecalc = new Map<Id, MonthlyPayment__c>();
    Map<Id, MonthlyPayment__c> orderItemRecalc = new Map<Id, MonthlyPayment__c>();
    for (Id mpId : newMap.keySet()) {
      MonthlyPayment__c newMp = newMap.get(mpId);
      MonthlyPayment__c oldMp = oldMap.get(mpId);
      if (aggregatesNeedRecalcForLineItem(newMp, oldMp)) {
        lineItemRecalc.put(mpId, newMp);
      }
      if (aggregatesNeedRecalcForOrderItem(newMp, oldMp)) {
        orderItemRecalc.put(mpId, newMp);
      }
    }

    if (!lineItemRecalc.isEmpty()) {
      MonthlyPaymentService.updateAggregatedPriceAdjustmentForLineItem(
        lineItemRecalc
      );
      MonthlyPaymentService.updateListPriceAggregatedAdjustmentForLineItem(
        lineItemRecalc
      );
    }
    if (!orderItemRecalc.isEmpty()) {
      MonthlyPaymentService.updateAggregatedPriceAdjustmentForOrderItem(
        orderItemRecalc
      );
    }
  }
}
