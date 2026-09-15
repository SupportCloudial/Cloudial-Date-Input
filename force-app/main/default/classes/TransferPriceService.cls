/**
 * Room-replace "Transfer price": copy monthly commercial terms (Discount / ListPrice /
 * Final_Adjusted_Price) from the replaced line onto the replacement, and map them back on undo-delete.
 */
public without sharing class TransferPriceService {
  public class MonthTerm {
    public Date monthStart;
    public Decimal discount;
    public Decimal listPrice;
    public Decimal finalAdjustedPrice;
    public Decimal monthlyUnits;
  }

  /**
   * Full-month commercial list total on old line → UnitPrice on new line (qty may differ).
   */
  public static Decimal unitPriceFromTransferredDeal(
    Decimal oldUnitPrice,
    Decimal oldQuantity,
    Decimal newQuantity
  ) {
    Decimal oldQty = oldQuantity != null && oldQuantity != 0 ? oldQuantity : 1;
    Decimal newQty = newQuantity != null && newQuantity != 0 ? newQuantity : 1;
    Decimal oldUnit = oldUnitPrice != null ? oldUnitPrice : 0;
    return ((oldUnit * oldQty) / newQty)
      .setScale(2, System.RoundingMode.HALF_UP);
  }

  /**
   * Snapshot terms from a line before it is curtailed (replace updates EndDate and may
   * delete post-swap monthly payments).
   */
  public static List<MonthTerm> snapshotTermsFromOrderItem(
    Id orderItemId,
    Date replaceStart
  ) {
    if (orderItemId == null || replaceStart == null) {
      return new List<MonthTerm>();
    }
    return loadTermsForOrderItem(orderItemId, monthStartOf(replaceStart));
  }

  /**
   * After replacement OrderItem insert (payments already auto-generated): align Discount,
   * ListPrice, Final_Adjusted_Price, and mid-month start dates from pre-curtail source terms;
   * carry forward last month.
   */
  public static void applyToReplacementLine(
    Id replacementOrderItemId,
    Id replacedOrderItemId,
    Date replaceStart
  ) {
    applyToReplacementLine(
      replacementOrderItemId,
      replaceStart,
      snapshotTermsFromOrderItem(replacedOrderItemId, replaceStart)
    );
  }

  public static void applyToReplacementLine(
    Id replacementOrderItemId,
    Date replaceStart,
    List<MonthTerm> sourceTerms
  ) {
    if (
      replacementOrderItemId == null ||
      replaceStart == null ||
      sourceTerms == null ||
      sourceTerms.isEmpty()
    ) {
      return;
    }

    // Room replace already spends most of the sync SOQL budget (curtail, payment
    // gen, date-sync flows). Finish transfer terms in a fresh transaction.
    if (Limits.getQueries() >= 50) {
      System.enqueueJob(
        new TransferPriceApplyQueueable(
          replacementOrderItemId,
          replaceStart,
          sourceTerms
        )
      );
      return;
    }

    Date fromMonth = monthStartOf(replaceStart);

    List<MonthlyPayment__c> targetPayments = [
      SELECT
        Id,
        OrderItem__c,
        Discount__c,
        ListPrice__c,
        Final_Adjusted_Price__c,
        Access_Type__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :replacementOrderItemId
      ORDER BY Stat_Date_Trigger__c ASC NULLS LAST, MonthIndex__c ASC
    ];
    if (targetPayments.isEmpty()) {
      return;
    }

    Map<Date, MonthTerm> byMonth = indexByMonth(sourceTerms);
    MonthTerm lastTerm = sourceTerms[sourceTerms.size() - 1];
    Date lastSourceMonth = lastTerm.monthStart;

    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c mp : targetPayments) {
      Date mpMonth = monthStartOf(mp.Stat_Date_Trigger__c);
      if (mpMonth == null || mpMonth < fromMonth) {
        continue;
      }
      MonthTerm term = byMonth.containsKey(mpMonth)
        ? byMonth.get(mpMonth)
        : (mpMonth > lastSourceMonth ? lastTerm : null);
      if (term == null) {
        continue;
      }
      mp.Discount__c = term.discount;
      mp.ListPrice__c = term.listPrice;
      if (mpMonth == fromMonth && replaceStart.day() > 1) {
        mp.Stat_Date_Trigger__c = replaceStart;
        mp.End_Date_trigger__c = lastDayOfMonth(replaceStart);
      }
      Decimal newUnits = PackageBuilderService.monthlyUnitsForAccessAndDates(
        mp.Access_Type__c,
        mp.Stat_Date_Trigger__c,
        mp.End_Date_trigger__c
      );
      mp.Final_Adjusted_Price__c = PackageBuilderService.scaleFinalAdjustedPrice(
        term.finalAdjustedPrice,
        term.monthlyUnits,
        newUnits
      );
      toUpdate.add(mp);
    }
    if (!toUpdate.isEmpty()) {
      commitPaymentTermUpdates(toUpdate, new Set<Id>{ replacementOrderItemId });
    }
  }

  /**
   * After the replaced line is curtailed: scale the overlap month FAP from the
   * pre-curtail snapshot (full-month commercial lock) onto the shortened span.
   */
  public static void scaleCurtailedLineToReplaceStart(
    Id curtailedOrderItemId,
    Date replaceStart,
    List<MonthTerm> sourceTerms
  ) {
    if (
      curtailedOrderItemId == null ||
      replaceStart == null ||
      sourceTerms == null ||
      sourceTerms.isEmpty()
    ) {
      return;
    }
    Date fromMonth = monthStartOf(replaceStart);
    MonthTerm term = indexByMonth(sourceTerms).get(fromMonth);
    if (term == null || term.finalAdjustedPrice == null) {
      return;
    }

    Date curtailedEnd = replaceStart.addDays(-1);
    OrderItem curtailedLine = [
      SELECT Access_Type__c
      FROM OrderItem
      WHERE Id = :curtailedOrderItemId
      LIMIT 1
    ];
    List<MonthlyPayment__c> overlapPayments = [
      SELECT
        Id,
        Access_Type__c,
        Final_Adjusted_Price__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :curtailedOrderItemId
    ];
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c mp : overlapPayments) {
      if (monthStartOf(mp.Stat_Date_Trigger__c) != fromMonth) {
        continue;
      }
      Boolean changed = false;
      if (
        mp.End_Date_trigger__c == null ||
        mp.End_Date_trigger__c > curtailedEnd
      ) {
        mp.End_Date_trigger__c = curtailedEnd;
        changed = true;
      }
      String accessType = String.isNotBlank(mp.Access_Type__c)
        ? mp.Access_Type__c
        : curtailedLine.Access_Type__c;
      Decimal scaledFap = PackageBuilderService.scaleFinalAdjustedPrice(
        term.finalAdjustedPrice,
        term.monthlyUnits,
        PackageBuilderService.monthlyUnitsForAccessAndDates(
          accessType,
          mp.Stat_Date_Trigger__c,
          mp.End_Date_trigger__c
        )
      );
      if (mp.Final_Adjusted_Price__c != scaledFap) {
        mp.Final_Adjusted_Price__c = scaledFap;
        changed = true;
      }
      if (changed) {
        toUpdate.add(mp);
      }
    }
    if (!toUpdate.isEmpty()) {
      commitPaymentTermUpdates(toUpdate, new Set<Id>{ curtailedOrderItemId });
    }
  }

  /**
   * Snapshot of replacement terms for undo map-back, plus which parents had Transfer Price.
   * Blank/false Transfer_Price__c → Discount-only map-back; true → Discount + ListPrice + FAP.
   */
  public class ParentTermSnapshot {
    public Map<Id, List<MonthTerm>> termsByParentId = new Map<Id, List<MonthTerm>>();
    public Set<Id> transferPriceParentIds = new Set<Id>();
  }

  /**
   * Snapshot replacement-line terms keyed by replaced (parent) OrderItem Id.
   * Call before hard-deleting replacement payments.
   * Pass Transfer_Price__c on replacement lines when available.
   */
  public static ParentTermSnapshot snapshotTermsByReplacedParent(
    List<OrderItem> replacementLines
  ) {
    ParentTermSnapshot out = new ParentTermSnapshot();
    if (replacementLines == null || replacementLines.isEmpty()) {
      return out;
    }
    Set<Id> replacementIds = new Set<Id>();
    Map<Id, Id> replacementToParent = new Map<Id, Id>();
    Map<Id, Date> fromMonthByReplacement = new Map<Id, Date>();
    Set<Id> transferPriceReplacementIds = new Set<Id>();
    for (OrderItem oi : replacementLines) {
      if (oi == null || oi.Id == null || oi.Replaced_Order_Product__c == null) {
        continue;
      }
      replacementIds.add(oi.Id);
      replacementToParent.put(oi.Id, oi.Replaced_Order_Product__c);
      if (oi.ServiceDate != null) {
        fromMonthByReplacement.put(oi.Id, monthStartOf(oi.ServiceDate));
      }
      // Only explicit true is full transfer; blank/false → Discount-only on undo.
      if (oi.Transfer_Price__c == true) {
        transferPriceReplacementIds.add(oi.Id);
      }
    }
    if (replacementIds.isEmpty()) {
      return out;
    }

    Map<Id, List<MonthTerm>> termsByReplacement = new Map<Id, List<MonthTerm>>();
    for (MonthlyPayment__c mp : [
      SELECT
        OrderItem__c,
        Discount__c,
        ListPrice__c,
        Final_Adjusted_Price__c,
        Access_Type__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :replacementIds
      ORDER BY Stat_Date_Trigger__c ASC NULLS LAST, MonthIndex__c ASC
    ]) {
      Date fromMonth = fromMonthByReplacement.get(mp.OrderItem__c);
      Date mpMonth = monthStartOf(mp.Stat_Date_Trigger__c);
      if (fromMonth == null || mpMonth == null || mpMonth < fromMonth) {
        continue;
      }
      if (!termsByReplacement.containsKey(mp.OrderItem__c)) {
        termsByReplacement.put(mp.OrderItem__c, new List<MonthTerm>());
      }
      MonthTerm t = new MonthTerm();
      t.monthStart = mpMonth;
      t.discount = mp.Discount__c;
      t.listPrice = mp.ListPrice__c;
      t.finalAdjustedPrice = mp.Final_Adjusted_Price__c;
      t.monthlyUnits = PackageBuilderService.monthlyUnitsForAccessAndDates(
        mp.Access_Type__c,
        mp.Stat_Date_Trigger__c,
        mp.End_Date_trigger__c
      );
      termsByReplacement.get(mp.OrderItem__c).add(t);
    }

    for (Id replacementId : termsByReplacement.keySet()) {
      Id parentId = replacementToParent.get(replacementId);
      if (parentId == null) {
        continue;
      }
      out.termsByParentId.put(parentId, termsByReplacement.get(replacementId));
      if (transferPriceReplacementIds.contains(replacementId)) {
        out.transferPriceParentIds.add(parentId);
      }
    }
    return out;
  }

  /**
   * After parent end-date restore + payment sync: apply terms by calendar month.
   * Transfer Price parents: Discount + ListPrice + FAP.
   * Non-transfer / blank: Discount only; clear FAP so Calculated Price follows parent Price.
   * Does not overwrite payment date spans (parent rebuild owns dates).
   */
  public static void applyMapBackToParents(ParentTermSnapshot snapshot) {
    if (
      snapshot == null ||
      snapshot.termsByParentId == null ||
      snapshot.termsByParentId.isEmpty()
    ) {
      return;
    }
    applyMapBackToParents(
      snapshot.termsByParentId,
      snapshot.transferPriceParentIds != null
        ? snapshot.transferPriceParentIds
        : new Set<Id>()
    );
  }

  public static void applyMapBackToParents(
    Map<Id, List<MonthTerm>> termsByParentId
  ) {
    applyMapBackToParents(termsByParentId, new Set<Id>());
  }

  public static void applyMapBackToParents(
    Map<Id, List<MonthTerm>> termsByParentId,
    Set<Id> transferPriceParentIds
  ) {
    if (termsByParentId == null || termsByParentId.isEmpty()) {
      return;
    }
    Set<Id> fullTransferParents = transferPriceParentIds != null
      ? transferPriceParentIds
      : new Set<Id>();
    Set<Id> parentIds = termsByParentId.keySet();
    List<MonthlyPayment__c> parentPayments = [
      SELECT
        Id,
        OrderItem__c,
        Discount__c,
        ListPrice__c,
        Final_Adjusted_Price__c,
        Access_Type__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :parentIds
      ORDER BY Stat_Date_Trigger__c ASC NULLS LAST, MonthIndex__c ASC
    ];
    if (parentPayments.isEmpty()) {
      return;
    }

    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (MonthlyPayment__c mp : parentPayments) {
      List<MonthTerm> terms = termsByParentId.get(mp.OrderItem__c);
      if (terms == null || terms.isEmpty()) {
        continue;
      }
      Date mpMonth = monthStartOf(mp.Stat_Date_Trigger__c);
      if (mpMonth == null) {
        continue;
      }
      Map<Date, MonthTerm> byMonth = indexByMonth(terms);
      MonthTerm lastTerm = terms[terms.size() - 1];
      Date firstMonth = terms[0].monthStart;
      if (mpMonth < firstMonth) {
        continue;
      }
      MonthTerm term = byMonth.containsKey(mpMonth)
        ? byMonth.get(mpMonth)
        : (mpMonth > lastTerm.monthStart ? lastTerm : null);
      if (term == null) {
        continue;
      }
      Boolean fullTransfer = fullTransferParents.contains(mp.OrderItem__c);
      Boolean changed = false;
      if (mp.Discount__c != term.discount) {
        mp.Discount__c = term.discount;
        changed = true;
      }
      if (fullTransfer) {
        if (mp.ListPrice__c != term.listPrice) {
          mp.ListPrice__c = term.listPrice;
          changed = true;
        }
        Decimal scaledFap = PackageBuilderService.scaleFinalAdjustedPrice(
          term.finalAdjustedPrice,
          term.monthlyUnits,
          PackageBuilderService.monthlyUnitsForAccessAndDates(
            mp.Access_Type__c,
            mp.Stat_Date_Trigger__c,
            mp.End_Date_trigger__c
          )
        );
        if (mp.Final_Adjusted_Price__c != scaledFap) {
          mp.Final_Adjusted_Price__c = scaledFap;
          changed = true;
        }
      } else if (mp.Final_Adjusted_Price__c != null) {
        // Discount-only undo: drop child FAP so FinalPrice uses parent Price × (1+Discount).
        mp.Final_Adjusted_Price__c = null;
        changed = true;
      }
      if (changed) {
        toUpdate.add(mp);
      }
    }
    if (!toUpdate.isEmpty()) {
      commitPaymentTermUpdates(toUpdate, parentIds);
    }
  }

  /**
   * Persist Discount/ListPrice/FAP (and optional mid-month dates) without firing
   * MonthlyPaymentTriggerHandler mid-DML — that path updates OrderItem Aggregated_*
   * and re-enters the date-sync flow, which stacks SOQL on long Periodic replaces.
   * Recompute Aggregated_* once, then Adjusted_Total_Price rollup (same end state).
   */
  private static void commitPaymentTermUpdates(
    List<MonthlyPayment__c> toUpdate,
    Set<Id> orderItemIdsForRollup
  ) {
    TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
    try {
      update toUpdate;
    } finally {
      TriggerHandler.clearBypass('MonthlyPaymentTriggerHandler');
    }
    MonthlyPaymentService.updateAggregatedPriceAdjustmentForOrderItem(
      new Map<Id, MonthlyPayment__c>(toUpdate)
    );
    if (orderItemIdsForRollup != null && !orderItemIdsForRollup.isEmpty()) {
      PackageBuilderService.syncOrderItemPriceRollups(orderItemIdsForRollup);
    }
  }

  @TestVisible
  private static List<MonthTerm> loadTermsForOrderItem(
    Id orderItemId,
    Date fromMonth
  ) {
    List<MonthTerm> terms = new List<MonthTerm>();
    if (orderItemId == null || fromMonth == null) {
      return terms;
    }
    for (MonthlyPayment__c mp : [
      SELECT
        Discount__c,
        ListPrice__c,
        Final_Adjusted_Price__c,
        Access_Type__c,
        Stat_Date_Trigger__c,
        End_Date_trigger__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c = :orderItemId
      ORDER BY Stat_Date_Trigger__c ASC NULLS LAST, MonthIndex__c ASC
    ]) {
      Date mpMonth = monthStartOf(mp.Stat_Date_Trigger__c);
      if (mpMonth == null || mpMonth < fromMonth) {
        continue;
      }
      MonthTerm t = new MonthTerm();
      t.monthStart = mpMonth;
      t.discount = mp.Discount__c;
      t.listPrice = mp.ListPrice__c;
      t.finalAdjustedPrice = mp.Final_Adjusted_Price__c;
      t.monthlyUnits = PackageBuilderService.monthlyUnitsForAccessAndDates(
        mp.Access_Type__c,
        mp.Stat_Date_Trigger__c,
        mp.End_Date_trigger__c
      );
      terms.add(t);
    }
    return terms;
  }

  private static Map<Date, MonthTerm> indexByMonth(List<MonthTerm> terms) {
    Map<Date, MonthTerm> byMonth = new Map<Date, MonthTerm>();
    if (terms == null) {
      return byMonth;
    }
    for (MonthTerm t : terms) {
      if (t != null && t.monthStart != null) {
        byMonth.put(t.monthStart, t);
      }
    }
    return byMonth;
  }

  @TestVisible
  private static Date monthStartOf(Date d) {
    return d == null ? null : Date.newInstance(d.year(), d.month(), 1);
  }

  private static Date lastDayOfMonth(Date d) {
    if (d == null) {
      return null;
    }
    Date firstNext = Date.newInstance(d.year(), d.month(), 1).addMonths(1);
    return firstNext.addDays(-1);
  }
}
