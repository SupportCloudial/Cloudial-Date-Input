trigger OrderTrigger on Order (before insert, before update, after insert, after update) {
    if (OrderTriggerHandler.isOrderTriggerHandlerEnabled()) {
        new OrderTriggerHandler().run();
    }
}