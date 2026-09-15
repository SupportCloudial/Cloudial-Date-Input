/**
 * Batch (and Schedulable) that activates Draft orders when their EffectiveDate has arrived.
 * On update to Activated, OrderTriggerHandler syncs order fields to the related contract.
 *
 * Schedule daily so orders with a future start date are activated on that date.
 * Example: System.schedule('Activate orders on start date', '0 0 6 * * ?', new OrderUpcomingActivationBatch());
 */
public class OrderUpcomingActivationBatch implements Database.Batchable<SObject>, Schedulable {

    public Database.QueryLocator start(Database.BatchableContext BC) {
        Date today = Date.today();
        return Database.getQueryLocator([
            SELECT Id, Previous_Order__c
            FROM Order
            WHERE Status = 'Draft'
            AND EffectiveDate <= :today
            AND ContractId != NULL
        ]);
    }

    public void execute(Database.BatchableContext BC, List<Order> scope) {
        List<Order> toUpdate = new List<Order>();
        Set<Id> previousOrderIds = new Set<Id>();
        for (Order o : scope) {
            toUpdate.add(new Order(Id = o.Id, Status = 'Activated'));
            if (o.Previous_Order__c != null) {
                previousOrderIds.add(o.Previous_Order__c);
            }
        }
        // Archive the previous active orders that are being replaced
        if (!previousOrderIds.isEmpty()) {
            for (Id prevId : previousOrderIds) {
                toUpdate.add(new Order(Id = prevId, Status = 'Archived'));
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    public void finish(Database.BatchableContext BC) {
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(new OrderUpcomingActivationBatch(), 200);
    }
}