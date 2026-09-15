public with sharing class IterationService {
  public static final String STATUS_PLANNED = 'Planned';
  public static final String STATUS_ORIGINAL = 'Original';
  public static final String STATUS_PROPOSED = 'Proposed';
  public static final String STATUS_APPROVED = 'Approved';
  public static final String STATUS_COMPLETED = 'Completed';
  public static final String STATUS_INACTIVE = 'Inactive';
  public static final String STATUS_NEGOTIATION = 'Negotiation';
  public static final String STATUS_ON_HOLD = 'On Hold';
  public static final String STATUS_REJECTED = 'Rejected';
  public static final String ACCESS_PERIODIC = 'Periodic';

  public static final String TYPE_PERCENT = 'Increase_by_Percentage';
  public static final String TYPE_VALUE = 'Increase_by_Value';
  public static final String TYPE_FINAL = 'Final_Price';

  public class SaveResult {
    @AuraEnabled
    public Boolean noticeAlreadyDue;
    @AuraEnabled
    public Integer remaining;
    @AuraEnabled
    public List<Iteration__c> iterations;
  }

  public class BulkApplyResult {
    @AuraEnabled
    public Integer updatedRows;
    @AuraEnabled
    public Integer skippedCompletedRows;
    @AuraEnabled
    public Integer updatedProducts;
    @AuraEnabled
    public String message;
  }

  public class ApproveResult {
    @AuraEnabled
    public Integer approvedCount;
    @AuraEnabled
    public Integer skippedNoProposed;
    @AuraEnabled
    public String message;
  }

  public class ActionResult {
    @AuraEnabled
    public Integer processedCount;
    @AuraEnabled
    public Integer skippedCount;
    @AuraEnabled
    public String message;
  }

  public class DeleteIterationRequest {
    @AuraEnabled
    public Id lineId;
    @AuraEnabled
    public Date lineEndDate;
    @AuraEnabled
    public Id iterationId;
  }

  public class DeleteResult {
    @AuraEnabled
    public Boolean noticeAlreadyDue;
  }

  public class ScreenRow {
    @AuraEnabled
    public Id lineId;
    @AuraEnabled
    public String productName;
    @AuraEnabled
    public String productCode;
    @AuraEnabled
    public Date startDate;
    @AuraEnabled
    public Date endDate;
    @AuraEnabled
    public String accessType;
    @AuraEnabled
    public Integer configuredCount;
    @AuraEnabled
    public Integer remaining;
    @AuraEnabled
    public List<Iteration__c> iterations;
  }

  public static Boolean isPeriodic(String accessType) {
    return accessType == ACCESS_PERIODIC;
  }

  public static List<Iteration__c> queryByParent(Set<Id> parentIds) {
    if (parentIds == null || parentIds.isEmpty()) {
      return new List<Iteration__c>();
    }
    return [
      SELECT
        Id,
        Name,
        Order_Product__c,
        Opportunity_Product__c,
        Sequence__c,
        Duration_Months__c,
        Advance_Notice_Days__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Status__c,
        Prior_Status__c,
        Notice_Date__c,
        Period_Start_Date__c,
        Period_End_Date__c,
        Original_Increase_Type__c,
        Original_Increase_Percent__c,
        Original_Increase_Amount__c,
        Original_Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c,
        Negotiation_Owner__c
      FROM Iteration__c
      WHERE
        (Order_Product__c IN :parentIds
        OR Opportunity_Product__c IN :parentIds)
        AND Status__c != :STATUS_INACTIVE
      ORDER BY Sequence__c ASC, CreatedDate ASC
    ];
  }

  /** Includes Inactive rows (e.g. restore after replacement delete). */
  public static List<Iteration__c> queryByParentIncludingInactive(
    Set<Id> parentIds
  ) {
    if (parentIds == null || parentIds.isEmpty()) {
      return new List<Iteration__c>();
    }
    return [
      SELECT
        Id,
        Name,
        Order_Product__c,
        Opportunity_Product__c,
        Sequence__c,
        Duration_Months__c,
        Advance_Notice_Days__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Status__c,
        Prior_Status__c,
        Notice_Date__c,
        Period_Start_Date__c,
        Period_End_Date__c,
        Original_Increase_Type__c,
        Original_Increase_Percent__c,
        Original_Increase_Amount__c,
        Original_Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c
      FROM Iteration__c
      WHERE
        Order_Product__c IN :parentIds
        OR Opportunity_Product__c IN :parentIds
      ORDER BY Sequence__c ASC, CreatedDate ASC
    ];
  }

  public static SaveResult savePlan(
    Id parentId,
    Date lineEndDate,
    List<Iteration__c> rows
  ) {
    return savePlan(parentId, lineEndDate, rows, null);
  }

  public static SaveResult savePlan(
    Id parentId,
    Date lineEndDate,
    List<Iteration__c> rows,
    String bulkSummary
  ) {
    if (parentId == null) {
      throw new AuraHandledException('A product line is required.');
    }
    Boolean isOrderItem = parentId.getSObjectType() == OrderItem.SObjectType;
    List<Iteration__c> existing = queryByParent(new Set<Id>{ parentId });
    Map<Id, Iteration__c> existingById = new Map<Id, Iteration__c>(existing);
    Map<Id, Iteration__c> priorSnapshots = snapshotById(existing);

    List<Iteration__c> toUpsert = new List<Iteration__c>();
    Set<Id> keepIds = new Set<Id>();
    Integer seq = 1;
    if (rows == null) {
      rows = new List<Iteration__c>();
    }
    for (Iteration__c row : rows) {
      Iteration__c rec = row.clone(false, true, false, false);
      if (row.Id != null && existingById.containsKey(row.Id)) {
        if (existingById.get(row.Id).Status__c == STATUS_COMPLETED) {
          keepIds.add(row.Id);
          // Keep the Completed row's place in the plan order so later rows
          // do not reuse its Sequence__c (which breaks propose/approve fan-out).
          seq++;
          continue;
        }
        rec.Id = row.Id;
      }
      rec.Sequence__c = seq;
      if (isOrderItem) {
        rec.Order_Product__c = parentId;
        rec.Opportunity_Product__c = null;
      } else {
        rec.Opportunity_Product__c = parentId;
        rec.Order_Product__c = null;
      }
      Iteration__c existingRow = row.Id != null &&
        existingById.containsKey(row.Id)
        ? existingById.get(row.Id)
        : null;
      if (String.isBlank(rec.Status__c)) {
        rec.Status__c = existingRow == null
          ? STATUS_ORIGINAL
          : existingRow.Status__c;
      }
      normalizeIncreaseTypes(rec);
      if (existingRow == null) {
        seedOriginalIfBlank(rec);
      }
      stampNegotiationOwner(rec);
      if (
        existingRow == null || !workingCommercialFieldsEqual(rec, existingRow)
      ) {
        validateCommercialFields(rec);
      }
      toUpsert.add(rec);
      if (rec.Id != null) {
        keepIds.add(rec.Id);
      }
      seq++;
    }

    List<Iteration__c> toDelete = new List<Iteration__c>();
    for (Iteration__c prior : existing) {
      if (prior.Status__c == STATUS_COMPLETED || keepIds.contains(prior.Id)) {
        continue;
      }
      Boolean stillSaving = false;
      for (Iteration__c u : toUpsert) {
        if (u.Id == prior.Id) {
          stillSaving = true;
          break;
        }
      }
      if (!stillSaving) {
        toDelete.add(prior);
      }
    }
    if (!toDelete.isEmpty()) {
      delete toDelete;
    }
    if (!toUpsert.isEmpty()) {
      upsert toUpsert;
    }

    List<Iteration__c> saved = queryByParent(new Set<Id>{ parentId });
    Boolean noticeDue = recalculateProjections(parentId, lineEndDate, saved);
    stampRemaining(parentId, countRemaining(saved));
    recordSaveHistory(priorSnapshots, saved, bulkSummary);

    SaveResult result = new SaveResult();
    result.noticeAlreadyDue = noticeDue;
    result.remaining = countRemaining(saved);
    result.iterations = queryByParent(new Set<Id>{ parentId });
    return result;
  }

  public static DeleteResult deleteIterations(
    List<DeleteIterationRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      throw new AuraHandledException(
        'Select at least one iteration to delete.'
      );
    }
    Map<Id, DeleteIterationRequest> batchByLine = new Map<Id, DeleteIterationRequest>();
    Map<Id, Set<Id>> iterationIdsByLine = new Map<Id, Set<Id>>();
    for (DeleteIterationRequest req : requests) {
      if (req == null || req.lineId == null || req.iterationId == null) {
        continue;
      }
      if (!batchByLine.containsKey(req.lineId)) {
        DeleteIterationRequest batch = new DeleteIterationRequest();
        batch.lineId = req.lineId;
        batch.lineEndDate = req.lineEndDate;
        batchByLine.put(req.lineId, batch);
        iterationIdsByLine.put(req.lineId, new Set<Id>());
      }
      iterationIdsByLine.get(req.lineId).add(req.iterationId);
      if (req.lineEndDate != null) {
        batchByLine.get(req.lineId).lineEndDate = req.lineEndDate;
      }
    }
    if (batchByLine.isEmpty()) {
      throw new AuraHandledException(
        'Select at least one iteration to delete.'
      );
    }

    DeleteResult result = new DeleteResult();
    result.noticeAlreadyDue = false;
    for (Id lineId : batchByLine.keySet()) {
      DeleteIterationRequest batch = batchByLine.get(lineId);
      Set<Id> removeIds = iterationIdsByLine.get(lineId);
      List<Iteration__c> existing = queryByParent(new Set<Id>{ lineId });
      List<Iteration__c> remaining = new List<Iteration__c>();
      Integer removed = 0;
      for (Iteration__c row : existing) {
        if (removeIds.contains(row.Id)) {
          if (row.Status__c == STATUS_COMPLETED) {
            throw new AuraHandledException(
              'Completed iterations cannot be deleted.'
            );
          }
          removed++;
          continue;
        }
        remaining.add(row);
      }
      if (removed == 0) {
        continue;
      }
      SaveResult saved = savePlan(lineId, batch.lineEndDate, remaining);
      if (saved != null && saved.noticeAlreadyDue == true) {
        result.noticeAlreadyDue = true;
      }
    }
    return result;
  }

  public static void bulkApplyTemplate(
    List<Id> parentIds,
    Map<Id, Date> endDateByParent,
    Iteration__c template
  ) {
    bulkApplyTemplate(parentIds, endDateByParent, template, null);
  }

  public static BulkApplyResult bulkApplyTemplate(
    List<Id> parentIds,
    Map<Id, Date> endDateByParent,
    Iteration__c template,
    Map<Id, List<Id>> iterationIdsByParent
  ) {
    BulkApplyResult result = new BulkApplyResult();
    result.updatedRows = 0;
    result.skippedCompletedRows = 0;
    result.updatedProducts = 0;
    if (parentIds == null || parentIds.isEmpty() || template == null) {
      result.message = 'Nothing to update.';
      return result;
    }
    if (!hasBulkIterationScope(iterationIdsByParent, parentIds)) {
      throw new AuraHandledException('Select at least one iteration row.');
    }
    Map<Id, List<Iteration__c>> byParent = groupByParent(
      queryByParent(new Set<Id>(parentIds))
    );
    for (Id parentId : parentIds) {
      List<Iteration__c> current = byParent.containsKey(parentId)
        ? byParent.get(parentId)
        : new List<Iteration__c>();
      Set<Id> scopedIds = resolveBulkScopeIds(parentId, iterationIdsByParent);
      List<Iteration__c> nextRows = new List<Iteration__c>();
      Integer updatedOnParent = 0;
      for (Iteration__c row : current) {
        if (row.Status__c == STATUS_COMPLETED) {
          if (scopedIds.contains(row.Id)) {
            result.skippedCompletedRows++;
          }
          nextRows.add(row);
          continue;
        }
        if (!scopedIds.contains(row.Id)) {
          nextRows.add(row);
          continue;
        }
        Iteration__c updated = row.clone(true, true, false, false);
        applyTemplateFields(updated, template);
        nextRows.add(updated);
        updatedOnParent++;
        result.updatedRows++;
      }
      if (updatedOnParent > 0) {
        Date endDate = endDateByParent == null
          ? null
          : endDateByParent.get(parentId);
        savePlan(parentId, endDate, nextRows, 'Bulk apply');
        result.updatedProducts++;
      }
    }
    result.message = buildBulkApplyMessage(result);
    return result;
  }

  public static ApproveResult approve(Id iterationId, Boolean allFuture) {
    if (iterationId == null) {
      throw new AuraHandledException('Iteration is required.');
    }
    return approveIterations(new List<Id>{ iterationId });
  }

  public static ApproveResult approveIterations(List<Id> iterationIds) {
    ApproveResult result = new ApproveResult();
    result.approvedCount = 0;
    result.skippedNoProposed = 0;
    if (iterationIds == null || iterationIds.isEmpty()) {
      throw new AuraHandledException('Select at least one iteration.');
    }
    for (Id iterationId : iterationIds) {
      if (iterationId == null) {
        continue;
      }
      Iteration__c current = loadMutableIteration(iterationId);
      if (
        current.Status__c == STATUS_COMPLETED ||
        current.Status__c == STATUS_INACTIVE
      ) {
        result.skippedNoProposed++;
        continue;
      }
      if (!hasProposedIncrease(current)) {
        result.skippedNoProposed++;
        continue;
      }
      applyProposedToWorking(current);
      clearProposedIncrease(current);
      current.Status__c = STATUS_APPROVED;
      stampNegotiationOwner(current);
      update current;
      IterationHistoryService.recordApproved(current);
      result.approvedCount++;
    }
    result.message = buildApproveMessage(result);
    return result;
  }

  private static String buildApproveMessage(ApproveResult result) {
    if (result.approvedCount == 0 && result.skippedNoProposed > 0) {
      return 'No iterations approved. Selected rows had no pending proposal.';
    }
    String msg =
      'Approved ' +
      result.approvedCount +
      ' iteration' +
      (result.approvedCount == 1 ? '' : 's') +
      '.';
    if (result.skippedNoProposed > 0) {
      msg +=
        ' Skipped ' +
        result.skippedNoProposed +
        ' without pending proposal.';
    }
    return msg;
  }

  public static void discardProposed(Id iterationId) {
    rejectProposed(iterationId);
  }

  public static void rejectProposed(Id iterationId) {
    rejectProposedIterations(new List<Id>{ iterationId });
  }

  public static ActionResult rejectProposedIterations(List<Id> iterationIds) {
    ActionResult result = new ActionResult();
    result.processedCount = 0;
    result.skippedCount = 0;
    if (iterationIds == null || iterationIds.isEmpty()) {
      throw new AuraHandledException('Select at least one iteration.');
    }
    for (Id iterationId : iterationIds) {
      if (iterationId == null) {
        continue;
      }
      Iteration__c row = loadMutableIteration(iterationId);
      if (
        row.Status__c == STATUS_COMPLETED ||
        row.Status__c == STATUS_INACTIVE
      ) {
        result.skippedCount++;
        continue;
      }
      if (!hasProposedIncrease(row)) {
        result.skippedCount++;
        continue;
      }
      Iteration__c prior = row.clone(true, true, true, true);
      clearProposedIncrease(row);
      row.Status__c = STATUS_REJECTED;
      stampNegotiationOwner(row);
      update row;
      IterationHistoryService.recordRejected(prior, row);
      result.processedCount++;
    }
    result.message = buildActionMessage('Rejected', result);
    return result;
  }

  public static void saveProposed(Id iterationId, Iteration__c proposed) {
    saveProposedIterations(new List<Id>{ iterationId }, proposed);
  }

  public static ActionResult saveProposedIterations(
    List<Id> iterationIds,
    Iteration__c proposed
  ) {
    ActionResult result = new ActionResult();
    result.processedCount = 0;
    result.skippedCount = 0;
    if (iterationIds == null || iterationIds.isEmpty()) {
      throw new AuraHandledException('Select at least one iteration.');
    }
    for (Id iterationId : iterationIds) {
      if (iterationId == null) {
        continue;
      }
      Iteration__c row = loadMutableIteration(iterationId);
      if (
        row.Status__c == STATUS_COMPLETED ||
        row.Status__c == STATUS_INACTIVE
      ) {
        result.skippedCount++;
        continue;
      }
      Iteration__c prior = row.clone(true, true, true, true);
      applyProposedFields(row, proposed);
      row.Status__c = STATUS_PROPOSED;
      stampNegotiationOwner(row);
      update row;
      IterationHistoryService.recordChanged(prior, row, 'Proposed saved');
      result.processedCount++;
    }
    result.message = buildActionMessage('Proposed', result);
    return result;
  }

  private static void applyProposedFields(
    Iteration__c row,
    Iteration__c proposed
  ) {
    if (proposed == null) {
      return;
    }
    if (
      proposed.getPopulatedFieldsAsMap()
        .containsKey('Proposed_Increase_Type__c')
    ) {
      row.Proposed_Increase_Type__c = normalizeIncreaseType(
        proposed.Proposed_Increase_Type__c
      );
    }
    if (proposed.Proposed_Increase_Percent__c != null) {
      row.Proposed_Increase_Percent__c = proposed.Proposed_Increase_Percent__c;
    }
    if (proposed.Proposed_Increase_Amount__c != null) {
      row.Proposed_Increase_Amount__c = proposed.Proposed_Increase_Amount__c;
    }
    if (proposed.Proposed_Final_Price__c != null) {
      row.Proposed_Final_Price__c = proposed.Proposed_Final_Price__c;
    }
    normalizeIncreaseTypes(row);
  }

  public static void revertWorkingToOriginal(Id iterationId) {
    Iteration__c row = loadMutableIteration(iterationId);
    if (row.Status__c == STATUS_COMPLETED || row.Status__c == STATUS_INACTIVE) {
      throw new AuraHandledException(
        'Completed iterations cannot be reverted.'
      );
    }
    if (
      String.isBlank(row.Original_Increase_Type__c) &&
      row.Original_Increase_Percent__c == null &&
      row.Original_Increase_Amount__c == null &&
      row.Original_Final_Price__c == null
    ) {
      throw new AuraHandledException('No original increase to revert to.');
    }
    Iteration__c prior = row.clone(true, true, true, true);
    applyOriginalToWorking(row);
    stampNegotiationOwner(row);
    update row;
    IterationHistoryService.recordReverted(prior, row);
  }

  private static Iteration__c loadMutableIteration(Id iterationId) {
    if (iterationId == null) {
      throw new AuraHandledException('Iteration is required.');
    }
    return [
      SELECT
        Id,
        Sequence__c,
        Status__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c,
        Proposed_Increase_Type__c,
        Proposed_Increase_Percent__c,
        Proposed_Increase_Amount__c,
        Proposed_Final_Price__c,
        Original_Increase_Type__c,
        Original_Increase_Percent__c,
        Original_Increase_Amount__c,
        Original_Final_Price__c,
        Negotiation_Owner__c
      FROM Iteration__c
      WHERE Id = :iterationId
      LIMIT 1
    ];
  }

  public static Boolean recalculateProjections(
    Id parentId,
    Date lineEndDate,
    List<Iteration__c> rows
  ) {
    return recalculateProjections(parentId, lineEndDate, rows, true);
  }

  public static Boolean recalculateProjections(
    Id parentId,
    Date lineEndDate,
    List<Iteration__c> rows,
    Boolean persist
  ) {
    if (rows == null || rows.isEmpty() || lineEndDate == null) {
      return false;
    }
    Date anchorEnd = lineEndDate;
    Boolean noticeDue = false;
    List<Iteration__c> toUpdate = new List<Iteration__c>();
    for (Iteration__c row : rows) {
      if (row.Status__c == STATUS_COMPLETED) {
        continue;
      }
      Integer months = row.Duration_Months__c == null
        ? 0
        : Integer.valueOf(row.Duration_Months__c);
      Integer noticeDays = row.Advance_Notice_Days__c == null
        ? 0
        : Integer.valueOf(row.Advance_Notice_Days__c);
      Date periodStart = anchorEnd.addDays(1);
      Date periodEnd = months > 0
        ? periodStart.addMonths(months).addDays(-1)
        : periodStart;
      Date noticeDate = anchorEnd.addDays(-noticeDays);
      row.Period_Start_Date__c = periodStart;
      row.Period_End_Date__c = periodEnd;
      row.Notice_Date__c = noticeDate;
      if (noticeDate != null && noticeDate <= Date.today()) {
        noticeDue = true;
      }
      toUpdate.add(row);
      anchorEnd = periodEnd;
    }
    if (persist == true && !toUpdate.isEmpty()) {
      update toUpdate;
    }
    return noticeDue;
  }

  public static Integer countRemaining(List<Iteration__c> rows) {
    Integer remaining = 0;
    if (rows == null) {
      return remaining;
    }
    for (Iteration__c row : rows) {
      if (
        row.Status__c != STATUS_COMPLETED &&
        row.Status__c != STATUS_INACTIVE
      ) {
        remaining++;
      }
    }
    return remaining;
  }

  public static void stampRemaining(Id parentId, Integer remaining) {
    if (parentId == null) {
      return;
    }
    Integer value = remaining == null ? 0 : remaining;
    if (parentId.getSObjectType() == OrderItem.SObjectType) {
      update new OrderItem(Id = parentId, Remaining_Iterations__c = value);
    } else if (parentId.getSObjectType() == OpportunityLineItem.SObjectType) {
      update new OpportunityLineItem(
        Id = parentId,
        Remaining_Iterations__c = value
      );
    }
  }

  public static void copyFromOpportunityProducts(List<OrderItem> newItems) {
    if (newItems == null || newItems.isEmpty()) {
      return;
    }
    Set<Id> oliIds = new Set<Id>();
    Map<Id, Id> oliToOrderItem = new Map<Id, Id>();
    for (OrderItem item : newItems) {
      // Modify-contract draft clones use Original_Order_Product__c; Active plan wins.
      if (item.Original_Order_Product__c != null) {
        continue;
      }
      if (item.Opportunity_Product__c != null) {
        oliIds.add(item.Opportunity_Product__c);
        oliToOrderItem.put(item.Opportunity_Product__c, item.Id);
      }
    }
    if (oliIds.isEmpty()) {
      return;
    }
    List<Iteration__c> source = queryByParent(oliIds);
    if (source.isEmpty()) {
      return;
    }
    List<Iteration__c> clones = new List<Iteration__c>();
    for (Iteration__c row : source) {
      Id newParent = oliToOrderItem.get(row.Opportunity_Product__c);
      if (newParent == null) {
        continue;
      }
      Iteration__c copy = row.clone(false, true, false, false);
      copy.Opportunity_Product__c = null;
      copy.Order_Product__c = newParent;
      copy.Prior_Status__c = null;
      clones.add(copy);
    }
    if (!clones.isEmpty()) {
      insert clones;
    }
    Map<Id, List<Iteration__c>> byNew = groupByParent(clones);
    for (Id newParent : byNew.keySet()) {
      stampRemaining(newParent, countRemaining(byNew.get(newParent)));
    }
  }

  /**
   * Copy Iteration plan from Active (or prior) OrderItems onto newly cloned draft lines
   * keyed by Original_Order_Product__c. Used by modify-contract ensureDraftOrder.
   */
  public static void copyFromOriginalOrderProducts(List<OrderItem> newItems) {
    if (newItems == null || newItems.isEmpty()) {
      return;
    }
    Set<Id> sourceIds = new Set<Id>();
    Map<Id, Id> sourceToNew = new Map<Id, Id>();
    for (OrderItem item : newItems) {
      if (item.Id == null || item.Original_Order_Product__c == null) {
        continue;
      }
      sourceIds.add(item.Original_Order_Product__c);
      sourceToNew.put(item.Original_Order_Product__c, item.Id);
    }
    if (sourceIds.isEmpty()) {
      return;
    }
    List<Iteration__c> source = queryByParent(sourceIds);
    if (source.isEmpty()) {
      return;
    }
    List<Iteration__c> clones = new List<Iteration__c>();
    for (Iteration__c row : source) {
      Id newParent = sourceToNew.get(row.Order_Product__c);
      if (newParent == null) {
        continue;
      }
      Iteration__c copy = row.clone(false, true, false, false);
      copy.Opportunity_Product__c = null;
      copy.Order_Product__c = newParent;
      copy.Prior_Status__c = null;
      clones.add(copy);
    }
    if (!clones.isEmpty()) {
      insert clones;
    }
    Map<Id, List<Iteration__c>> byNew = groupByParent(clones);
    for (Id newParent : byNew.keySet()) {
      stampRemaining(newParent, countRemaining(byNew.get(newParent)));
    }
  }

  /**
   * Move Iteration plan from a replaced Periodic parent onto the latest Periodic
   * replacement child (product replace / qty change). Skips access-type changes.
   * Source rows are marked Inactive (Prior_Status kept) so they can be restored
   * if the replacement is deleted.
   */
  public static void copyFromReplacedOrderProducts(List<OrderItem> newItems) {
    if (newItems == null || newItems.isEmpty()) {
      return;
    }
    Set<Id> parentIds = new Set<Id>();
    for (OrderItem item : newItems) {
      if (
        item == null ||
        item.Id == null ||
        item.Replaced_Order_Product__c == null ||
        item.Changed_Access_Type__c == true
      ) {
        continue;
      }
      parentIds.add(item.Replaced_Order_Product__c);
    }
    if (parentIds.isEmpty()) {
      return;
    }

    Map<Id, List<OrderItem>> childrenByParent = loadEligibleReplacementChildren(
      parentIds,
      null
    );
    Set<Id> allLineIds = new Set<Id>(parentIds);
    for (List<OrderItem> children : childrenByParent.values()) {
      for (OrderItem child : children) {
        allLineIds.add(child.Id);
      }
    }
    Map<Id, List<Iteration__c>> iterationsByLine = groupByParent(
      queryByParent(allLineIds)
    );

    List<Iteration__c> toInsert = new List<Iteration__c>();
    List<Iteration__c> toUpdate = new List<Iteration__c>();
    Set<Id> stampIds = new Set<Id>();

    for (Id parentId : parentIds) {
      List<OrderItem> children = childrenByParent.get(parentId);
      if (children == null || children.isEmpty()) {
        continue;
      }
      OrderItem latest = pickLatestReplacement(children);
      if (latest == null) {
        continue;
      }
      List<Iteration__c> onLatest = iterationsByLine.containsKey(latest.Id)
        ? iterationsByLine.get(latest.Id)
        : new List<Iteration__c>();
      if (!onLatest.isEmpty()) {
        continue;
      }

      List<Iteration__c> onParent = iterationsByLine.containsKey(parentId)
        ? iterationsByLine.get(parentId)
        : new List<Iteration__c>();
      if (!onParent.isEmpty()) {
        for (Iteration__c row : onParent) {
          Iteration__c copy = row.clone(false, true, false, false);
          copy.Opportunity_Product__c = null;
          copy.Order_Product__c = latest.Id;
          copy.Prior_Status__c = null;
          toInsert.add(copy);

          row.Prior_Status__c = String.isNotBlank(row.Status__c)
            ? row.Status__c
            : STATUS_ORIGINAL;
          row.Status__c = STATUS_INACTIVE;
          toUpdate.add(row);
        }
        stampIds.add(parentId);
        stampIds.add(latest.Id);
        continue;
      }

      // Parent already Inactive from a prior replace: move active plan from an older child.
      for (OrderItem sibling : children) {
        if (sibling.Id == latest.Id) {
          continue;
        }
        List<Iteration__c> onSibling = iterationsByLine.containsKey(sibling.Id)
          ? iterationsByLine.get(sibling.Id)
          : new List<Iteration__c>();
        if (onSibling.isEmpty()) {
          continue;
        }
        for (Iteration__c row : onSibling) {
          row.Order_Product__c = latest.Id;
          toUpdate.add(row);
        }
        stampIds.add(sibling.Id);
        stampIds.add(latest.Id);
        break;
      }
    }

    if (!toInsert.isEmpty()) {
      insert toInsert;
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
    for (Id lineId : stampIds) {
      stampRemaining(
        lineId,
        countRemaining(queryByParent(new Set<Id>{ lineId }))
      );
    }
  }

  /**
   * When Periodic replacement children are deleted: remove their active Iteration
   * clones. If no eligible sibling remains, restore Inactive rows on the parent.
   * If siblings remain, move the deleted child's plan to the new latest sibling.
   */
  public static void restoreFromReplacedOrderProducts(
    List<OrderItem> deletedItems
  ) {
    if (deletedItems == null || deletedItems.isEmpty()) {
      return;
    }
    Set<Id> deletedIds = new Set<Id>();
    Set<Id> parentIds = new Set<Id>();
    for (OrderItem item : deletedItems) {
      if (
        item == null ||
        item.Id == null ||
        item.Replaced_Order_Product__c == null ||
        item.Changed_Access_Type__c == true
      ) {
        continue;
      }
      deletedIds.add(item.Id);
      parentIds.add(item.Replaced_Order_Product__c);
    }
    if (deletedIds.isEmpty() || parentIds.isEmpty()) {
      return;
    }

    Map<Id, List<OrderItem>> remainingByParent = loadEligibleReplacementChildren(
      parentIds,
      deletedIds
    );
    Map<Id, List<Iteration__c>> activeOnDeleted = groupByParent(
      queryByParent(deletedIds)
    );
    Map<Id, List<Iteration__c>> inactiveOnParents = groupByParent(
      [
        SELECT
          Id,
          Order_Product__c,
          Opportunity_Product__c,
          Status__c,
          Prior_Status__c
        FROM Iteration__c
        WHERE Order_Product__c IN :parentIds AND Status__c = :STATUS_INACTIVE
      ]
    );

    List<Iteration__c> toDelete = new List<Iteration__c>();
    List<Iteration__c> toUpdate = new List<Iteration__c>();
    Set<Id> stampIds = new Set<Id>();

    for (Id parentId : parentIds) {
      List<OrderItem> remaining = remainingByParent.containsKey(parentId)
        ? remainingByParent.get(parentId)
        : new List<OrderItem>();
      List<Iteration__c> deletedPlan = new List<Iteration__c>();
      for (Id deletedId : deletedIds) {
        if (!activeOnDeleted.containsKey(deletedId)) {
          continue;
        }
        // Only iterations belonging to children of this parent
        for (OrderItem gone : deletedItems) {
          if (
            gone != null &&
            gone.Id == deletedId &&
            gone.Replaced_Order_Product__c == parentId
          ) {
            deletedPlan.addAll(activeOnDeleted.get(deletedId));
          }
        }
      }

      if (remaining.isEmpty()) {
        toDelete.addAll(deletedPlan);
        List<Iteration__c> inactive = inactiveOnParents.containsKey(parentId)
          ? inactiveOnParents.get(parentId)
          : new List<Iteration__c>();
        for (Iteration__c row : inactive) {
          row.Status__c = String.isNotBlank(row.Prior_Status__c)
            ? row.Prior_Status__c
            : STATUS_ORIGINAL;
          row.Prior_Status__c = null;
          toUpdate.add(row);
        }
        stampIds.add(parentId);
        continue;
      }

      OrderItem latest = pickLatestReplacement(remaining);
      List<Iteration__c> onLatest = queryByParent(new Set<Id>{ latest.Id });
      if (!deletedPlan.isEmpty() && onLatest.isEmpty()) {
        for (Iteration__c row : deletedPlan) {
          row.Order_Product__c = latest.Id;
          toUpdate.add(row);
        }
        stampIds.add(latest.Id);
      } else {
        toDelete.addAll(deletedPlan);
      }
      for (OrderItem rem : remaining) {
        stampIds.add(rem.Id);
      }
    }

    if (!toDelete.isEmpty()) {
      delete toDelete;
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
    for (Id lineId : stampIds) {
      stampRemaining(
        lineId,
        countRemaining(queryByParent(new Set<Id>{ lineId }))
      );
    }
  }

  private static Map<Id, List<OrderItem>> loadEligibleReplacementChildren(
    Set<Id> parentIds,
    Set<Id> excludeIds
  ) {
    Map<Id, List<OrderItem>> byParent = new Map<Id, List<OrderItem>>();
    if (parentIds == null || parentIds.isEmpty()) {
      return byParent;
    }
    for (OrderItem child : [
      SELECT
        Id,
        Replaced_Order_Product__c,
        Access_Type__c,
        Changed_Access_Type__c,
        ServiceDate,
        CreatedDate
      FROM OrderItem
      WHERE Replaced_Order_Product__c IN :parentIds
      ORDER BY ServiceDate ASC NULLS FIRST, CreatedDate ASC
    ]) {
      if (excludeIds != null && excludeIds.contains(child.Id)) {
        continue;
      }
      if (
        child.Changed_Access_Type__c == true ||
        !isPeriodic(child.Access_Type__c)
      ) {
        continue;
      }
      Id parentId = child.Replaced_Order_Product__c;
      if (!byParent.containsKey(parentId)) {
        byParent.put(parentId, new List<OrderItem>());
      }
      byParent.get(parentId).add(child);
    }
    return byParent;
  }

  private static OrderItem pickLatestReplacement(List<OrderItem> children) {
    if (children == null || children.isEmpty()) {
      return null;
    }
    OrderItem latest = null;
    for (OrderItem child : children) {
      if (latest == null) {
        latest = child;
        continue;
      }
      Date childStart = child.ServiceDate;
      Date latestStart = latest.ServiceDate;
      if (childStart != null && latestStart != null) {
        if (childStart > latestStart) {
          latest = child;
        } else if (
          childStart == latestStart &&
          child.CreatedDate > latest.CreatedDate
        ) {
          latest = child;
        }
      } else if (childStart != null && latestStart == null) {
        latest = child;
      } else if (
        childStart == latestStart &&
        child.CreatedDate > latest.CreatedDate
      ) {
        latest = child;
      }
    }
    return latest;
  }

  public static Iteration__c nextDueIteration(
    List<Iteration__c> rows,
    Date today
  ) {
    if (rows == null) {
      return null;
    }
    Iteration__c nextRow = null;
    for (Iteration__c row : rows) {
      if (
        row.Status__c == STATUS_COMPLETED ||
        row.Status__c == STATUS_INACTIVE
      ) {
        continue;
      }
      if (row.Notice_Date__c == null || row.Notice_Date__c > today) {
        continue;
      }
      if (
        nextRow == null ||
        (row.Sequence__c != null &&
        nextRow.Sequence__c != null &&
        row.Sequence__c < nextRow.Sequence__c)
      ) {
        nextRow = row;
      }
    }
    return nextRow;
  }

  public static Boolean usesApprovedIncrease(Iteration__c row) {
    return row != null && row.Status__c == STATUS_APPROVED;
  }

  public static Map<Id, List<Iteration__c>> groupByParent(
    List<Iteration__c> rows
  ) {
    Map<Id, List<Iteration__c>> byParent = new Map<Id, List<Iteration__c>>();
    for (Iteration__c row : rows) {
      Id parentId = row.Order_Product__c != null
        ? row.Order_Product__c
        : row.Opportunity_Product__c;
      if (parentId == null) {
        continue;
      }
      if (!byParent.containsKey(parentId)) {
        byParent.put(parentId, new List<Iteration__c>());
      }
      byParent.get(parentId).add(row);
    }
    return byParent;
  }

  private static Set<Id> resolveBulkScopeIds(
    Id parentId,
    Map<Id, List<Id>> iterationIdsByParent
  ) {
    if (
      iterationIdsByParent == null ||
      !iterationIdsByParent.containsKey(parentId)
    ) {
      return new Set<Id>();
    }
    List<Id> ids = iterationIdsByParent.get(parentId);
    if (ids == null || ids.isEmpty()) {
      return new Set<Id>();
    }
    return new Set<Id>(ids);
  }

  private static Boolean hasBulkIterationScope(
    Map<Id, List<Id>> iterationIdsByParent,
    List<Id> parentIds
  ) {
    if (iterationIdsByParent == null || parentIds == null) {
      return false;
    }
    for (Id parentId : parentIds) {
      List<Id> ids = iterationIdsByParent.get(parentId);
      if (ids != null && !ids.isEmpty()) {
        return true;
      }
    }
    return false;
  }

  private static String buildActionMessage(String verb, ActionResult result) {
    if (result.processedCount == 0 && result.skippedCount > 0) {
      return 'No iterations ' +
        verb.toLowerCase() +
        '. Selected rows were ineligible.';
    }
    String msg =
      verb +
      ' ' +
      result.processedCount +
      ' iteration' +
      (result.processedCount == 1 ? '' : 's') +
      '.';
    if (result.skippedCount > 0) {
      msg += ' Skipped ' + result.skippedCount + ' ineligible row(s).';
    }
    return msg;
  }

  private static String buildBulkApplyMessage(BulkApplyResult result) {
    if (result.updatedRows == 0) {
      if (result.skippedCompletedRows > 0) {
        return 'No rows updated. Completed iterations were skipped.';
      }
      return 'No rows updated.';
    }
    String msg =
      'Updated ' +
      result.updatedRows +
      ' iteration' +
      (result.updatedRows == 1 ? '' : 's') +
      ' across ' +
      result.updatedProducts +
      ' product' +
      (result.updatedProducts == 1 ? '' : 's') +
      '.';
    if (result.skippedCompletedRows > 0) {
      msg +=
        ' Skipped ' +
        result.skippedCompletedRows +
        ' completed row' +
        (result.skippedCompletedRows == 1 ? '' : 's') +
        '.';
    }
    return msg;
  }

  private static void applyTemplateFields(
    Iteration__c updated,
    Iteration__c template
  ) {
    if (template.Duration_Months__c != null) {
      updated.Duration_Months__c = template.Duration_Months__c;
    }
    if (template.Advance_Notice_Days__c != null) {
      updated.Advance_Notice_Days__c = template.Advance_Notice_Days__c;
    }
    if (template.getPopulatedFieldsAsMap().containsKey('Increase_Type__c')) {
      updated.Increase_Type__c = template.Increase_Type__c;
    }
    if (template.Increase_Percent__c != null) {
      updated.Increase_Percent__c = template.Increase_Percent__c;
    }
    if (template.Increase_Amount__c != null) {
      updated.Increase_Amount__c = template.Increase_Amount__c;
    }
    if (template.Final_Price__c != null) {
      updated.Final_Price__c = template.Final_Price__c;
    }
    if (
      template.getPopulatedFieldsAsMap()
        .containsKey('Proposed_Increase_Type__c')
    ) {
      updated.Proposed_Increase_Type__c = template.Proposed_Increase_Type__c;
    }
    if (template.Proposed_Increase_Percent__c != null) {
      updated.Proposed_Increase_Percent__c = template.Proposed_Increase_Percent__c;
    }
    if (template.Proposed_Increase_Amount__c != null) {
      updated.Proposed_Increase_Amount__c = template.Proposed_Increase_Amount__c;
    }
    if (template.Proposed_Final_Price__c != null) {
      updated.Proposed_Final_Price__c = template.Proposed_Final_Price__c;
    }
  }

  private static void applyApprovalStatusRules(
    Iteration__c rec,
    Iteration__c existing
  ) {
    if (rec == null || rec.Status__c != STATUS_APPROVED) {
      return;
    }
    String prior = existing == null ? null : existing.Status__c;
    Boolean pending = hasProposedIncrease(rec);
    if (prior == STATUS_APPROVED) {
      if (pending && proposedIncreaseChanged(rec, existing)) {
        rec.Status__c = STATUS_PLANNED;
      }
      return;
    }
    rec.Status__c = String.isBlank(prior) ? STATUS_PLANNED : prior;
  }

  private static void prepareOriginalBaseline(
    Iteration__c rec,
    Iteration__c existing
  ) {
    if (rec == null) {
      return;
    }
    Boolean firstProposed =
      hasProposedIncrease(rec) &&
      (existing == null || !hasProposedIncrease(existing));
    if (firstProposed) {
      snapshotOriginalFromWorking(rec);
    }
  }

  @TestVisible
  static Boolean hasProposedIncrease(Iteration__c rec) {
    if (rec == null) {
      return false;
    }
    Map<String, Object> populated = rec.getPopulatedFieldsAsMap();
    return String.isNotBlank(
        (String) populated.get('Proposed_Increase_Type__c')
      ) ||
      populated.get('Proposed_Increase_Percent__c') != null ||
      populated.get('Proposed_Increase_Amount__c') != null ||
      populated.get('Proposed_Final_Price__c') != null;
  }

  private static Boolean proposedIncreaseChanged(
    Iteration__c rec,
    Iteration__c existing
  ) {
    if (rec == null) {
      return false;
    }
    if (existing == null) {
      return hasProposedIncrease(rec);
    }
    Map<String, Object> next = rec.getPopulatedFieldsAsMap();
    Map<String, Object> prior = existing.getPopulatedFieldsAsMap();
    return next.get('Proposed_Increase_Type__c') !=
      prior.get('Proposed_Increase_Type__c') ||
      next.get('Proposed_Increase_Percent__c') !=
      prior.get('Proposed_Increase_Percent__c') ||
      next.get('Proposed_Increase_Amount__c') !=
      prior.get('Proposed_Increase_Amount__c') ||
      next.get('Proposed_Final_Price__c') !=
      prior.get('Proposed_Final_Price__c');
  }

  private static void snapshotOriginalFromWorking(Iteration__c row) {
    Map<String, Object> populated = row.getPopulatedFieldsAsMap();
    row.Original_Increase_Type__c = (String) populated.get('Increase_Type__c');
    row.Original_Increase_Percent__c = (Decimal) populated.get(
      'Increase_Percent__c'
    );
    row.Original_Increase_Amount__c = (Decimal) populated.get(
      'Increase_Amount__c'
    );
    row.Original_Final_Price__c = (Decimal) populated.get('Final_Price__c');
  }

  private static void clearProposedIncrease(Iteration__c row) {
    row.Proposed_Increase_Type__c = null;
    row.Proposed_Increase_Percent__c = null;
    row.Proposed_Increase_Amount__c = null;
    row.Proposed_Final_Price__c = null;
  }

  private static void seedOriginalIfBlank(Iteration__c rec) {
    Map<String, Object> populated = rec.getPopulatedFieldsAsMap();
    if (
      !populated.containsKey('Original_Increase_Type__c') ||
      String.isBlank((String) populated.get('Original_Increase_Type__c'))
    ) {
      rec.Original_Increase_Type__c = populated.containsKey('Increase_Type__c')
        ? (String) populated.get('Increase_Type__c')
        : null;
    }
    if (
      !populated.containsKey('Original_Increase_Percent__c') ||
      populated.get('Original_Increase_Percent__c') == null
    ) {
      rec.Original_Increase_Percent__c = populated.containsKey(
          'Increase_Percent__c'
        )
        ? (Decimal) populated.get('Increase_Percent__c')
        : null;
    }
    if (
      !populated.containsKey('Original_Increase_Amount__c') ||
      populated.get('Original_Increase_Amount__c') == null
    ) {
      rec.Original_Increase_Amount__c = populated.containsKey(
          'Increase_Amount__c'
        )
        ? (Decimal) populated.get('Increase_Amount__c')
        : null;
    }
    if (
      !populated.containsKey('Original_Final_Price__c') ||
      populated.get('Original_Final_Price__c') == null
    ) {
      rec.Original_Final_Price__c = populated.containsKey('Final_Price__c')
        ? (Decimal) populated.get('Final_Price__c')
        : null;
    }
  }

  private static void applyProposedToWorking(Iteration__c row) {
    String type = normalizeIncreaseType(
      String.isNotBlank(row.Proposed_Increase_Type__c)
        ? row.Proposed_Increase_Type__c
        : row.Increase_Type__c
    );
    row.Increase_Type__c = type;
    row.Increase_Percent__c = null;
    row.Increase_Amount__c = null;
    row.Final_Price__c = null;
    if (type == TYPE_VALUE) {
      row.Increase_Amount__c = row.Proposed_Increase_Amount__c;
    } else if (type == TYPE_FINAL) {
      row.Final_Price__c = row.Proposed_Final_Price__c;
    } else if (type == TYPE_PERCENT) {
      row.Increase_Percent__c = row.Proposed_Increase_Percent__c;
    }
  }

  private static void applyOriginalToWorking(Iteration__c row) {
    String type = normalizeIncreaseType(
      String.isNotBlank(row.Original_Increase_Type__c)
        ? row.Original_Increase_Type__c
        : row.Increase_Type__c
    );
    row.Increase_Type__c = type;
    row.Increase_Percent__c = null;
    row.Increase_Amount__c = null;
    row.Final_Price__c = null;
    if (type == TYPE_VALUE) {
      row.Increase_Amount__c = row.Original_Increase_Amount__c;
    } else if (type == TYPE_FINAL) {
      row.Final_Price__c = row.Original_Final_Price__c;
    } else if (type == TYPE_PERCENT) {
      row.Increase_Percent__c = row.Original_Increase_Percent__c;
    }
  }

  public static String normalizeIncreaseType(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    if (raw == TYPE_PERCENT || raw == 'Percent') {
      return TYPE_PERCENT;
    }
    if (raw == TYPE_VALUE || raw == 'Fixed Amount' || raw == 'Amount') {
      return TYPE_VALUE;
    }
    if (raw == TYPE_FINAL || raw == 'Final Price') {
      return TYPE_FINAL;
    }
    return raw;
  }

  private static Boolean workingCommercialFieldsEqual(
    Iteration__c nextRow,
    Iteration__c priorRow
  ) {
    if (nextRow == null || priorRow == null) {
      return false;
    }
    Map<String, Object> nextPop = nextRow.getPopulatedFieldsAsMap();
    Map<String, Object> priorPop = priorRow.getPopulatedFieldsAsMap();
    if (nextPop.containsKey('Increase_Type__c')) {
      if (
        normalizeIncreaseType((String) nextPop.get('Increase_Type__c')) !=
        normalizeIncreaseType((String) priorPop.get('Increase_Type__c'))
      ) {
        return false;
      }
    }
    if (
      nextPop.containsKey('Increase_Percent__c') &&
      nextPop.get('Increase_Percent__c') != priorPop.get('Increase_Percent__c')
    ) {
      return false;
    }
    if (
      nextPop.containsKey('Increase_Amount__c') &&
      nextPop.get('Increase_Amount__c') != priorPop.get('Increase_Amount__c')
    ) {
      return false;
    }
    if (
      nextPop.containsKey('Final_Price__c') &&
      nextPop.get('Final_Price__c') != priorPop.get('Final_Price__c')
    ) {
      return false;
    }
    return true;
  }

  private static void validateCommercialFields(Iteration__c row) {
    if (row == null) {
      return;
    }
    if (row.Status__c == STATUS_COMPLETED || row.Status__c == STATUS_INACTIVE) {
      return;
    }
    String seqLabel = row.Sequence__c == null
      ? '?'
      : String.valueOf(row.Sequence__c.intValue());
    Map<String, Object> populated = row.getPopulatedFieldsAsMap();
    validateCommercialPair(
      'Iteration ' +
        seqLabel +
        ': Price Increase Value is required when a type is selected.',
      (String) populated.get('Increase_Type__c'),
      decimalFromPopulated(populated, 'Increase_Percent__c'),
      decimalFromPopulated(populated, 'Increase_Amount__c'),
      decimalFromPopulated(populated, 'Final_Price__c')
    );
  }

  private static Decimal decimalFromPopulated(
    Map<String, Object> populated,
    String fieldName
  ) {
    if (populated == null || !populated.containsKey(fieldName)) {
      return null;
    }
    return (Decimal) populated.get(fieldName);
  }

  private static void validateCommercialPair(
    String message,
    String type,
    Decimal percent,
    Decimal amount,
    Decimal finalPrice
  ) {
    String normalized = normalizeIncreaseType(type);
    if (String.isBlank(normalized)) {
      return;
    }
    if (normalized == TYPE_PERCENT && percent == null) {
      throw new AuraHandledException(message);
    }
    if (normalized == TYPE_VALUE && amount == null) {
      throw new AuraHandledException(message);
    }
    if (normalized == TYPE_FINAL && finalPrice == null) {
      throw new AuraHandledException(message);
    }
  }

  private static void normalizeIncreaseTypes(Iteration__c rec) {
    if (rec == null) {
      return;
    }
    Map<String, Object> populated = rec.getPopulatedFieldsAsMap();
    if (populated.containsKey('Increase_Type__c')) {
      rec.Increase_Type__c = normalizeIncreaseType(
        (String) populated.get('Increase_Type__c')
      );
    }
    if (populated.containsKey('Proposed_Increase_Type__c')) {
      rec.Proposed_Increase_Type__c = normalizeIncreaseType(
        (String) populated.get('Proposed_Increase_Type__c')
      );
    }
    if (populated.containsKey('Original_Increase_Type__c')) {
      rec.Original_Increase_Type__c = normalizeIncreaseType(
        (String) populated.get('Original_Increase_Type__c')
      );
    }
  }

  private static Map<Id, Iteration__c> snapshotById(List<Iteration__c> rows) {
    Map<Id, Iteration__c> out = new Map<Id, Iteration__c>();
    if (rows == null) {
      return out;
    }
    for (Iteration__c row : rows) {
      if (row.Id != null) {
        out.put(row.Id, row.clone(true, true, true, true));
      }
    }
    return out;
  }

  private static void stampNegotiationOwner(Iteration__c rec) {
    if (rec != null) {
      rec.Negotiation_Owner__c = UserInfo.getUserId();
    }
  }

  private static void recordSaveHistory(
    Map<Id, Iteration__c> priorById,
    List<Iteration__c> saved,
    String bulkSummary
  ) {
    if (saved == null || saved.isEmpty()) {
      return;
    }
    for (Iteration__c after : saved) {
      if (after.Id == null || after.Status__c == STATUS_COMPLETED) {
        continue;
      }
      Iteration__c prior = priorById != null ? priorById.get(after.Id) : null;
      if (String.isNotBlank(bulkSummary)) {
        IterationHistoryService.recordBulkApplied(after, bulkSummary);
        continue;
      }
      if (prior == null) {
        IterationHistoryService.recordChanged(null, after, 'Plan row added');
        continue;
      }
      if (hasStatusChange(prior, after)) {
        IterationHistoryService.recordStatusChanged(prior, after, null);
      }
      if (hasCommercialChange(prior, after)) {
        IterationHistoryService.recordChanged(prior, after, null);
      }
    }
  }

  private static Boolean hasStatusChange(
    Iteration__c prior,
    Iteration__c after
  ) {
    if (after == null) {
      return false;
    }
    if (prior == null) {
      return String.isNotBlank(after.Status__c);
    }
    return prior.Status__c != after.Status__c;
  }

  private static Boolean hasCommercialChange(
    Iteration__c prior,
    Iteration__c after
  ) {
    if (after == null) {
      return false;
    }
    if (prior == null) {
      return true;
    }
    return !sameDecimal(prior.Duration_Months__c, after.Duration_Months__c) ||
      !sameDecimal(
        prior.Advance_Notice_Days__c,
        after.Advance_Notice_Days__c
      ) ||
      prior.Increase_Type__c != after.Increase_Type__c ||
      !sameDecimal(prior.Increase_Percent__c, after.Increase_Percent__c) ||
      !sameDecimal(prior.Increase_Amount__c, after.Increase_Amount__c) ||
      !sameDecimal(prior.Final_Price__c, after.Final_Price__c) ||
      prior.Proposed_Increase_Type__c != after.Proposed_Increase_Type__c ||
      !sameDecimal(
        prior.Proposed_Increase_Percent__c,
        after.Proposed_Increase_Percent__c
      ) ||
      !sameDecimal(
        prior.Proposed_Increase_Amount__c,
        after.Proposed_Increase_Amount__c
      ) ||
      !sameDecimal(
        prior.Proposed_Final_Price__c,
        after.Proposed_Final_Price__c
      );
  }

  private static Boolean sameDecimal(Decimal a, Decimal b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a == b;
  }
}
