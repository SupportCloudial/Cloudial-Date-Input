/**
 * Applies Transfer Price monthly terms in a separate transaction so room-replace
 * does not hit the synchronous 100 SOQL limit (parent curtail + payment gen + flows).
 */
public without sharing class TransferPriceApplyQueueable implements Queueable {
  private final Id replacementOrderItemId;
  private final Date replaceStart;
  private final String sourceTermsJson;

  public TransferPriceApplyQueueable(
    Id replacementOrderItemId,
    Date replaceStart,
    List<TransferPriceService.MonthTerm> sourceTerms
  ) {
    this.replacementOrderItemId = replacementOrderItemId;
    this.replaceStart = replaceStart;
    this.sourceTermsJson = sourceTerms == null
      ? '[]'
      : JSON.serialize(sourceTerms);
  }

  public void execute(QueueableContext context) {
    if (replacementOrderItemId == null || replaceStart == null) {
      return;
    }
    List<TransferPriceService.MonthTerm> terms = (List<TransferPriceService.MonthTerm>) JSON.deserialize(
      sourceTermsJson,
      List<TransferPriceService.MonthTerm>.class
    );
    TransferPriceService.applyToReplacementLine(
      replacementOrderItemId,
      replaceStart,
      terms
    );
  }
}
