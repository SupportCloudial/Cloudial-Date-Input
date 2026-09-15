/**
 * Aura/LWC facade for Contract/Opportunity Package Builder recurring price-increase modal.
 */
public with sharing class RecurringPriceIncreaseController {
  public class LoadResult {
    @AuraEnabled
    public List<Id> eligibleLineIds;
    @AuraEnabled
    public String excludedMessage;
    @AuraEnabled
    public Boolean archivedBlocked;
    @AuraEnabled
    public Date minStartDate;
    @AuraEnabled
    public Integer frequencyMonths;
    @AuraEnabled
    public Date startDate;
    @AuraEnabled
    public String increaseType;
    @AuraEnabled
    public Decimal increasePercent;
    @AuraEnabled
    public Decimal increaseAmount;
    @AuraEnabled
    public Boolean anyRuleEnabled;
    @AuraEnabled
    public Integer eligibleCount;
  }

  @AuraEnabled
  public static LoadResult loadContext(List<Id> lineIds, Boolean isArchived) {
    LoadResult result = new LoadResult();
    result.eligibleLineIds = new List<Id>();
    result.excludedMessage = '';
    result.archivedBlocked = false;
    result.anyRuleEnabled = false;
    result.eligibleCount = 0;
    result.minStartDate = Date.today();

    if (lineIds == null || lineIds.isEmpty()) {
      throw new AuraHandledException('Select at least one product.');
    }
    if (isArchived == true) {
      result.archivedBlocked = true;
      result.excludedMessage = 'Recurring price increase cannot be edited on archived orders.';
      return result;
    }

    List<String> excluded = new List<String>();
    Date minStart = Date.today();
    Boolean firstEligible = true;
    Integer enabledCount = 0;
    Integer freq = null;
    Date startDt = null;
    String increaseType = null;
    Decimal increasePercent = null;
    Decimal increaseAmount = null;
    Boolean ruleFieldsConsistent = true;

    Set<Id> orderItemIds = new Set<Id>();
    Set<Id> oliIds = new Set<Id>();
    for (Id lineId : lineIds) {
      if (lineId == null) {
        continue;
      }
      if (lineId.getSObjectType() == OrderItem.SObjectType) {
        orderItemIds.add(lineId);
      } else if (lineId.getSObjectType() == OpportunityLineItem.SObjectType) {
        oliIds.add(lineId);
      }
    }

    if (!orderItemIds.isEmpty()) {
      for (OrderItem oi : [
        SELECT
          Id,
          Access_Type__c,
          Product2.Name,
          Recurring_Price_Increase_Enabled__c,
          Recurring_Increase_Frequency_Months__c,
          Recurring_Increase_Start_Date__c,
          Recurring_Increase_Type__c,
          Recurring_Increase_Percent__c,
          Recurring_Increase_Amount__c,
          Order.Order_Start_Date__c,
          Order.EffectiveDate,
          Order.Contract.StartDate
        FROM OrderItem
        WHERE Id IN :orderItemIds
      ]) {
        if (
          !RecurringPriceIncreaseService.isEligibleAccessType(oi.Access_Type__c)
        ) {
          excluded.add(
            String.isBlank(oi.Product2?.Name)
              ? String.valueOf(oi.Id)
              : oi.Product2.Name
          );
          continue;
        }
        result.eligibleLineIds.add(oi.Id);
        Date contractStart = orderContractStart(oi);
        minStart = RecurringPriceIncreaseService.maxDate(
          minStart,
          contractStart
        );

        Boolean enabled = oi.Recurring_Price_Increase_Enabled__c == true;
        if (enabled) {
          enabledCount++;
        }
        if (firstEligible) {
          freq = oi.Recurring_Increase_Frequency_Months__c == null
            ? null
            : oi.Recurring_Increase_Frequency_Months__c.intValue();
          startDt = oi.Recurring_Increase_Start_Date__c;
          increaseType = oi.Recurring_Increase_Type__c;
          increasePercent = oi.Recurring_Increase_Percent__c;
          increaseAmount = oi.Recurring_Increase_Amount__c;
          firstEligible = false;
        } else if (
          !ruleFieldsEqual(
            freq,
            startDt,
            increaseType,
            increasePercent,
            increaseAmount,
            oi
          )
        ) {
          ruleFieldsConsistent = false;
        }
      }
    }

    if (!oliIds.isEmpty()) {
      for (OpportunityLineItem oli : [
        SELECT
          Id,
          Access_Type__c,
          Product2.Name,
          Recurring_Price_Increase_Enabled__c,
          Recurring_Increase_Frequency_Months__c,
          Recurring_Increase_Start_Date__c,
          Recurring_Increase_Type__c,
          Recurring_Increase_Percent__c,
          Recurring_Increase_Amount__c,
          Opportunity.Start_Date__c
        FROM OpportunityLineItem
        WHERE Id IN :oliIds
      ]) {
        if (
          !RecurringPriceIncreaseService.isEligibleAccessType(
            oli.Access_Type__c
          )
        ) {
          excluded.add(
            String.isBlank(oli.Product2?.Name)
              ? String.valueOf(oli.Id)
              : oli.Product2.Name
          );
          continue;
        }
        result.eligibleLineIds.add(oli.Id);
        Date oppStart = oli.Opportunity != null
          ? oli.Opportunity.Start_Date__c
          : null;
        minStart = RecurringPriceIncreaseService.maxDate(minStart, oppStart);

        Boolean enabled = oli.Recurring_Price_Increase_Enabled__c == true;
        if (enabled) {
          enabledCount++;
        }
        if (firstEligible) {
          freq = oli.Recurring_Increase_Frequency_Months__c == null
            ? null
            : oli.Recurring_Increase_Frequency_Months__c.intValue();
          startDt = oli.Recurring_Increase_Start_Date__c;
          increaseType = oli.Recurring_Increase_Type__c;
          increasePercent = oli.Recurring_Increase_Percent__c;
          increaseAmount = oli.Recurring_Increase_Amount__c;
          firstEligible = false;
        } else if (
          !ruleFieldsEqualOli(
            freq,
            startDt,
            increaseType,
            increasePercent,
            increaseAmount,
            oli
          )
        ) {
          ruleFieldsConsistent = false;
        }
      }
    }

    result.eligibleCount = result.eligibleLineIds.size();
    result.anyRuleEnabled = enabledCount > 0;
    result.minStartDate = minStart;
    if (!excluded.isEmpty()) {
      result.excludedMessage =
        'Skipped (not Monthly/Periodic): ' + String.join(excluded, ', ');
    }
    if (ruleFieldsConsistent && !firstEligible) {
      result.frequencyMonths = freq;
      result.startDate = startDt;
      result.increaseType = increaseType;
      result.increasePercent = increasePercent;
      result.increaseAmount = increaseAmount;
    }
    return result;
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.OverlapPreviewResult previewOverlap(
    List<Id> lineIds,
    String draftJson
  ) {
    return RecurringPriceIncreaseService.previewIterationOverlap(
      lineIds,
      parseDraft(draftJson)
    );
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult saveRuleFields(
    List<Id> lineIds,
    String draftJson,
    Boolean isArchived
  ) {
    return RecurringPriceIncreaseService.saveRuleFields(
      lineIds,
      parseDraft(draftJson),
      isArchived
    );
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult enableRules(
    List<Id> lineIds,
    String draftJson,
    Boolean isArchived
  ) {
    return RecurringPriceIncreaseService.enableRules(
      lineIds,
      parseDraft(draftJson),
      isArchived
    );
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult enableAndApplyRules(
    List<Id> lineIds,
    String draftJson,
    Boolean isArchived,
    Boolean confirmOverlap
  ) {
    return RecurringPriceIncreaseService.enableAndApplyRules(
      lineIds,
      parseDraft(draftJson),
      isArchived,
      confirmOverlap == true
    );
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult saveRules(
    List<Id> lineIds,
    String draftJson,
    Boolean isArchived,
    Boolean confirmOverlap
  ) {
    return enableAndApplyRules(lineIds, draftJson, isArchived, confirmOverlap);
  }

  @TestVisible
  private static RecurringPriceIncreaseService.RuleDraft parseDraft(
    String draftJson
  ) {
    if (String.isBlank(draftJson)) {
      throw new AuraHandledException(
        'A recurring price increase rule is required.'
      );
    }
    RecurringPriceIncreaseService.RuleDraft draft;
    try {
      draft = (RecurringPriceIncreaseService.RuleDraft) JSON.deserialize(
        draftJson,
        RecurringPriceIncreaseService.RuleDraft.class
      );
    } catch (Exception e) {
      throw new AuraHandledException(
        'Invalid recurring price increase rule payload.'
      );
    }
    if (draft == null) {
      throw new AuraHandledException(
        'A recurring price increase rule is required.'
      );
    }
    // JSON may deserialize whole numbers as Decimal into Integer field as null
    // on some API paths; recover from a raw map when needed.
    if (draft.frequencyMonths == null) {
      Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
        draftJson
      );
      Object freqRaw = raw != null ? raw.get('frequencyMonths') : null;
      if (freqRaw != null) {
        draft.frequencyMonths = Integer.valueOf(String.valueOf(freqRaw));
      }
    }
    if (draft.startDate == null) {
      Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
        draftJson
      );
      Object startRaw = raw != null ? raw.get('startDate') : null;
      if (startRaw != null && String.valueOf(startRaw).trim() != '') {
        draft.startDate = Date.valueOf(String.valueOf(startRaw).trim());
      }
    }
    return draft;
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult disableRules(
    List<Id> lineIds,
    Boolean isArchived
  ) {
    return RecurringPriceIncreaseService.disableRules(lineIds, isArchived);
  }

  @AuraEnabled
  public static RecurringPriceIncreaseService.SaveResult removeRules(
    List<Id> lineIds,
    Boolean isArchived
  ) {
    return RecurringPriceIncreaseService.removeRules(lineIds, isArchived);
  }

  private static Date orderContractStart(OrderItem oi) {
    if (oi == null || oi.Order == null) {
      return null;
    }
    if (oi.Order.Order_Start_Date__c != null) {
      return oi.Order.Order_Start_Date__c;
    }
    if (oi.Order.Contract != null && oi.Order.Contract.StartDate != null) {
      return oi.Order.Contract.StartDate;
    }
    return oi.Order.EffectiveDate;
  }

  private static Boolean ruleFieldsEqual(
    Integer freq,
    Date startDt,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    OrderItem oi
  ) {
    Integer oiFreq = oi.Recurring_Increase_Frequency_Months__c == null
      ? null
      : oi.Recurring_Increase_Frequency_Months__c.intValue();
    return freq == oiFreq &&
      startDt == oi.Recurring_Increase_Start_Date__c &&
      increaseType == oi.Recurring_Increase_Type__c &&
      increasePercent == oi.Recurring_Increase_Percent__c &&
      increaseAmount == oi.Recurring_Increase_Amount__c;
  }

  private static Boolean ruleFieldsEqualOli(
    Integer freq,
    Date startDt,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    OpportunityLineItem oli
  ) {
    Integer oliFreq = oli.Recurring_Increase_Frequency_Months__c == null
      ? null
      : oli.Recurring_Increase_Frequency_Months__c.intValue();
    return freq == oliFreq &&
      startDt == oli.Recurring_Increase_Start_Date__c &&
      increaseType == oli.Recurring_Increase_Type__c &&
      increasePercent == oli.Recurring_Increase_Percent__c &&
      increaseAmount == oli.Recurring_Increase_Amount__c;
  }
}
