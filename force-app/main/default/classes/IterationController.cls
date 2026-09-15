public with sharing class IterationController {
  private static final Map<String, String> HISTORY_FIELD_LABELS = new Map<String, String>{
    'Owner' => 'Owner',
    'OwnerId' => 'Owner',
    'created' => 'Created',
    'Name' => 'Name',
    'Sequence__c' => 'Sequence',
    'Duration_Months__c' => 'Duration (months)',
    'Advance_Notice_Days__c' => 'Advance Notice (days)',
    'Notice_Date__c' => 'Notice Date',
    'Period_Start_Date__c' => 'Period Start',
    'Period_End_Date__c' => 'Period End',
    'Increase_Type__c' => 'Price Increase Type',
    'Increase_Percent__c' => 'Price Increase Percent',
    'Increase_Amount__c' => 'Price Increase Amount',
    'Final_Price__c' => 'Price Increase Final Price',
    'Proposed_Increase_Type__c' => 'Proposed Type',
    'Proposed_Increase_Percent__c' => 'Proposed Percent',
    'Proposed_Increase_Amount__c' => 'Proposed Amount',
    'Proposed_Final_Price__c' => 'Proposed Final Price',
    'Original_Increase_Type__c' => 'Original Type',
    'Original_Increase_Percent__c' => 'Original Percent',
    'Original_Increase_Amount__c' => 'Original Amount',
    'Original_Final_Price__c' => 'Original Final Price',
    'Status__c' => 'Status',
    'Prior_Status__c' => 'Prior Status',
    'Opportunity_Product__c' => 'Opportunity Product',
    'Order_Product__c' => 'Order Product'
  };

  private static final Set<String> INCREASE_TYPE_HISTORY_FIELDS = new Set<String>{
    'Increase_Type__c',
    'Proposed_Increase_Type__c',
    'Original_Increase_Type__c'
  };

  private static final Set<String> PERCENT_HISTORY_FIELDS = new Set<String>{
    'Increase_Percent__c',
    'Proposed_Increase_Percent__c',
    'Original_Increase_Percent__c'
  };
  public class LoadResult {
    @AuraEnabled
    public List<IterationService.ScreenRow> rows;
    @AuraEnabled
    public String excludedMessage;
    @AuraEnabled
    public Boolean archivedBlocked;
  }

  public class HistoryRow {
    @AuraEnabled
    public String fieldLabel;
    @AuraEnabled
    public String oldValue;
    @AuraEnabled
    public String newValue;
    @AuraEnabled
    public String createdByName;
    @AuraEnabled
    public Datetime createdDate;
  }

  @AuraEnabled
  public static LoadResult loadIterations(
    List<Id> lineIds,
    String context,
    Boolean isArchived
  ) {
    if (lineIds == null || lineIds.isEmpty()) {
      throw new AuraHandledException('Select at least one product.');
    }
    if (isArchived == true) {
      LoadResult blocked = new LoadResult();
      blocked.archivedBlocked = true;
      blocked.excludedMessage = 'Iterations cannot be edited on archived orders.';
      blocked.rows = new List<IterationService.ScreenRow>();
      return blocked;
    }
    LoadResult result = new LoadResult();
    result.archivedBlocked = false;
    result.rows = new List<IterationService.ScreenRow>();
    List<String> excluded = new List<String>();
    Boolean isOpp = context == 'Opportunity';

    if (isOpp) {
      List<OpportunityLineItem> items = [
        SELECT
          Id,
          Product2.Name,
          Product2.ProductCode,
          Entry_Date__c,
          End_date__c,
          Access_Type__c,
          Remaining_Iterations__c
        FROM OpportunityLineItem
        WHERE Id IN :lineIds
      ];
      Set<Id> periodicIds = new Set<Id>();
      for (OpportunityLineItem item : items) {
        if (!IterationService.isPeriodic(item.Access_Type__c)) {
          excluded.add(item.Product2?.Name);
          continue;
        }
        periodicIds.add(item.Id);
      }
      Map<Id, List<Iteration__c>> byParent = IterationService.groupByParent(
        IterationService.queryByParent(periodicIds)
      );
      for (OpportunityLineItem item : items) {
        if (!periodicIds.contains(item.Id)) {
          continue;
        }
        List<Iteration__c> plan = byParent.get(item.Id);
        result.rows.add(
          toRow(
            item.Id,
            item.Product2?.Name,
            item.Product2?.ProductCode,
            item.Entry_Date__c,
            item.End_date__c,
            item.Access_Type__c,
            plan == null ? new List<Iteration__c>() : plan,
            item.Remaining_Iterations__c
          )
        );
      }
    } else {
      List<OrderItem> items = [
        SELECT
          Id,
          Product2.Name,
          Product2.ProductCode,
          ServiceDate,
          EndDate,
          Access_Type__c,
          Remaining_Iterations__c
        FROM OrderItem
        WHERE Id IN :lineIds
      ];
      Set<Id> periodicIds = new Set<Id>();
      for (OrderItem item : items) {
        if (!IterationService.isPeriodic(item.Access_Type__c)) {
          excluded.add(item.Product2?.Name);
          continue;
        }
        periodicIds.add(item.Id);
      }
      Map<Id, List<Iteration__c>> byParent = IterationService.groupByParent(
        IterationService.queryByParent(periodicIds)
      );
      for (OrderItem item : items) {
        if (!periodicIds.contains(item.Id)) {
          continue;
        }
        List<Iteration__c> plan = byParent.get(item.Id);
        result.rows.add(
          toRow(
            item.Id,
            item.Product2?.Name,
            item.Product2?.ProductCode,
            item.ServiceDate,
            item.EndDate,
            item.Access_Type__c,
            plan == null ? new List<Iteration__c>() : plan,
            item.Remaining_Iterations__c
          )
        );
      }
    }
    if (!excluded.isEmpty()) {
      result.excludedMessage =
        'Iterations are Periodic only. Skipped: ' + String.join(excluded, ', ');
    }
    return result;
  }

  @AuraEnabled
  public static IterationService.SaveResult saveIterations(
    Id lineId,
    Date lineEndDate,
    List<Iteration__c> iterations
  ) {
    return IterationService.savePlan(lineId, lineEndDate, iterations);
  }

  @AuraEnabled
  public static IterationService.DeleteResult deleteIterations(
    List<IterationService.DeleteIterationRequest> specs
  ) {
    return IterationService.deleteIterations(specs);
  }

  @AuraEnabled
  public static IterationService.BulkApplyResult bulkApply(
    List<Id> lineIds,
    Map<Id, Date> endDates,
    Iteration__c template,
    Map<Id, List<Id>> iterationIdsByLine
  ) {
    return IterationService.bulkApplyTemplate(
      lineIds,
      endDates,
      template,
      iterationIdsByLine
    );
  }

  @AuraEnabled
  public static IterationService.ApproveResult approveIteration(
    List<Id> iterationIds
  ) {
    return IterationService.approveIterations(iterationIds);
  }

  @AuraEnabled
  public static IterationService.ActionResult rejectProposed(
    List<Id> iterationIds
  ) {
    return IterationService.rejectProposedIterations(iterationIds);
  }

  @AuraEnabled
  public static IterationService.ActionResult discardProposed(
    List<Id> iterationIds
  ) {
    return IterationService.rejectProposedIterations(iterationIds);
  }

  @AuraEnabled
  public static IterationService.ActionResult saveProposed(
    List<Id> iterationIds,
    Iteration__c proposed
  ) {
    return IterationService.saveProposedIterations(iterationIds, proposed);
  }

  @AuraEnabled(cacheable=false)
  public static List<IterationHistoryService.HistoryEventRow> getHistoryEvents(
    Id iterationId
  ) {
    return IterationHistoryService.getEventsForIteration(iterationId);
  }

  @AuraEnabled(cacheable=false)
  public static List<IterationHistoryService.HistoryEventRow> getHistoryEventsForIterations(
    List<Id> iterationIds
  ) {
    return IterationHistoryService.getEventsForIterations(iterationIds);
  }

  @AuraEnabled
  public static void revertWorkingToOriginal(Id iterationId) {
    IterationService.revertWorkingToOriginal(iterationId);
  }

  @AuraEnabled(cacheable=false)
  public static List<HistoryRow> getFieldHistory(Id iterationId) {
    if (iterationId == null) {
      throw new AuraHandledException('Select one iteration to view history.');
    }
    List<HistoryRow> rows = new List<HistoryRow>();
    for (Iteration__History h : [
      SELECT Field, OldValue, NewValue, CreatedBy.Name, CreatedDate
      FROM Iteration__History
      WHERE ParentId = :iterationId
      ORDER BY CreatedDate DESC
      LIMIT 200
    ]) {
      HistoryRow row = new HistoryRow();
      row.fieldLabel = historyFieldLabel(h.Field);
      row.oldValue = formatHistoryValue(h.Field, h.OldValue);
      row.newValue = formatHistoryValue(h.Field, h.NewValue);
      row.createdByName = h.CreatedBy != null ? h.CreatedBy.Name : null;
      row.createdDate = h.CreatedDate;
      rows.add(row);
    }
    return rows;
  }

  private static String historyFieldLabel(String fieldApi) {
    if (String.isBlank(fieldApi)) {
      return fieldApi;
    }
    if (HISTORY_FIELD_LABELS.containsKey(fieldApi)) {
      return HISTORY_FIELD_LABELS.get(fieldApi);
    }
    return fieldApi.replace('__c', '').replace('_', ' ');
  }

  private static String formatHistoryValue(String fieldApi, Object rawValue) {
    if (rawValue == null) {
      return null;
    }
    String text = String.valueOf(rawValue);
    if (INCREASE_TYPE_HISTORY_FIELDS.contains(fieldApi)) {
      return IterationService.normalizeIncreaseType(text) == null
        ? ''
        : increaseTypeHistoryLabel(
            IterationService.normalizeIncreaseType(text)
          );
    }
    if (PERCENT_HISTORY_FIELDS.contains(fieldApi)) {
      return formatPercentHistoryValue(rawValue);
    }
    return text;
  }

  @TestVisible
  private static String formatPercentHistoryValue(Object rawValue) {
    Decimal value;
    if (rawValue instanceof Decimal) {
      value = (Decimal) rawValue;
    } else {
      try {
        value = Decimal.valueOf(String.valueOf(rawValue));
      } catch (Exception e) {
        return String.valueOf(rawValue);
      }
    }
    Decimal display = value.abs() <= 1 ? value * 100 : value;
    return display.stripTrailingZeros().toPlainString() + '%';
  }

  private static String increaseTypeHistoryLabel(String apiValue) {
    if (String.isBlank(apiValue)) {
      return '';
    }
    if (apiValue == IterationService.TYPE_PERCENT) {
      return 'Increase by Percentage';
    }
    if (apiValue == IterationService.TYPE_VALUE) {
      return 'Increase by Value';
    }
    if (apiValue == IterationService.TYPE_FINAL) {
      return 'Final Price';
    }
    return apiValue.replace('_', ' ');
  }

  private static IterationService.ScreenRow toRow(
    Id lineId,
    String name,
    String code,
    Date startDate,
    Date endDate,
    String accessType,
    List<Iteration__c> iterations,
    Decimal remaining
  ) {
    IterationService.ScreenRow row = new IterationService.ScreenRow();
    row.lineId = lineId;
    row.productName = name;
    row.productCode = code;
    row.startDate = startDate;
    row.endDate = endDate;
    row.accessType = accessType;
    row.iterations = iterations == null ? new List<Iteration__c>() : iterations;
    row.configuredCount = row.iterations.size();
    row.remaining = remaining == null
      ? IterationService.countRemaining(row.iterations)
      : Integer.valueOf(remaining);
    return row;
  }
}
