/**
 * Domain service for recurring price-increase rules on OLI / OrderItem.
 * Saves/disables/removes rules, projects a Final-chain onto existing
 * Monthly Payments, and exposes consult helpers for MP create/top-up.
 */
public with sharing class RecurringPriceIncreaseService {
  public static final String TYPE_PERCENT = 'Increase_by_Percentage';
  public static final String TYPE_VALUE = 'Increase_by_Value';
  /** Prefix on AuraHandledException when save needs UI confirm for iteration overlap. */
  public static final String CONFIRM_ITERATION_OVERLAP = 'CONFIRM_ITERATION_OVERLAP';

  public class RuleDraft {
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
  }

  public class SaveResult {
    @AuraEnabled
    public Integer updatedLines;
    @AuraEnabled
    public Integer updatedPayments;
    @AuraEnabled
    public Integer skippedIneligible;
    @AuraEnabled
    public String message;
    @AuraEnabled
    public List<String> skippedMessages;
  }

  public class OverlapPreviewRow {
    @AuraEnabled
    public Id lineId;
    @AuraEnabled
    public String productName;
    @AuraEnabled
    public Date overlapMonth;
    @AuraEnabled
    public Id iterationId;
    @AuraEnabled
    public Decimal listPrice;
    @AuraEnabled
    public Decimal afterIteration;
    @AuraEnabled
    public Decimal afterRecurring;
    @AuraEnabled
    public Decimal afterUser;
    @AuraEnabled
    public Decimal finalPrice;
    @AuraEnabled
    public Decimal userAdjustment;
  }

  public class OverlapPreviewResult {
    @AuraEnabled
    public Boolean hasOverlap;
    @AuraEnabled
    public List<OverlapPreviewRow> rows;
    @AuraEnabled
    public String message;
  }

  /**
   * Persist rule fields only. Does not enable (unless already enabled) and does not
   * rewrite monthly payments. New lines stay disabled until enableAndApplyRules.
   */
  public static SaveResult saveRuleFields(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived
  ) {
    return persistRule(lineIds, draft, isArchived, false, false, false);
  }

  /**
   * Enable the rule without projecting monthly payments.
   */
  public static SaveResult enableRules(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived
  ) {
    return persistRule(lineIds, draft, isArchived, false, false, true);
  }

  /**
   * Enable the rule and project monthly payments from the effective start forward.
   * Always re-projects eligible lines (even when rule fields unchanged).
   * Without confirm, throws when a recurring step month overlaps an Iteration period start.
   */
  public static SaveResult enableAndApplyRules(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived
  ) {
    return enableAndApplyRules(lineIds, draft, isArchived, false);
  }

  public static SaveResult enableAndApplyRules(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived,
    Boolean confirmOverlap
  ) {
    return persistRule(
      lineIds,
      draft,
      isArchived,
      true,
      confirmOverlap == true,
      false
    );
  }

  /** Delegates to enableAndApplyRules for backward compatibility. */
  public static SaveResult saveRules(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived
  ) {
    return enableAndApplyRules(lineIds, draft, isArchived, false);
  }

  public static SaveResult saveRules(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived,
    Boolean confirmOverlap
  ) {
    return enableAndApplyRules(
      lineIds,
      draft,
      isArchived,
      confirmOverlap == true
    );
  }

  private static SaveResult persistRule(
    List<Id> lineIds,
    RuleDraft draft,
    Boolean isArchived,
    Boolean enableAndApply,
    Boolean confirmOverlap,
    Boolean enableOnly
  ) {
    clearLineCache();
    SaveResult result = emptyResult();
    if (lineIds == null || lineIds.isEmpty()) {
      throw new AuraHandledException('Select at least one product.');
    }
    if (isArchived == true) {
      throw new AuraHandledException(
        'Recurring price increase cannot be edited on archived orders.'
      );
    }
    if (draft == null) {
      throw new AuraHandledException(
        'A recurring price increase rule is required.'
      );
    }

    String increaseType = normalizeIncreaseType(draft.increaseType);
    validateDraft(draft, increaseType);

    LineBundle bundle = loadLines(new Set<Id>(lineIds));
    assertNotTerminatedOrDeleted(bundle);

    if (enableAndApply) {
      OverlapPreviewResult overlapPreview = buildOverlapPreview(
        bundle,
        draft,
        increaseType,
        Date.today()
      );
      if (overlapPreview.hasOverlap == true && confirmOverlap != true) {
        throw new AuraHandledException(
          CONFIRM_ITERATION_OVERLAP +
          ': A recurring step falls in the same month as an Iteration period start. Confirm to apply.'
        );
      }
    }

    Date today = Date.today();
    List<SObject> parentUpdates = new List<SObject>();
    Map<Id, LineContext> contextsById = new Map<Id, LineContext>();

    for (Id lineId : lineIds) {
      LineContext ctx = bundle.byId.get(lineId);
      if (ctx == null) {
        continue;
      }
      if (!isEligibleAccessType(ctx.accessType)) {
        result.skippedIneligible++;
        String name = String.isBlank(ctx.productName)
          ? String.valueOf(lineId)
          : ctx.productName;
        result.skippedMessages.add(
          name +
          ' skipped: recurring price increase applies only to Monthly and Periodic products.'
        );
        continue;
      }

      Date minStart = maxDate(today, ctx.contractStart);
      if (draft.startDate == null || draft.startDate < minStart) {
        throw new AuraHandledException(
          'Start date must be on or after ' +
            String.valueOf(minStart) +
            ' (max of today and contract/opportunity start).'
        );
      }

      Date effectiveStart = resolveEffectiveStart(
        draft.startDate,
        ctx.serviceDate,
        ctx.contractStart
      );
      Decimal basePrice = lineBasePrice(ctx);

      SObject parent = ctx.isOrderItem
        ? (SObject) new OrderItem(Id = lineId)
        : (SObject) new OpportunityLineItem(Id = lineId);
      Boolean enabledFlag = enableAndApply || enableOnly == true
        ? true
        : (ctx.enabled == true);
      parent.put('Recurring_Price_Increase_Enabled__c', enabledFlag);
      parent.put(
        'Recurring_Increase_Frequency_Months__c',
        draft.frequencyMonths
      );
      parent.put('Recurring_Increase_Start_Date__c', draft.startDate);
      parent.put('Recurring_Increase_Type__c', increaseType);
      parent.put(
        'Recurring_Increase_Percent__c',
        increaseType == TYPE_PERCENT ? draft.increasePercent : null
      );
      parent.put(
        'Recurring_Increase_Amount__c',
        increaseType == TYPE_VALUE ? draft.increaseAmount : null
      );
      parentUpdates.add(parent);

      ctx.effectiveStart = effectiveStart;
      ctx.basePrice = basePrice;
      ctx.frequencyMonths = draft.frequencyMonths;
      ctx.increaseType = increaseType;
      ctx.increasePercent = draft.increasePercent;
      ctx.increaseAmount = draft.increaseAmount;
      result.updatedLines++;
      if (enableAndApply) {
        contextsById.put(lineId, ctx);
      }
    }

    if (!parentUpdates.isEmpty()) {
      update parentUpdates;
    }

    result.updatedPayments = contextsById.isEmpty()
      ? 0
      : projectMonthlyPayments(contextsById, today);
    result.message = enableAndApply
      ? buildApplyMessage(result)
      : enableOnly == true
          ? buildEnableMessage(result)
          : buildFieldsSaveMessage(result);
    return result;
  }

  /** Disable: Enabled=false, keep values, leave MPs unchanged. */
  public static SaveResult disableRules(List<Id> lineIds, Boolean isArchived) {
    return mutateEnabled(lineIds, isArchived, false, false);
  }

  /** Remove: Enabled=false, clear rule values, leave MPs unchanged. */
  public static SaveResult removeRules(List<Id> lineIds, Boolean isArchived) {
    return mutateEnabled(lineIds, isArchived, false, true);
  }

  /** Request-scoped line contexts for bulk MP create/top-up consult. */
  private static Map<Id, LineContext> lineContextById;
  /** Cached MPs by line for Final-chain consult (avoid N+1 on bulk create). */
  private static Map<Id, List<MonthlyPayment__c>> paymentsCacheByLineId;

  /**
   * Preload line rule contexts so repeated resolveDiscount calls avoid N+1 SOQL.
   * Call from MP generation / top-up entry points (legacy populateOrderItemRenewalIntervals seam).
   */
  public static void preloadLines(Set<Id> lineIds) {
    if (lineIds == null || lineIds.isEmpty()) {
      return;
    }
    LineBundle bundle = loadLines(lineIds);
    if (lineContextById == null) {
      lineContextById = new Map<Id, LineContext>();
    }
    lineContextById.putAll(bundle.byId);
    ensurePaymentsCached(lineIds);
  }

  @TestVisible
  private static void clearLineCache() {
    lineContextById = null;
    paymentsCacheByLineId = null;
  }

  /**
   * Consult helper for MP create/rebuild paths (T2.3).
   * Final-chain: target = one step off prior MP Final (or carry), no today floor
   * on effective start. userPriceAdjustment kept for API compat but ignored.
   * Returns Discount__c in percent-points (e.g. 10 means +10%), or null when
   * no active rule applies.
   */
  public static Decimal resolveDiscount(
    Id lineId,
    Date monthStart,
    Decimal userPriceAdjustment
  ) {
    if (lineId == null || monthStart == null) {
      return null;
    }
    LineContext ctx = lineContextById != null
      ? lineContextById.get(lineId)
      : null;
    if (ctx == null) {
      LineBundle bundle = loadLines(new Set<Id>{ lineId });
      ctx = bundle.byId.get(lineId);
      if (ctx != null) {
        if (lineContextById == null) {
          lineContextById = new Map<Id, LineContext>();
        }
        lineContextById.put(lineId, ctx);
      }
    }
    if (ctx == null || ctx.enabled != true) {
      return null;
    }
    if (!isEligibleAccessType(ctx.accessType)) {
      return null;
    }
    Date effectiveStart = resolveEffectiveStart(
      ctx.ruleStartDate,
      ctx.serviceDate,
      ctx.contractStart
    );
    if (effectiveStart == null) {
      return null;
    }
    Date month = monthStart.toStartOfMonth();
    Date startMonth = effectiveStart.toStartOfMonth();
    if (month < startMonth) {
      return null;
    }
    if (
      ctx.frequencyMonths == null ||
      ctx.frequencyMonths <= 0 ||
      String.isBlank(ctx.increaseType)
    ) {
      return null;
    }

    Decimal basePrice = lineBasePrice(ctx);
    Decimal priorFinal = priorFinalBeforeMonth(lineId, month, basePrice);
    Decimal targetFinal = priorFinal;
    if (isRecurringStepMonth(month, effectiveStart, ctx.frequencyMonths)) {
      targetFinal = applyOneRecurringStep(
        priorFinal,
        ctx.increaseType,
        ctx.increasePercent,
        ctx.increaseAmount
      );
    }
    // New MPs often have no Price__c yet — use list/unit as basis.
    Decimal discount = discountForMonthlyPaymentStorage(basePrice, targetFinal);
    // Remember for later months in the same request (bulk generate before insert).
    rememberConsultResult(lineId, month, basePrice, targetFinal, discount);
    return discount;
  }

  /**
   * Pure math: Discount__c percent-points for a month under a known rule.
   * Kept for overlap/math callers; applies list staircase then optional user layer.
   */
  public static Decimal resolveDiscountFromRule(
    Decimal basePrice,
    Date monthStart,
    Date effectiveStart,
    Integer frequencyMonths,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    Decimal userPriceAdjustment
  ) {
    if (
      basePrice == null ||
      basePrice == 0 ||
      monthStart == null ||
      effectiveStart == null ||
      frequencyMonths == null ||
      frequencyMonths <= 0
    ) {
      return null;
    }
    Date month = monthStart.toStartOfMonth();
    Date startMonth = effectiveStart.toStartOfMonth();
    if (month < startMonth) {
      return null;
    }
    Decimal commercial = commercialAt(
      basePrice,
      effectiveStart,
      frequencyMonths,
      increaseType,
      increasePercent,
      increaseAmount,
      month
    );
    Decimal userFrac = toFraction(userPriceAdjustment);
    Decimal finalPrice = (commercial * (1 + userFrac)).setScale(6);
    return discountFromBasis(basePrice, finalPrice);
  }

  /**
   * Package Builder MP grid save hook (T2.5).
   * When an active recurring rule applies to that month: keep the user's
   * incoming Discount__c as-is and optionally stamp User_Price_Adjustment__c
   * for bookkeeping. Do not rewrite Discount from a commercial/user split.
   * When no rule applies: leave Discount__c as sent (legacy behavior).
   */
  public static void applyUserLayerFromGridEdits(
    List<MonthlyPayment__c> payments
  ) {
    if (payments == null || payments.isEmpty()) {
      return;
    }
    Set<Id> paymentIds = new Set<Id>();
    for (MonthlyPayment__c p : payments) {
      if (p != null && p.Id != null && p.Discount__c != null) {
        paymentIds.add(p.Id);
      }
    }
    if (paymentIds.isEmpty()) {
      return;
    }

    Map<Id, MonthlyPayment__c> existingById = new Map<Id, MonthlyPayment__c>(
      [
        SELECT
          Id,
          OrderItem__c,
          OpportunityLineItem__c,
          Start_date__c,
          Stat_Date_Trigger__c,
          User_Price_Adjustment__c
        FROM MonthlyPayment__c
        WHERE Id IN :paymentIds
      ]
    );

    Set<Id> lineIds = new Set<Id>();
    for (MonthlyPayment__c row : existingById.values()) {
      if (row.OrderItem__c != null) {
        lineIds.add(row.OrderItem__c);
      } else if (row.OpportunityLineItem__c != null) {
        lineIds.add(row.OpportunityLineItem__c);
      }
    }
    if (!lineIds.isEmpty()) {
      preloadLines(lineIds);
    }

    for (MonthlyPayment__c incoming : payments) {
      if (
        incoming == null ||
        incoming.Id == null ||
        incoming.Discount__c == null
      ) {
        continue;
      }
      MonthlyPayment__c existing = existingById.get(incoming.Id);
      if (existing == null) {
        continue;
      }
      Id lineId = existing.OrderItem__c != null
        ? existing.OrderItem__c
        : existing.OpportunityLineItem__c;
      if (lineId == null) {
        continue;
      }
      Date monthStart = existing.Start_date__c != null
        ? existing.Start_date__c.toStartOfMonth()
        : (existing.Stat_Date_Trigger__c == null
            ? null
            : existing.Stat_Date_Trigger__c.toStartOfMonth());
      if (monthStart == null) {
        continue;
      }

      Decimal ruleDiscount = resolveDiscount(lineId, monthStart, 0);
      if (ruleDiscount == null) {
        continue;
      }
      // Keep user edit; bookkeeping only.
      incoming.User_Price_Adjustment__c = incoming.Discount__c;
    }
  }

  /**
   * Preview dual-increase months where a recurring step shares a calendar month
   * with an Iteration Period_Start_Date__c (non-Completed, non-blank increase type).
   * Math order: latest commercial → Iteration → recurring step → user layer → final.
   */
  public static OverlapPreviewResult previewIterationOverlap(
    List<Id> lineIds,
    RuleDraft draft
  ) {
    clearLineCache();
    OverlapPreviewResult empty = new OverlapPreviewResult();
    empty.hasOverlap = false;
    empty.rows = new List<OverlapPreviewRow>();
    empty.message = '';
    if (lineIds == null || lineIds.isEmpty() || draft == null) {
      return empty;
    }
    String increaseType = normalizeIncreaseType(draft.increaseType);
    validateDraft(draft, increaseType);
    LineBundle bundle = loadLines(new Set<Id>(lineIds));
    return buildOverlapPreview(bundle, draft, increaseType, Date.today());
  }

  /** True when monthStart is on the recurring staircase (start + k*N months). */
  public static Boolean isRecurringStepMonth(
    Date monthStart,
    Date effectiveStart,
    Integer frequencyMonths
  ) {
    if (
      monthStart == null ||
      effectiveStart == null ||
      frequencyMonths == null ||
      frequencyMonths <= 0
    ) {
      return false;
    }
    Date month = monthStart.toStartOfMonth();
    Date startMonth = effectiveStart.toStartOfMonth();
    if (month < startMonth) {
      return false;
    }
    Integer monthsBetween =
      (month.year() - startMonth.year()) * 12 +
      (month.month() - startMonth.month());
    return Math.mod(monthsBetween, frequencyMonths) == 0;
  }

  /** Apply one Iteration increase to a basis (mirrors IterationAutoRenewService). */
  public static Decimal applyIterationIncrease(
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    Decimal finalPrice,
    Decimal basis
  ) {
    Decimal working = basis == null ? 0 : basis;
    String type = IterationService.normalizeIncreaseType(increaseType);
    if (String.isBlank(type)) {
      return working.setScale(2);
    }
    if (type == IterationService.TYPE_FINAL) {
      return (finalPrice == null ? working : finalPrice).setScale(2);
    }
    if (type == IterationService.TYPE_VALUE) {
      Decimal amount = increaseAmount == null ? 0 : increaseAmount;
      return (working + amount).setScale(2);
    }
    if (type == IterationService.TYPE_PERCENT) {
      if (working == 0) {
        return 0;
      }
      Decimal pct = toFraction(increasePercent);
      return (working * (1 + pct)).setScale(2);
    }
    return working.setScale(2);
  }

  /** One recurring step from a latest commercial price (not re-based from list). */
  public static Decimal applyOneRecurringStep(
    Decimal latestPrice,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount
  ) {
    Decimal latest = latestPrice == null ? 0 : latestPrice;
    String type = normalizeIncreaseType(increaseType);
    if (type == TYPE_VALUE) {
      Decimal amount = increaseAmount == null ? 0 : increaseAmount;
      return (latest + amount).setScale(2);
    }
    Decimal pct = toFraction(increasePercent);
    return (latest * (1 + pct)).setScale(2);
  }

  /**
   * Undo one recurring step (for rebuild: recover pre-rule Final on start month).
   */
  public static Decimal reverseOneRecurringStep(
    Decimal steppedPrice,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount
  ) {
    if (steppedPrice == null) {
      return null;
    }
    String type = normalizeIncreaseType(increaseType);
    if (String.isBlank(type)) {
      return steppedPrice;
    }
    if (type == TYPE_VALUE) {
      Decimal amount = increaseAmount == null ? 0 : increaseAmount;
      return (steppedPrice - amount).setScale(2);
    }
    Decimal pct = toFraction(increasePercent);
    if (pct <= -1) {
      return steppedPrice;
    }
    return (steppedPrice / (1 + pct)).setScale(2);
  }

  /**
   * Effective start = max(chosenStart, lineServiceDate, contractStart).
   * No today floor (consult / projection after start validation).
   */
  public static Date resolveEffectiveStart(
    Date chosenStart,
    Date lineServiceDate,
    Date contractStart
  ) {
    return resolveEffectiveStart(
      chosenStart,
      lineServiceDate,
      contractStart,
      null
    );
  }

  /**
   * Effective start = max(chosenStart, lineServiceDate, floor).
   * Floor is max(today, contractStart) when today is non-null; otherwise contractStart only.
   */
  public static Date resolveEffectiveStart(
    Date chosenStart,
    Date lineServiceDate,
    Date contractStart,
    Date today
  ) {
    Date floor = today == null ? contractStart : maxDate(today, contractStart);
    return maxDate(chosenStart, maxDate(lineServiceDate, floor));
  }

  public static Boolean isEligibleAccessType(String accessType) {
    if (String.isBlank(accessType)) {
      return false;
    }
    return PackageBuilderAccessTypePolicy.isMonthlyLike(accessType) ||
      PackageBuilderAccessTypePolicy.ACCESS_TYPE_PERIODIC.equalsIgnoreCase(
        accessType
      );
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
    return raw;
  }

  public static Date maxDate(Date a, Date b) {
    if (a == null) {
      return b;
    }
    if (b == null) {
      return a;
    }
    return a >= b ? a : b;
  }

  /**
   * Start month = step 1, then every N months.
   * Months before effective start return 0 (base price, no increase).
   */
  public static Integer stepCount(
    Date monthStart,
    Date effectiveStart,
    Integer frequencyMonths
  ) {
    if (
      monthStart == null ||
      effectiveStart == null ||
      frequencyMonths == null ||
      frequencyMonths <= 0
    ) {
      return 0;
    }
    Date month = monthStart.toStartOfMonth();
    Date startMonth = effectiveStart.toStartOfMonth();
    if (month < startMonth) {
      return 0;
    }
    Integer monthsBetween =
      (month.year() - startMonth.year()) * 12 +
      (month.month() - startMonth.month());
    return (monthsBetween / frequencyMonths) + 1;
  }

  public static Decimal commercialAt(
    Decimal basePrice,
    Date effectiveStart,
    Integer frequencyMonths,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    Date asOfMonth
  ) {
    Decimal base = basePrice == null ? 0 : basePrice;
    Integer steps = stepCount(asOfMonth, effectiveStart, frequencyMonths);
    if (steps <= 0) {
      return base.setScale(2);
    }
    String type = normalizeIncreaseType(increaseType);
    if (type == TYPE_VALUE) {
      Decimal amount = increaseAmount == null ? 0 : increaseAmount;
      return (base + (amount * steps)).setScale(2);
    }
    Decimal pct = toFraction(increasePercent);
    Decimal commercial = base;
    for (Integer i = 0; i < steps; i++) {
      commercial = commercial * (1 + pct);
    }
    return commercial.setScale(2);
  }

  public static Decimal discountFromBasis(Decimal basis, Decimal targetFinal) {
    if (basis == null || basis == 0 || targetFinal == null) {
      return 0;
    }
    return (((targetFinal / basis) - 1) * 100).setScale(6);
  }

  /**
   * Discount__c for MonthlyPayment DML, compatible with
   * PackageBuilderService.monthlyLinePayableAmount: |d| &lt; 1 is a fraction,
   * otherwise percent points / 100.
   */
  @TestVisible
  public static Decimal discountForMonthlyPaymentStorage(
    Decimal basis,
    Decimal targetFinal
  ) {
    if (basis == null || basis == 0 || targetFinal == null) {
      return 0;
    }
    Decimal fraction = ((targetFinal / basis) - 1).setScale(8);
    Decimal percentPoints = fraction * 100;
    if (percentPoints != 0 && Math.abs(percentPoints) < 1) {
      return fraction.setScale(6);
    }
    return percentPoints.setScale(6);
  }

  /**
   * After iteration auto-renew stamps new-period MPs, walk recurring step months from the
   * iteration target (renew month anchor) so recurring stacks on top of renewal pricing.
   */
  public static Integer stackRecurringAfterRenewalPricing(
    Map<Id, Decimal> iterationTargetByLine,
    Map<Id, Date> renewalStartByLine
  ) {
    if (
      iterationTargetByLine == null ||
      iterationTargetByLine.isEmpty() ||
      renewalStartByLine == null ||
      renewalStartByLine.isEmpty()
    ) {
      return 0;
    }
    Set<Id> lineIds = new Set<Id>();
    for (Id lineId : iterationTargetByLine.keySet()) {
      if (
        lineId != null &&
        renewalStartByLine.containsKey(lineId) &&
        renewalStartByLine.get(lineId) != null
      ) {
        lineIds.add(lineId);
      }
    }
    if (lineIds.isEmpty()) {
      return 0;
    }

    LineBundle bundle = loadLines(lineIds);
    List<MonthlyPayment__c> payments = [
      SELECT
        Id,
        OrderItem__c,
        Start_date__c,
        Stat_Date_Trigger__c,
        Discount__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :lineIds
    ];

    Map<Id, List<MonthlyPayment__c>> byLine = new Map<Id, List<MonthlyPayment__c>>();
    for (MonthlyPayment__c mp : payments) {
      if (mp.OrderItem__c == null) {
        continue;
      }
      if (!byLine.containsKey(mp.OrderItem__c)) {
        byLine.put(mp.OrderItem__c, new List<MonthlyPayment__c>());
      }
      byLine.get(mp.OrderItem__c).add(mp);
    }

    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    for (Id lineId : lineIds) {
      LineContext ctx = bundle.byId.get(lineId);
      if (
        ctx == null ||
        ctx.enabled != true ||
        !isEligibleAccessType(ctx.accessType)
      ) {
        continue;
      }
      Date renewalStart = renewalStartByLine.get(lineId).toStartOfMonth();
      Decimal iterationTarget = iterationTargetByLine.get(lineId);
      if (renewalStart == null || iterationTarget == null) {
        continue;
      }
      Date effectiveStart = resolveEffectiveStart(
        ctx.ruleStartDate,
        ctx.serviceDate,
        ctx.contractStart
      );
      if (
        effectiveStart == null ||
        ctx.frequencyMonths == null ||
        ctx.frequencyMonths <= 0 ||
        String.isBlank(ctx.increaseType)
      ) {
        continue;
      }
      Decimal listBase = lineBasePrice(ctx);
      List<MonthlyPayment__c> linePayments = byLine.get(lineId);
      if (linePayments == null || linePayments.isEmpty()) {
        continue;
      }
      linePayments.sort(new MonthlyPaymentMonthComparator());

      Decimal chainFinal = iterationTarget;
      for (MonthlyPayment__c mp : linePayments) {
        Date monthStart = paymentMonthStart(mp);
        if (monthStart == null || monthStart < renewalStart) {
          continue;
        }
        if (monthStart == renewalStart) {
          chainFinal = iterationTarget;
        } else if (
          isRecurringStepMonth(monthStart, effectiveStart, ctx.frequencyMonths)
        ) {
          chainFinal = applyOneRecurringStep(
            chainFinal,
            ctx.increaseType,
            ctx.increasePercent,
            ctx.increaseAmount
          );
        }
        toUpdate.add(
          new MonthlyPayment__c(
            Id = mp.Id,
            Discount__c = discountForMonthlyPaymentStorage(
              listBase,
              chainFinal
            ),
            Final_Adjusted_Price__c = chainFinal
          )
        );
      }
    }

    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
    return toUpdate.size();
  }

  public static Decimal toFraction(Decimal raw) {
    if (raw == null) {
      return 0;
    }
    return Math.abs(raw) > 1 ? (raw / 100) : raw;
  }

  private class LineContext {
    Id lineId;
    Boolean isOrderItem;
    String accessType;
    String productName;
    Date serviceDate;
    Date contractStart;
    Boolean isLineDeleted;
    String terminationReason;
    Boolean enabled;
    Date ruleStartDate;
    Integer frequencyMonths;
    String increaseType;
    Decimal increasePercent;
    Decimal increaseAmount;
    Decimal unitPrice;
    Decimal quantity;
    Decimal totalPrice;
    Date effectiveStart;
    Decimal basePrice;
  }

  private class LineBundle {
    Map<Id, LineContext> byId = new Map<Id, LineContext>();
  }

  private static OverlapPreviewResult buildOverlapPreview(
    LineBundle bundle,
    RuleDraft draft,
    String increaseType,
    Date today
  ) {
    OverlapPreviewResult result = new OverlapPreviewResult();
    result.hasOverlap = false;
    result.rows = new List<OverlapPreviewRow>();
    result.message = '';
    if (
      bundle == null ||
      draft == null ||
      bundle.byId == null ||
      bundle.byId.isEmpty()
    ) {
      return result;
    }

    Set<Id> parentIds = new Set<Id>(bundle.byId.keySet());
    Map<Id, List<Iteration__c>> iterationsByParent = loadActiveIterationsByParent(
      parentIds
    );
    Map<Id, Map<Date, Decimal>> userAdjByLineMonth = loadUserAdjustmentsByLineMonth(
      parentIds
    );

    for (Id lineId : parentIds) {
      LineContext ctx = bundle.byId.get(lineId);
      if (ctx == null || !isEligibleAccessType(ctx.accessType)) {
        continue;
      }
      List<Iteration__c> iterations = iterationsByParent.get(lineId);
      if (iterations == null || iterations.isEmpty()) {
        continue;
      }

      Date effectiveStart = resolveEffectiveStart(
        draft.startDate,
        ctx.serviceDate,
        ctx.contractStart,
        today
      );
      Decimal basePrice = lineBasePrice(ctx);

      for (Iteration__c row : iterations) {
        if (row.Period_Start_Date__c == null) {
          continue;
        }
        Date overlapMonth = row.Period_Start_Date__c.toStartOfMonth();
        if (
          !isRecurringStepMonth(
            overlapMonth,
            effectiveStart,
            draft.frequencyMonths
          )
        ) {
          continue;
        }

        Date priorMonth = overlapMonth.addMonths(-1);
        Decimal listPrice = commercialAt(
          basePrice,
          effectiveStart,
          draft.frequencyMonths,
          increaseType,
          draft.increasePercent,
          draft.increaseAmount,
          priorMonth
        );
        Decimal afterIteration = applyIterationIncrease(
          row.Increase_Type__c,
          row.Increase_Percent__c,
          row.Increase_Amount__c,
          row.Final_Price__c,
          listPrice
        );
        Decimal afterRecurring = applyOneRecurringStep(
          afterIteration,
          increaseType,
          draft.increasePercent,
          draft.increaseAmount
        );
        Decimal userAdj = 0;
        Map<Date, Decimal> byMonth = userAdjByLineMonth.get(lineId);
        if (byMonth != null && byMonth.containsKey(overlapMonth)) {
          userAdj = byMonth.get(overlapMonth);
        }
        Decimal userFrac = toFraction(userAdj);
        Decimal afterUser = (afterRecurring * (1 + userFrac)).setScale(2);

        OverlapPreviewRow previewRow = new OverlapPreviewRow();
        previewRow.lineId = lineId;
        previewRow.productName = ctx.productName;
        previewRow.overlapMonth = overlapMonth;
        previewRow.iterationId = row.Id;
        previewRow.listPrice = listPrice;
        previewRow.afterIteration = afterIteration;
        previewRow.afterRecurring = afterRecurring;
        previewRow.afterUser = afterUser;
        previewRow.finalPrice = afterUser;
        previewRow.userAdjustment = userAdj;
        result.rows.add(previewRow);
      }
    }

    result.hasOverlap = !result.rows.isEmpty();
    if (result.hasOverlap) {
      result.message =
        'Recurring step overlaps Iteration period start on ' +
        result.rows.size() +
        ' month(s). Iteration applies first, then recurring.';
    }
    return result;
  }

  private static Map<Id, List<Iteration__c>> loadActiveIterationsByParent(
    Set<Id> parentIds
  ) {
    Map<Id, List<Iteration__c>> byParent = new Map<Id, List<Iteration__c>>();
    if (parentIds == null || parentIds.isEmpty()) {
      return byParent;
    }
    for (Iteration__c row : [
      SELECT
        Id,
        Order_Product__c,
        Opportunity_Product__c,
        Period_Start_Date__c,
        Status__c,
        Increase_Type__c,
        Increase_Percent__c,
        Increase_Amount__c,
        Final_Price__c
      FROM Iteration__c
      WHERE
        (Order_Product__c IN :parentIds
        OR Opportunity_Product__c IN :parentIds)
        AND Status__c != :IterationService.STATUS_COMPLETED
        AND Increase_Type__c != NULL
    ]) {
      Id parentId = row.Order_Product__c != null
        ? row.Order_Product__c
        : row.Opportunity_Product__c;
      if (parentId == null || !parentIds.contains(parentId)) {
        continue;
      }
      if (String.isBlank(row.Increase_Type__c)) {
        continue;
      }
      if (!byParent.containsKey(parentId)) {
        byParent.put(parentId, new List<Iteration__c>());
      }
      byParent.get(parentId).add(row);
    }
    return byParent;
  }

  private static Map<Id, Map<Date, Decimal>> loadUserAdjustmentsByLineMonth(
    Set<Id> parentIds
  ) {
    Map<Id, Map<Date, Decimal>> byLine = new Map<Id, Map<Date, Decimal>>();
    if (parentIds == null || parentIds.isEmpty()) {
      return byLine;
    }
    for (MonthlyPayment__c mp : [
      SELECT
        OrderItem__c,
        OpportunityLineItem__c,
        Start_Date__c,
        Stat_Date_Trigger__c,
        User_Price_Adjustment__c
      FROM MonthlyPayment__c
      WHERE OrderItem__c IN :parentIds OR OpportunityLineItem__c IN :parentIds
    ]) {
      Id lineId = mp.OrderItem__c != null
        ? mp.OrderItem__c
        : mp.OpportunityLineItem__c;
      if (lineId == null) {
        continue;
      }
      Date monthStart = mp.Start_Date__c != null
        ? mp.Start_Date__c.toStartOfMonth()
        : (mp.Stat_Date_Trigger__c == null
            ? null
            : mp.Stat_Date_Trigger__c.toStartOfMonth());
      if (monthStart == null) {
        continue;
      }
      if (!byLine.containsKey(lineId)) {
        byLine.put(lineId, new Map<Date, Decimal>());
      }
      byLine.get(lineId)
        .put(
          monthStart,
          mp.User_Price_Adjustment__c == null ? 0 : mp.User_Price_Adjustment__c
        );
    }
    return byLine;
  }

  private static SaveResult emptyResult() {
    SaveResult result = new SaveResult();
    result.updatedLines = 0;
    result.updatedPayments = 0;
    result.skippedIneligible = 0;
    result.skippedMessages = new List<String>();
    result.message = '';
    return result;
  }

  private static void validateDraft(RuleDraft draft, String increaseType) {
    if (draft.frequencyMonths == null || draft.frequencyMonths <= 0) {
      throw new AuraHandledException(
        'Frequency must be a positive whole number of months.'
      );
    }
    if (String.isBlank(increaseType)) {
      throw new AuraHandledException('Increase type is required.');
    }
    if (increaseType != TYPE_PERCENT && increaseType != TYPE_VALUE) {
      throw new AuraHandledException(
        'Increase type must be Increase by Percentage or Increase by Value.'
      );
    }
    if (increaseType == TYPE_PERCENT && draft.increasePercent == null) {
      throw new AuraHandledException(
        'Increase percent is required for percentage increases.'
      );
    }
    if (increaseType == TYPE_VALUE && draft.increaseAmount == null) {
      throw new AuraHandledException(
        'Increase amount is required for fixed-value increases.'
      );
    }
  }

  private static SaveResult mutateEnabled(
    List<Id> lineIds,
    Boolean isArchived,
    Boolean enabled,
    Boolean clearValues
  ) {
    clearLineCache();
    SaveResult result = emptyResult();
    if (lineIds == null || lineIds.isEmpty()) {
      throw new AuraHandledException('Select at least one product.');
    }
    if (isArchived == true) {
      throw new AuraHandledException(
        'Recurring price increase cannot be edited on archived orders.'
      );
    }
    LineBundle bundle = loadLines(new Set<Id>(lineIds));
    assertNotTerminatedOrDeleted(bundle);

    List<SObject> parentUpdates = new List<SObject>();
    for (Id lineId : lineIds) {
      LineContext ctx = bundle.byId.get(lineId);
      if (ctx == null) {
        continue;
      }
      SObject parent = ctx.isOrderItem
        ? (SObject) new OrderItem(Id = lineId)
        : (SObject) new OpportunityLineItem(Id = lineId);
      parent.put('Recurring_Price_Increase_Enabled__c', enabled);
      if (clearValues) {
        parent.put('Recurring_Increase_Frequency_Months__c', null);
        parent.put('Recurring_Increase_Start_Date__c', null);
        parent.put('Recurring_Increase_Type__c', null);
        parent.put('Recurring_Increase_Percent__c', null);
        parent.put('Recurring_Increase_Amount__c', null);
        parent.put('Current_Effective_Price__c', null);
      }
      parentUpdates.add(parent);
      result.updatedLines++;
    }
    if (!parentUpdates.isEmpty()) {
      update parentUpdates;
    }
    result.message = clearValues
      ? 'Removed recurring price increase from ' +
        result.updatedLines +
        ' product(s). Monthly payments were left unchanged.'
      : 'Disabled recurring price increase on ' +
        result.updatedLines +
        ' product(s). Monthly payments were left unchanged.';
    return result;
  }

  private static void assertNotTerminatedOrDeleted(LineBundle bundle) {
    for (LineContext ctx : bundle.byId.values()) {
      if (ctx.isLineDeleted == true) {
        throw new AuraHandledException(
          'Recurring price increase cannot be edited on archived or deleted lines.'
        );
      }
      if (ctx.isOrderItem == true && !String.isBlank(ctx.terminationReason)) {
        throw new AuraHandledException(
          'Recurring price increase cannot be changed on terminated products.'
        );
      }
    }
  }

  private static Decimal lineBasePrice(LineContext ctx) {
    if (ctx == null) {
      return 0;
    }
    if (ctx.isOrderItem == true) {
      Decimal unit = ctx.unitPrice == null ? 0 : ctx.unitPrice;
      Decimal qty = ctx.quantity == null ||
        ctx.quantity == 0
        ? 1
        : ctx.quantity;
      return (unit * qty).setScale(2);
    }
    if (ctx.totalPrice != null) {
      return ctx.totalPrice.setScale(2);
    }
    Decimal unit = ctx.unitPrice == null ? 0 : ctx.unitPrice;
    Decimal qty = ctx.quantity == null || ctx.quantity == 0 ? 1 : ctx.quantity;
    return (unit * qty).setScale(2);
  }

  private static Integer projectMonthlyPayments(
    Map<Id, LineContext> contextsById,
    Date today
  ) {
    if (contextsById == null || contextsById.isEmpty()) {
      return 0;
    }
    Set<Id> orderItemIds = new Set<Id>();
    Set<Id> oliIds = new Set<Id>();
    for (LineContext ctx : contextsById.values()) {
      if (ctx.isOrderItem == true) {
        orderItemIds.add(ctx.lineId);
      } else {
        oliIds.add(ctx.lineId);
      }
    }

    List<MonthlyPayment__c> payments = new List<MonthlyPayment__c>();
    if (!orderItemIds.isEmpty()) {
      payments.addAll(
        [
          SELECT
            Id,
            OrderItem__c,
            OpportunityLineItem__c,
            Start_date__c,
            Stat_Date_Trigger__c,
            Price__c,
            Discount__c,
            Final_Adjusted_Price__c,
            User_Price_Adjustment__c
          FROM MonthlyPayment__c
          WHERE OrderItem__c IN :orderItemIds
        ]
      );
    }
    if (!oliIds.isEmpty()) {
      payments.addAll(
        [
          SELECT
            Id,
            OrderItem__c,
            OpportunityLineItem__c,
            Start_date__c,
            Stat_Date_Trigger__c,
            Price__c,
            Discount__c,
            Final_Adjusted_Price__c,
            User_Price_Adjustment__c
          FROM MonthlyPayment__c
          WHERE OpportunityLineItem__c IN :oliIds
        ]
      );
    }

    Map<Id, List<MonthlyPayment__c>> byLine = new Map<Id, List<MonthlyPayment__c>>();
    for (MonthlyPayment__c mp : payments) {
      Id parentId = mp.OrderItem__c != null
        ? mp.OrderItem__c
        : mp.OpportunityLineItem__c;
      if (parentId == null || !contextsById.containsKey(parentId)) {
        continue;
      }
      if (!byLine.containsKey(parentId)) {
        byLine.put(parentId, new List<MonthlyPayment__c>());
      }
      byLine.get(parentId).add(mp);
    }

    Date todayMonth = today.toStartOfMonth();
    List<MonthlyPayment__c> toUpdate = new List<MonthlyPayment__c>();
    List<SObject> parentPriceUpdates = new List<SObject>();

    for (Id lineId : contextsById.keySet()) {
      LineContext ctx = contextsById.get(lineId);
      if (ctx == null || ctx.effectiveStart == null) {
        continue;
      }
      Date effectiveMonth = ctx.effectiveStart.toStartOfMonth();
      List<MonthlyPayment__c> linePayments = byLine.get(lineId);
      if (linePayments == null) {
        linePayments = new List<MonthlyPayment__c>();
      }
      linePayments.sort(new MonthlyPaymentMonthComparator());

      Decimal stableBase = ctx.basePrice;
      MonthlyPayment__c priorMp = null;
      MonthlyPayment__c startMp = null;
      for (MonthlyPayment__c mp : linePayments) {
        Date monthStart = paymentMonthStart(mp);
        if (monthStart == null) {
          continue;
        }
        if (monthStart < effectiveMonth) {
          priorMp = mp;
        } else if (monthStart == effectiveMonth) {
          startMp = mp;
          break;
        } else {
          break;
        }
      }
      Decimal listBase = ctx.basePrice == null ? 0 : ctx.basePrice;
      Decimal priorFull = priorMp != null
        ? fullUnitEquivalentFinal(priorMp, listBase)
        : listBase;
      Decimal startFull = startMp != null
        ? fullUnitEquivalentFinal(startMp, listBase)
        : null;

      if (startFull != null) {
        // Step off the current start-month Final (or prior month when start month is missing).
        stableBase = startFull >= priorFull ? startFull : priorFull;
      } else if (priorMp != null) {
        stableBase = priorFull;
      }

      Decimal lastSteppedFinal = stableBase;
      Decimal currentEffective = null;
      // Advance calendar from effective start so missed step months still compound.
      Date cursor = effectiveMonth;
      Date walkEnd = todayMonth;
      for (MonthlyPayment__c mp : linePayments) {
        Date monthStart = paymentMonthStart(mp);
        if (monthStart != null && monthStart > walkEnd) {
          walkEnd = monthStart;
        }
      }
      Map<Date, Decimal> targetByMonth = new Map<Date, Decimal>();
      while (cursor <= walkEnd) {
        if (
          isRecurringStepMonth(cursor, ctx.effectiveStart, ctx.frequencyMonths)
        ) {
          lastSteppedFinal = applyOneRecurringStep(
            lastSteppedFinal,
            ctx.increaseType,
            ctx.increasePercent,
            ctx.increaseAmount
          );
        }
        if (cursor >= effectiveMonth) {
          targetByMonth.put(cursor, lastSteppedFinal);
        }
        if (cursor == todayMonth) {
          currentEffective = lastSteppedFinal;
        }
        cursor = cursor.addMonths(1);
      }
      if (currentEffective == null) {
        if (todayMonth < effectiveMonth) {
          currentEffective = ctx.basePrice;
        } else {
          currentEffective = targetFinalAsOf(
            stableBase,
            ctx.effectiveStart,
            ctx.frequencyMonths,
            ctx.increaseType,
            ctx.increasePercent,
            ctx.increaseAmount,
            todayMonth
          );
        }
      }

      for (MonthlyPayment__c mp : linePayments) {
        Date monthStart = paymentMonthStart(mp);
        if (monthStart == null) {
          continue;
        }
        if (monthStart < effectiveMonth || monthStart < todayMonth) {
          continue;
        }
        Decimal targetFinal = targetByMonth.get(monthStart);
        if (targetFinal == null) {
          continue;
        }
        mp.Discount__c = discountForMonthlyPaymentStorage(
          ctx.basePrice,
          targetFinal
        );
        toUpdate.add(mp);
      }

      SObject parent = ctx.isOrderItem
        ? (SObject) new OrderItem(Id = lineId)
        : (SObject) new OpportunityLineItem(Id = lineId);
      parent.put('Current_Effective_Price__c', currentEffective);
      parentPriceUpdates.add(parent);
    }

    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
    if (!parentPriceUpdates.isEmpty()) {
      update parentPriceUpdates;
    }
    return toUpdate.size();
  }

  private static Decimal targetFinalAsOf(
    Decimal stableBase,
    Date effectiveStart,
    Integer frequencyMonths,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount,
    Date asOfMonth
  ) {
    Decimal running = stableBase == null ? 0 : stableBase;
    Integer steps = stepCount(asOfMonth, effectiveStart, frequencyMonths);
    for (Integer i = 0; i < steps; i++) {
      running = applyOneRecurringStep(
        running,
        increaseType,
        increasePercent,
        increaseAmount
      );
    }
    return running;
  }

  private static Boolean isRuleUnchanged(
    LineContext ctx,
    Integer frequencyMonths,
    Date startDate,
    String increaseType,
    Decimal increasePercent,
    Decimal increaseAmount
  ) {
    if (ctx == null || ctx.enabled != true) {
      return false;
    }
    if (ctx.frequencyMonths != frequencyMonths) {
      return false;
    }
    if (ctx.ruleStartDate != startDate) {
      return false;
    }
    if (normalizeIncreaseType(ctx.increaseType) != increaseType) {
      return false;
    }
    if (increaseType == TYPE_PERCENT) {
      return decimalEquals(ctx.increasePercent, increasePercent);
    }
    if (increaseType == TYPE_VALUE) {
      return decimalEquals(ctx.increaseAmount, increaseAmount);
    }
    return false;
  }

  private static Boolean decimalEquals(Decimal a, Decimal b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a == b;
  }

  private static Date paymentMonthStart(MonthlyPayment__c mp) {
    if (mp == null) {
      return null;
    }
    if (mp.Start_date__c != null) {
      return mp.Start_date__c.toStartOfMonth();
    }
    return mp.Stat_Date_Trigger__c == null
      ? null
      : mp.Stat_Date_Trigger__c.toStartOfMonth();
  }

  /**
   * Final for an MP: prefer usable Final_Adjusted_Price__c; else Price * (1 + rate).
   */
  @TestVisible
  private static Decimal finalOfPayment(
    MonthlyPayment__c mp,
    Decimal fallbackBasis
  ) {
    if (mp == null) {
      return fallbackBasis == null ? 0 : fallbackBasis;
    }
    if (mp.Final_Adjusted_Price__c != null && mp.Final_Adjusted_Price__c != 0) {
      return mp.Final_Adjusted_Price__c.setScale(2);
    }
    Decimal priceBasis = (mp.Price__c != null &&
      mp.Price__c != 0)
      ? mp.Price__c
      : fallbackBasis;
    if (priceBasis == null) {
      priceBasis = 0;
    }
    Decimal rate = toFraction(mp.Discount__c);
    return (priceBasis * (1 + rate)).setScale(2);
  }

  private static Decimal priorFinalBeforeMonth(
    Id lineId,
    Date monthStart,
    Decimal fallbackBasis
  ) {
    List<MonthlyPayment__c> cached = paymentsForLine(lineId);
    MonthlyPayment__c latest = null;
    Date latestMonth = null;
    for (MonthlyPayment__c mp : cached) {
      Date m = paymentMonthStart(mp);
      if (m == null || m >= monthStart) {
        continue;
      }
      if (latestMonth == null || m > latestMonth) {
        latestMonth = m;
        latest = mp;
      }
    }
    if (latest == null) {
      return fallbackBasis == null ? 0 : fallbackBasis;
    }
    return fullUnitEquivalentFinal(latest, fallbackBasis);
  }

  /**
   * Prior-month Final scaled to full list/unit so step math matches
   * Discount-vs-unit semantics (partial Monthly_Units do not shrink the chain).
   */
  @TestVisible
  private static Decimal fullUnitEquivalentFinal(
    MonthlyPayment__c mp,
    Decimal fallbackBasis
  ) {
    Decimal fin = finalOfPayment(mp, fallbackBasis);
    if (mp == null) {
      return fallbackBasis == null ? 0 : fallbackBasis;
    }
    Decimal price = mp.Price__c;
    if (
      price != null &&
      price != 0 &&
      fallbackBasis != null &&
      fallbackBasis != 0
    ) {
      return (fin * fallbackBasis / price).setScale(2);
    }
    return fin;
  }

  /**
   * Stash consult outcome so subsequent create/top-up months in the same
   * transaction see prior Finals before those rows are inserted.
   */
  private static void rememberConsultResult(
    Id lineId,
    Date monthStart,
    Decimal priceBasis,
    Decimal targetFinal,
    Decimal discount
  ) {
    if (lineId == null || monthStart == null) {
      return;
    }
    ensurePaymentsCached(new Set<Id>{ lineId });
    List<MonthlyPayment__c> rows = paymentsCacheByLineId.get(lineId);
    if (rows == null) {
      rows = new List<MonthlyPayment__c>();
      paymentsCacheByLineId.put(lineId, rows);
    }
    Date month = monthStart.toStartOfMonth();
    for (MonthlyPayment__c existing : rows) {
      Date m = paymentMonthStart(existing);
      if (m == month) {
        // Price__c / Start_date__c are formulas — only writable fields here.
        existing.Discount__c = discount;
        existing.Final_Adjusted_Price__c = targetFinal;
        return;
      }
    }
    // Synthetic in-memory row for same-tx consult chain (not inserted).
    MonthlyPayment__c syn = new MonthlyPayment__c(
      Stat_Date_Trigger__c = month,
      Discount__c = discount,
      Final_Adjusted_Price__c = targetFinal
    );
    if (lineId.getSObjectType() == OrderItem.SObjectType) {
      syn.OrderItem__c = lineId;
    } else if (lineId.getSObjectType() == OpportunityLineItem.SObjectType) {
      syn.OpportunityLineItem__c = lineId;
    }
    rows.add(syn);
  }

  private static List<MonthlyPayment__c> paymentsForLine(Id lineId) {
    if (lineId == null) {
      return new List<MonthlyPayment__c>();
    }
    ensurePaymentsCached(new Set<Id>{ lineId });
    List<MonthlyPayment__c> rows = paymentsCacheByLineId.get(lineId);
    return rows == null ? new List<MonthlyPayment__c>() : rows;
  }

  private static void ensurePaymentsCached(Set<Id> lineIds) {
    if (lineIds == null || lineIds.isEmpty()) {
      return;
    }
    if (paymentsCacheByLineId == null) {
      paymentsCacheByLineId = new Map<Id, List<MonthlyPayment__c>>();
    }
    Set<Id> missing = new Set<Id>();
    for (Id lineId : lineIds) {
      if (lineId != null && !paymentsCacheByLineId.containsKey(lineId)) {
        missing.add(lineId);
      }
    }
    if (missing.isEmpty()) {
      return;
    }
    for (Id lineId : missing) {
      paymentsCacheByLineId.put(lineId, new List<MonthlyPayment__c>());
    }
    Set<Id> orderItemIds = new Set<Id>();
    Set<Id> oliIds = new Set<Id>();
    for (Id lineId : missing) {
      if (lineId.getSObjectType() == OrderItem.SObjectType) {
        orderItemIds.add(lineId);
      } else if (lineId.getSObjectType() == OpportunityLineItem.SObjectType) {
        oliIds.add(lineId);
      }
    }
    if (!orderItemIds.isEmpty()) {
      for (MonthlyPayment__c mp : [
        SELECT
          Id,
          OrderItem__c,
          OpportunityLineItem__c,
          Start_date__c,
          Stat_Date_Trigger__c,
          Price__c,
          Discount__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE OrderItem__c IN :orderItemIds
      ]) {
        paymentsCacheByLineId.get(mp.OrderItem__c).add(mp);
      }
    }
    if (!oliIds.isEmpty()) {
      for (MonthlyPayment__c mp : [
        SELECT
          Id,
          OrderItem__c,
          OpportunityLineItem__c,
          Start_date__c,
          Stat_Date_Trigger__c,
          Price__c,
          Discount__c,
          Final_Adjusted_Price__c
        FROM MonthlyPayment__c
        WHERE OpportunityLineItem__c IN :oliIds
      ]) {
        paymentsCacheByLineId.get(mp.OpportunityLineItem__c).add(mp);
      }
    }
  }

  private class MonthlyPaymentMonthComparator implements Comparator<MonthlyPayment__c> {
    public Integer compare(MonthlyPayment__c a, MonthlyPayment__c b) {
      Date da = paymentMonthStart(a);
      Date db = paymentMonthStart(b);
      if (da == null && db == null) {
        return 0;
      }
      if (da == null) {
        return 1;
      }
      if (db == null) {
        return -1;
      }
      if (da == db) {
        return 0;
      }
      return da > db ? 1 : -1;
    }
  }

  private static String buildEnableMessage(SaveResult result) {
    String msg =
      'Activated recurring price increase on ' +
      result.updatedLines +
      ' product(s). Monthly payments were not updated.';
    if (result.skippedIneligible != null && result.skippedIneligible > 0) {
      msg += ' Skipped ' + result.skippedIneligible + ' ineligible product(s).';
    }
    return msg;
  }

  private static String buildFieldsSaveMessage(SaveResult result) {
    String msg =
      'Saved recurring price increase rule on ' +
      result.updatedLines +
      ' product(s). Monthly payments were not updated.';
    if (result.skippedIneligible != null && result.skippedIneligible > 0) {
      msg += ' Skipped ' + result.skippedIneligible + ' ineligible product(s).';
    }
    return msg;
  }

  private static String buildApplyMessage(SaveResult result) {
    String msg =
      'Enabled and applied recurring price increase to ' +
      result.updatedLines +
      ' product(s)';
    if (result.updatedPayments != null && result.updatedPayments > 0) {
      msg += ' and updated ' + result.updatedPayments + ' monthly payment(s)';
    }
    msg += '.';
    if (result.skippedIneligible != null && result.skippedIneligible > 0) {
      msg += ' Skipped ' + result.skippedIneligible + ' ineligible product(s).';
    }
    return msg;
  }

  private static LineBundle loadLines(Set<Id> lineIds) {
    LineBundle bundle = new LineBundle();
    if (lineIds == null || lineIds.isEmpty()) {
      return bundle;
    }
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
          ServiceDate,
          UnitPrice,
          Quantity,
          Termination_Reason__c,
          Is_Line_Deleted__c,
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
        LineContext ctx = new LineContext();
        ctx.lineId = oi.Id;
        ctx.isOrderItem = true;
        ctx.accessType = oi.Access_Type__c;
        ctx.productName = oi.Product2 != null ? oi.Product2.Name : null;
        ctx.serviceDate = oi.ServiceDate;
        ctx.contractStart = orderContractStart(oi);
        ctx.isLineDeleted = oi.Is_Line_Deleted__c == true;
        ctx.terminationReason = oi.Termination_Reason__c;
        ctx.enabled = oi.Recurring_Price_Increase_Enabled__c == true;
        ctx.ruleStartDate = oi.Recurring_Increase_Start_Date__c;
        ctx.frequencyMonths = oi.Recurring_Increase_Frequency_Months__c == null
          ? null
          : oi.Recurring_Increase_Frequency_Months__c.intValue();
        ctx.increaseType = oi.Recurring_Increase_Type__c;
        ctx.increasePercent = oi.Recurring_Increase_Percent__c;
        ctx.increaseAmount = oi.Recurring_Increase_Amount__c;
        ctx.unitPrice = oi.UnitPrice;
        ctx.quantity = oi.Quantity;
        bundle.byId.put(oi.Id, ctx);
      }
    }

    if (!oliIds.isEmpty()) {
      for (OpportunityLineItem oli : [
        SELECT
          Id,
          Access_Type__c,
          Entry_Date__c,
          UnitPrice,
          Quantity,
          TotalPrice,
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
        LineContext ctx = new LineContext();
        ctx.lineId = oli.Id;
        ctx.isOrderItem = false;
        ctx.accessType = oli.Access_Type__c;
        ctx.productName = oli.Product2 != null ? oli.Product2.Name : null;
        ctx.serviceDate = oli.Entry_Date__c;
        ctx.contractStart = oli.Opportunity != null
          ? oli.Opportunity.Start_Date__c
          : null;
        ctx.isLineDeleted = false;
        ctx.terminationReason = null;
        ctx.enabled = oli.Recurring_Price_Increase_Enabled__c == true;
        ctx.ruleStartDate = oli.Recurring_Increase_Start_Date__c;
        ctx.frequencyMonths = oli.Recurring_Increase_Frequency_Months__c == null
          ? null
          : oli.Recurring_Increase_Frequency_Months__c.intValue();
        ctx.increaseType = oli.Recurring_Increase_Type__c;
        ctx.increasePercent = oli.Recurring_Increase_Percent__c;
        ctx.increaseAmount = oli.Recurring_Increase_Amount__c;
        ctx.unitPrice = oli.UnitPrice;
        ctx.quantity = oli.Quantity;
        ctx.totalPrice = oli.TotalPrice;
        bundle.byId.put(oli.Id, ctx);
      }
    }
    return bundle;
  }

  /**
   * Closed Won: copy recurring rule fields from OpportunityLineItem onto new OrderItems
   * keyed by Opportunity_Product__c. Skips draft clones (Original_Order_Product__c set).
   */
  public static void copyFromOpportunityProducts(List<OrderItem> newItems) {
    if (newItems == null || newItems.isEmpty()) {
      return;
    }
    Set<Id> oliIds = new Set<Id>();
    Map<Id, Id> oliToOrderItem = new Map<Id, Id>();
    for (OrderItem item : newItems) {
      if (item == null || item.Id == null) {
        continue;
      }
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
    Map<Id, OpportunityLineItem> sources = new Map<Id, OpportunityLineItem>(
      [
        SELECT
          Id,
          Recurring_Price_Increase_Enabled__c,
          Recurring_Increase_Frequency_Months__c,
          Recurring_Increase_Start_Date__c,
          Recurring_Increase_Type__c,
          Recurring_Increase_Percent__c,
          Recurring_Increase_Amount__c,
          Current_Effective_Price__c
        FROM OpportunityLineItem
        WHERE Id IN :oliIds
      ]
    );
    List<OrderItem> updates = new List<OrderItem>();
    for (Id oliId : oliToOrderItem.keySet()) {
      OpportunityLineItem src = sources.get(oliId);
      if (src == null) {
        continue;
      }
      OrderItem dest = new OrderItem(Id = oliToOrderItem.get(oliId));
      applyRuleFields(dest, src);
      updates.add(dest);
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  /**
   * Draft clone / auto-renew: copy recurring rule fields from Active (or prior)
   * OrderItems onto newly cloned draft lines keyed by Original_Order_Product__c.
   */
  public static void copyFromOriginalOrderProducts(List<OrderItem> newItems) {
    if (newItems == null || newItems.isEmpty()) {
      return;
    }
    Set<Id> sourceIds = new Set<Id>();
    Map<Id, Id> sourceToNew = new Map<Id, Id>();
    for (OrderItem item : newItems) {
      if (
        item == null ||
        item.Id == null ||
        item.Original_Order_Product__c == null
      ) {
        continue;
      }
      sourceIds.add(item.Original_Order_Product__c);
      sourceToNew.put(item.Original_Order_Product__c, item.Id);
    }
    if (sourceIds.isEmpty()) {
      return;
    }
    Map<Id, OrderItem> sources = new Map<Id, OrderItem>(
      [
        SELECT
          Id,
          Recurring_Price_Increase_Enabled__c,
          Recurring_Increase_Frequency_Months__c,
          Recurring_Increase_Start_Date__c,
          Recurring_Increase_Type__c,
          Recurring_Increase_Percent__c,
          Recurring_Increase_Amount__c,
          Current_Effective_Price__c
        FROM OrderItem
        WHERE Id IN :sourceIds
      ]
    );
    List<OrderItem> updates = new List<OrderItem>();
    for (Id sourceId : sourceToNew.keySet()) {
      OrderItem src = sources.get(sourceId);
      if (src == null) {
        continue;
      }
      OrderItem dest = new OrderItem(Id = sourceToNew.get(sourceId));
      applyRuleFields(dest, src);
      updates.add(dest);
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  private static void applyRuleFields(OrderItem dest, SObject src) {
    dest.Recurring_Price_Increase_Enabled__c = (Boolean) src.get(
      'Recurring_Price_Increase_Enabled__c'
    );
    dest.Recurring_Increase_Frequency_Months__c = (Decimal) src.get(
      'Recurring_Increase_Frequency_Months__c'
    );
    dest.Recurring_Increase_Start_Date__c = (Date) src.get(
      'Recurring_Increase_Start_Date__c'
    );
    dest.Recurring_Increase_Type__c = (String) src.get(
      'Recurring_Increase_Type__c'
    );
    dest.Recurring_Increase_Percent__c = (Decimal) src.get(
      'Recurring_Increase_Percent__c'
    );
    dest.Recurring_Increase_Amount__c = (Decimal) src.get(
      'Recurring_Increase_Amount__c'
    );
    dest.Current_Effective_Price__c = (Decimal) src.get(
      'Current_Effective_Price__c'
    );
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
}
