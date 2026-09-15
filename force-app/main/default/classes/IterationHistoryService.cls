public with sharing class IterationHistoryService {
  public static final String EVENT_CHANGED = 'Changed';
  public static final String EVENT_APPROVED = 'Approved';
  public static final String EVENT_REJECTED = 'Rejected';
  public static final String EVENT_STATUS_CHANGED = 'Status_Changed';
  public static final String EVENT_REVERTED = 'Reverted';
  public static final String EVENT_BULK_APPLIED = 'Bulk_Applied';

  public class HistoryEventRow {
    @AuraEnabled
    public String eventType;
    @AuraEnabled
    public Datetime eventAt;
    @AuraEnabled
    public String actorName;
    @AuraEnabled
    public Decimal sequence;
    @AuraEnabled
    public Id iterationId;
    @AuraEnabled
    public String summary;
    @AuraEnabled
    public String workingDisplay;
    @AuraEnabled
    public String proposedDisplay;
    @AuraEnabled
    public String priorWorkingDisplay;
    @AuraEnabled
    public String priorProposedDisplay;
    @AuraEnabled
    public String priorStatus;
    @AuraEnabled
    public String newStatus;
  }

  public static void recordChanged(
    Iteration__c prior,
    Iteration__c after,
    String summary
  ) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      prior,
      EVENT_CHANGED,
      summary
    );
    copyWorkingSnapshots(evt, after, prior);
    copyProposedSnapshots(evt, after, prior);
    insert evt;
  }

  public static void recordApproved(Iteration__c after) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      null,
      EVENT_APPROVED,
      null
    );
    copyWorkingSnapshots(evt, after, null);
    copyProposedSnapshots(evt, after, null);
    insert evt;
  }

  public static void recordRejected(Iteration__c prior, Iteration__c after) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      prior,
      EVENT_REJECTED,
      null
    );
    copyWorkingSnapshots(evt, after, null);
    copyProposedSnapshots(evt, after, prior);
    insert evt;
  }

  public static void recordReverted(Iteration__c prior, Iteration__c after) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      prior,
      EVENT_REVERTED,
      null
    );
    copyWorkingSnapshots(evt, after, null);
    copyProposedSnapshots(evt, after, null);
    insert evt;
  }

  public static void recordStatusChanged(
    Iteration__c prior,
    Iteration__c after,
    String summary
  ) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      prior,
      EVENT_STATUS_CHANGED,
      summary
    );
    evt.Prior_Status__c = prior != null ? prior.Status__c : null;
    evt.New_Status__c = after != null ? after.Status__c : null;
    insert evt;
  }

  public static void recordBulkApplied(Iteration__c after, String summary) {
    Iteration_History_Event__c evt = buildEvent(
      after,
      null,
      EVENT_BULK_APPLIED,
      summary
    );
    copyWorkingSnapshots(evt, after, null);
    copyProposedSnapshots(evt, after, null);
    insert evt;
  }

  @AuraEnabled(cacheable=false)
  public static List<HistoryEventRow> getEventsForIteration(Id iterationId) {
    if (iterationId == null) {
      return new List<HistoryEventRow>();
    }
    return getEventsForIterations(new List<Id>{ iterationId });
  }

  @AuraEnabled(cacheable=false)
  public static List<HistoryEventRow> getEventsForIterations(
    List<Id> iterationIds
  ) {
    List<HistoryEventRow> rows = new List<HistoryEventRow>();
    if (iterationIds == null || iterationIds.isEmpty()) {
      return rows;
    }
    Set<Id> idSet = new Set<Id>();
    for (Id iterationId : iterationIds) {
      if (iterationId != null) {
        idSet.add(iterationId);
      }
    }
    if (idSet.isEmpty()) {
      return rows;
    }
    for (Iteration_History_Event__c evt : [
      SELECT
        Iteration__c,
        Event_Type__c,
        Event_At__c,
        Actor__r.Name,
        Sequence__c,
        Summary__c,
        Working_Increase_Type__c,
        Working_Increase_Percent__c,
        Working_Increase_Amount__c,
        Working_Final_Price__c,
        Prior_Working_Increase_Type__c,
        Prior_Working_Increase_Percent__c,
        Prior_Working_Increase_Amount__c,
        Prior_Working_Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c,
        Prior_Proposed_Increase_Type__c,
        Prior_Proposed_Increase_Percent__c,
        Prior_Proposed_Increase_Amount__c,
        Prior_Proposed_Final_Price__c,
        Prior_Status__c,
        New_Status__c
      FROM Iteration_History_Event__c
      WHERE Iteration__c IN :idSet
      ORDER BY Sequence__c ASC, Event_At__c DESC, CreatedDate DESC
      LIMIT 500
    ]) {
      rows.add(toHistoryEventRow(evt));
    }
    return rows;
  }

  private static HistoryEventRow toHistoryEventRow(
    Iteration_History_Event__c evt
  ) {
    HistoryEventRow row = new HistoryEventRow();
    row.iterationId = evt.Iteration__c;
    row.eventType = evt.Event_Type__c;
    row.eventAt = evt.Event_At__c;
    row.actorName = evt.Actor__r != null ? evt.Actor__r.Name : null;
    row.sequence = evt.Sequence__c;
    row.summary = evt.Summary__c;
    row.workingDisplay = formatCommercialDisplay(
      evt.Working_Increase_Type__c,
      evt.Working_Increase_Percent__c,
      evt.Working_Increase_Amount__c,
      evt.Working_Final_Price__c
    );
    row.proposedDisplay = formatCommercialDisplay(
      evt.Proposed_Increase_Type__c,
      evt.Proposed_Increase_Percent__c,
      evt.Proposed_Increase_Amount__c,
      evt.Proposed_Final_Price__c
    );
    row.priorWorkingDisplay = formatCommercialDisplay(
      evt.Prior_Working_Increase_Type__c,
      evt.Prior_Working_Increase_Percent__c,
      evt.Prior_Working_Increase_Amount__c,
      evt.Prior_Working_Final_Price__c
    );
    row.priorProposedDisplay = formatCommercialDisplay(
      evt.Prior_Proposed_Increase_Type__c,
      evt.Prior_Proposed_Increase_Percent__c,
      evt.Prior_Proposed_Increase_Amount__c,
      evt.Prior_Proposed_Final_Price__c
    );
    row.priorStatus = evt.Prior_Status__c;
    row.newStatus = evt.New_Status__c;
    return row;
  }

  private static Iteration_History_Event__c buildEvent(
    Iteration__c after,
    Iteration__c prior,
    String eventType,
    String summary
  ) {
    Id iterationId = after != null ? after.Id : prior?.Id;
    if (iterationId == null) {
      throw new AuraHandledException(
        'Iteration is required to record history.'
      );
    }
    Iteration_History_Event__c evt = new Iteration_History_Event__c();
    evt.Iteration__c = iterationId;
    evt.Event_Type__c = eventType;
    evt.Actor__c = UserInfo.getUserId();
    evt.Event_At__c = Datetime.now();
    evt.Sequence__c = resolveSequence(after, prior);
    evt.Summary__c = summary;
    return evt;
  }

  private static Decimal resolveSequence(
    Iteration__c after,
    Iteration__c prior
  ) {
    if (after != null) {
      Object afterSeq = after.get('Sequence__c');
      if (afterSeq != null) {
        return (Decimal) afterSeq;
      }
    }
    if (prior != null) {
      Object priorSeq = prior.get('Sequence__c');
      if (priorSeq != null) {
        return (Decimal) priorSeq;
      }
    }
    return null;
  }

  private static void copyWorkingSnapshots(
    Iteration_History_Event__c evt,
    Iteration__c after,
    Iteration__c prior
  ) {
    copyWorkingFromIteration(evt, after, false);
    copyWorkingFromIteration(evt, prior, true);
  }

  private static void copyProposedSnapshots(
    Iteration_History_Event__c evt,
    Iteration__c after,
    Iteration__c prior
  ) {
    copyProposedFromIteration(evt, after, false);
    copyProposedFromIteration(evt, prior, true);
  }

  private static void copyWorkingFromIteration(
    Iteration_History_Event__c evt,
    Iteration__c row,
    Boolean isPrior
  ) {
    if (row == null) {
      return;
    }
    if (isPrior) {
      evt.Prior_Working_Increase_Type__c = normalizeType(row.Increase_Type__c);
      evt.Prior_Working_Increase_Percent__c = row.Increase_Percent__c;
      evt.Prior_Working_Increase_Amount__c = row.Increase_Amount__c;
      evt.Prior_Working_Final_Price__c = row.Final_Price__c;
    } else {
      evt.Working_Increase_Type__c = normalizeType(row.Increase_Type__c);
      evt.Working_Increase_Percent__c = row.Increase_Percent__c;
      evt.Working_Increase_Amount__c = row.Increase_Amount__c;
      evt.Working_Final_Price__c = row.Final_Price__c;
    }
  }

  private static void copyProposedFromIteration(
    Iteration_History_Event__c evt,
    Iteration__c row,
    Boolean isPrior
  ) {
    if (row == null) {
      return;
    }
    if (isPrior) {
      evt.Prior_Proposed_Increase_Type__c = normalizeType(
        row.Proposed_Increase_Type__c
      );
      evt.Prior_Proposed_Increase_Percent__c = row.Proposed_Increase_Percent__c;
      evt.Prior_Proposed_Increase_Amount__c = row.Proposed_Increase_Amount__c;
      evt.Prior_Proposed_Final_Price__c = row.Proposed_Final_Price__c;
    } else {
      evt.Proposed_Increase_Type__c = normalizeType(
        row.Proposed_Increase_Type__c
      );
      evt.Proposed_Increase_Percent__c = row.Proposed_Increase_Percent__c;
      evt.Proposed_Increase_Amount__c = row.Proposed_Increase_Amount__c;
      evt.Proposed_Final_Price__c = row.Proposed_Final_Price__c;
    }
  }

  private static String normalizeType(String raw) {
    return IterationService.normalizeIncreaseType(raw);
  }

  private static String formatCommercialDisplay(
    String type,
    Decimal percent,
    Decimal amount,
    Decimal finalPrice
  ) {
    String normalized = normalizeType(type);
    if (String.isBlank(normalized)) {
      return '';
    }
    String label = increaseTypeLabel(normalized);
    String valuePart;
    if (normalized == IterationService.TYPE_PERCENT) {
      valuePart = formatPercentValue(percent);
    } else if (normalized == IterationService.TYPE_VALUE) {
      valuePart = formatNumberValue(amount);
    } else if (normalized == IterationService.TYPE_FINAL) {
      valuePart = formatNumberValue(finalPrice);
    } else {
      valuePart = null;
    }
    if (String.isBlank(valuePart)) {
      return label;
    }
    return label + ' · ' + valuePart;
  }

  private static String increaseTypeLabel(String apiValue) {
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

  private static String formatPercentValue(Decimal value) {
    if (value == null) {
      return null;
    }
    Decimal display = value.abs() <= 1 ? value * 100 : value;
    return display.stripTrailingZeros().toPlainString() + '%';
  }

  private static String formatNumberValue(Decimal value) {
    if (value == null) {
      return null;
    }
    return value.stripTrailingZeros().toPlainString();
  }
}
