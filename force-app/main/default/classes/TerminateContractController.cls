public with sharing class TerminateContractController {
    public class ContractContext {
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public String status;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public Date nextPossibleTerminationDate;
        @AuraEnabled public Date lastTerminationDate;
        @AuraEnabled public Date existingTerminationDate;
        @AuraEnabled public String existingTerminationReason;
        @AuraEnabled public Decimal existingEarlyTerminationFee;
    }

    public class TerminationResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public Date terminationDate;
        @AuraEnabled public String terminationReason;
        @AuraEnabled public Id activeOrderId;
    }

    @AuraEnabled(cacheable=true)
    public static ContractContext getContractContext(Id contractId) {
        if (contractId == null) {
            throw new AuraHandledException('Contract id is required.');
        }

        Contract contractRecord = [
            SELECT Id, ContractNumber, Account.Name, Status, StartDate, EndDate,
                   Lease_Termination_Notice_Months__c,
                   Contract_Termination_Date__c, Contract_Termination_Reason__c,
                   Early_Termination_Fee__c
            FROM Contract
            WHERE Id = :contractId
            LIMIT 1
        ];

        ContractContext ctx = new ContractContext();
        ctx.contractId = contractRecord.Id;
        ctx.contractNumber = contractRecord.ContractNumber;
        ctx.accountName = contractRecord.Account != null ? contractRecord.Account.Name : null;
        ctx.status = contractRecord.Status;
        ctx.startDate = contractRecord.StartDate;
        ctx.endDate = contractRecord.EndDate;
        ctx.nextPossibleTerminationDate = null;
        ctx.existingTerminationDate = contractRecord.Contract_Termination_Date__c;
        ctx.existingTerminationReason = contractRecord.Contract_Termination_Reason__c;
        ctx.existingEarlyTerminationFee = contractRecord.Early_Termination_Fee__c;

        if (contractRecord.EndDate != null) {
            Integer noticeMonths = 0;
            if (contractRecord.Lease_Termination_Notice_Months__c != null) {
                noticeMonths = Integer.valueOf(contractRecord.Lease_Termination_Notice_Months__c);
            }
            ctx.lastTerminationDate = contractRecord.EndDate.addMonths(-1 * noticeMonths);
        }

        return ctx;
    }

    @AuraEnabled
    public static TerminationResult terminateContract(
        Id contractId,
        Date terminationDate,
        String terminationReason,
        Decimal earlyTerminationFee
    ) {
        if (contractId == null) {
            throw new AuraHandledException('Contract id is required.');
        }
        if (terminationDate == null) {
            throw new AuraHandledException('Contract Termination Date is required.');
        }
        if (String.isBlank(terminationReason)) {
            throw new AuraHandledException('Termination Reason is required.');
        }

        Contract contractRecord = [
            SELECT Id, ContractNumber, Account.Name, StartDate, EndDate
            FROM Contract
            WHERE Id = :contractId
            LIMIT 1
            FOR UPDATE
        ];

        if (contractRecord.StartDate != null && terminationDate <= contractRecord.StartDate) {
            throw new AuraHandledException('Termination Date must be greater than Start Date');
        }

        TerminationResult result = new TerminationResult();

        List<Order> activeOrders = [
            SELECT Id, EndDate, Early_Termination_Fee__c
            FROM Order
            WHERE ContractId = :contractId
              AND Status = 'Activated'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (!activeOrders.isEmpty()) {
            Order activeOrder = activeOrders[0];
            result.activeOrderId = activeOrder.Id;
            List<OrderItem> orderItems = [
                SELECT Id, EndDate, Termination_Reason__c
                FROM OrderItem
                WHERE OrderId = :activeOrder.Id
                FOR UPDATE
            ];

            Date maxProductEndDate = null;
            for (OrderItem item : orderItems) {
                if (item.EndDate != null && (maxProductEndDate == null || item.EndDate > maxProductEndDate)) {
                    maxProductEndDate = item.EndDate;
                }
            }

            Boolean terminationAfterProductDates = (maxProductEndDate == null || terminationDate > maxProductEndDate);

            if (terminationAfterProductDates) {
                // Scenario 1: user date is later than product dates
                // Contract -> Order -> Order Items
                applyContractUpdate(contractRecord, terminationDate, terminationReason, earlyTerminationFee);
                update contractRecord;

                applyOrderUpdate(activeOrder, terminationDate, earlyTerminationFee);
                update activeOrder;

                applyOrderItemsUpdate(orderItems, terminationDate, terminationReason);
                if (!orderItems.isEmpty()) {
                    OrderItemTriggerHandler.enterContractTermMeterEndDateNormalizeSuppress();
                    try {
                        update orderItems;
                    } finally {
                        OrderItemTriggerHandler.exitContractTermMeterEndDateNormalizeSuppress();
                    }
                }
            } else {
                // Scenario 2: user date is earlier than or equal to at least one product end date
                // Order Items -> Order -> Contract
                applyOrderItemsUpdate(orderItems, terminationDate, terminationReason);
                if (!orderItems.isEmpty()) {
                    OrderItemTriggerHandler.enterContractTermMeterEndDateNormalizeSuppress();
                    try {
                        update orderItems;
                    } finally {
                        OrderItemTriggerHandler.exitContractTermMeterEndDateNormalizeSuppress();
                    }
                }

                applyOrderUpdate(activeOrder, terminationDate, earlyTerminationFee);
                update activeOrder;

                applyContractUpdate(contractRecord, terminationDate, terminationReason, earlyTerminationFee);
                update contractRecord;
            }
        } else {
            applyContractUpdate(contractRecord, terminationDate, terminationReason, earlyTerminationFee);
            update contractRecord;
        }

        result.success = true;
        result.message = 'Contract Terminated Successfully';
        result.contractNumber = contractRecord.ContractNumber;
        result.accountName = contractRecord.Account != null ? contractRecord.Account.Name : null;
        result.terminationDate = terminationDate;
        result.terminationReason = terminationReason;
        return result;
    }

    private static void applyContractUpdate(
        Contract contractRecord,
        Date terminationDate,
        String terminationReason,
        Decimal earlyTerminationFee
    ) {
        contractRecord.put('EndDate', terminationDate);
        contractRecord.Contract_Termination_Date__c = terminationDate;
        contractRecord.Contract_Termination_Reason__c = terminationReason;
        contractRecord.Early_Termination_Fee__c = earlyTerminationFee;
    }

    private static void applyOrderUpdate(Order activeOrder, Date terminationDate, Decimal earlyTerminationFee) {
        activeOrder.put('EndDate', terminationDate);
        if (earlyTerminationFee != null) {
            activeOrder.Early_Termination_Fee__c = earlyTerminationFee;
        }
    }

    private static void applyOrderItemsUpdate(List<OrderItem> orderItems, Date terminationDate, String terminationReason) {
        for (OrderItem item : orderItems) {
            item.put('EndDate', terminationDate);
            item.Termination_Reason__c = terminationReason;
        }
    }
}