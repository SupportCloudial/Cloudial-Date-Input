/**
 * @description       :
 * @author            : LAURIE CS
 * @group             :
 * @last modified on  : 2024-10-13
 **/
trigger OrderItemTrigger on OrderItem(
  before insert,
  before update,
  after insert,
  before delete,
  after update
) {
  if (OrderTriggerHandler.isOrderTriggerHandlerEnabled()) {
    new OrderItemTriggerHandler().run();
  }
}
