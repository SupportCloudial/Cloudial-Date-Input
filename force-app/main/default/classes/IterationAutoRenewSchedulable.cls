public class IterationAutoRenewSchedulable implements Schedulable {
  public static final Integer DEFAULT_BATCH_SIZE = 1;

  public void execute(SchedulableContext sc) {
    Database.executeBatch(new IterationAutoRenewBatch(), DEFAULT_BATCH_SIZE);
  }

  /** Async: one contract per batch execute (avoids SOQL 101 across many due contracts). */
  public static Id runNow() {
    return Database.executeBatch(
      new IterationAutoRenewBatch(),
      DEFAULT_BATCH_SIZE
    );
  }
}
