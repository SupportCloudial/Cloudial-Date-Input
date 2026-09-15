@isTest
private class TerminateContractController_Test {
    private static void bypassHeavyAutomation() {
        TriggerHandler.clearAllBypasses();
        TriggerHandler.bypass('OrderItemTriggerHandler');
        TriggerHandler.bypass('MonthlyPaymentTriggerHandler');
        TriggerHandler.bypass('OrderTriggerHandler');
        TriggerHandler.bypass('OpportunityLineItemTriggerHandler');
    }

    @isTest
    static void getContractContext_nullContractId_throws() {
        try {
            TerminateContractController.getContractContext(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('Contract id') || e.getMessage().contains('Script-thrown'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void getContractContext_returnsContext() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'TerminateCtx Acc');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addMonths(-2),
            EndDate = Date.today().addYears(1),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;

        Test.startTest();
        TerminateContractController.ContractContext ctx = TerminateContractController.getContractContext(c.Id);
        Test.stopTest();

        System.assertEquals(c.Id, ctx.contractId);
        System.assertEquals('Activated', ctx.status);
        System.assertNotEquals(null, ctx.startDate);
    }

    /**
     * No activated orders on the contract: controller applies contract-only termination (else branch).
     */
    @isTest
    static void terminateContract_noActiveOrders_updatesContract() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'Terminate Acc');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addMonths(-3),
            EndDate = Date.today().addYears(2),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;

        Date termDate = c.StartDate.addDays(45);

        Test.startTest();
        TerminateContractController.TerminationResult res = TerminateContractController.terminateContract(
            c.Id,
            termDate,
            'Dissatisfaction',
            25
        );
        Test.stopTest();

        System.assertEquals(true, res.success);
        System.assertEquals(termDate, res.terminationDate);
        System.assertEquals('Dissatisfaction', res.terminationReason);

        Contract reloaded = [
            SELECT Contract_Termination_Date__c, Contract_Termination_Reason__c, Early_Termination_Fee__c
            FROM Contract
            WHERE Id = :c.Id
        ];
        System.assertEquals(termDate, reloaded.Contract_Termination_Date__c);
        System.assertEquals('Dissatisfaction', reloaded.Contract_Termination_Reason__c);
        System.assertEquals(25, reloaded.Early_Termination_Fee__c);
    }

    @isTest
    static void terminateContract_nullContractId_throws() {
        try {
            TerminateContractController.terminateContract(null, Date.today(), 'Other', null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('Contract id') || e.getMessage().contains('Script-thrown'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void terminateContract_blankReason_throws() {
        Account acc = new Account(Name = 'TR Blank');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addYears(1),
            ContractTerm = 12
        );
        insert c;
        try {
            TerminateContractController.terminateContract(c.Id, Date.today().addDays(10), '   ', null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('Termination Reason') || e.getMessage().contains('Script-thrown'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void terminateContract_nullTerminationDate_throws() {
        Account acc = new Account(Name = 'TR NullTermDate');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addYears(1),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;
        try {
            TerminateContractController.terminateContract(c.Id, null, 'Other', null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('Termination Date') || e.getMessage().contains('Script-thrown'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void terminateContract_terminationOnOrBeforeStart_throws() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'TR BeforeStart');
        insert acc;
        Date start = Date.today().addMonths(-1);
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = start,
            EndDate = Date.today().addYears(2),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;
        try {
            TerminateContractController.terminateContract(c.Id, start, 'Dissatisfaction', null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('greater than Start Date') || e.getMessage().contains('Script-thrown'),
                e.getMessage()
            );
        }
    }

    @isTest
    static void getContractContext_setsLastTerminationFromNoticeMonths() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'TR LastTerm');
        insert acc;
        Date endD = Date.today().addYears(2);
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addMonths(-1),
            EndDate = endD,
            ContractTerm = 12,
            Lease_Termination_Notice_Months__c = '3'
        );
        insert c;
        c.Status = 'Activated';
        update c;

        Test.startTest();
        TerminateContractController.ContractContext ctx = TerminateContractController.getContractContext(c.Id);
        Test.stopTest();

        System.assertEquals(endD.addMonths(-3), ctx.lastTerminationDate);
    }

    private static void activateOrderWithItems(
        Contract c,
        Date itemEnd,
        Date itemStart
    ) {
        Id pb = Test.getStandardPricebookId();
        Locations__c loc = new Locations__c(Name = 'TR Term Loc');
        insert loc;
        Product2 prod = new Product2(Name = 'TR Term Prod', IsActive = true);
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pb,
            Product2Id = prod.Id,
            UnitPrice = 10,
            IsActive = true
        );
        insert pbe;
        Opportunity opp = new Opportunity(
            Name = 'TR Term Opp',
            StageName = 'New',
            CloseDate = Date.today().addMonths(1),
            AccountId = c.AccountId,
            Pricebook2Id = pb,
            Location__c = loc.Id
        );
        insert opp;
        Order ord = new Order(
            AccountId = c.AccountId,
            ContractId = c.Id,
            OpportunityId = opp.Id,
            Status = 'Draft',
            EffectiveDate = c.StartDate,
            Pricebook2Id = pb,
            Location__c = loc.Id
        );
        insert ord;
        OrderItem oi = new OrderItem(
            OrderId = ord.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 10,
            ServiceDate = itemStart,
            EndDate = itemEnd,
            Access_Type__c = 'Periodic',
            Contract__c = c.Id
        );
        insert oi;
        ord.Status = 'Activated';
        update ord;
    }

    /**
     * Termination date after all product end dates: contract -> order -> order items update order.
     */
    @isTest
    static void terminateContract_activatedOrder_afterProductEnds() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'TR AfterEnds');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addMonths(-2),
            EndDate = Date.today().addYears(3),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;

        Date prodEnd = c.StartDate.addDays(120);
        activateOrderWithItems(c, prodEnd, c.StartDate.addDays(1));

        Date termDate = prodEnd.addDays(30);
        Test.startTest();
        TerminateContractController.TerminationResult res = TerminateContractController.terminateContract(
            c.Id,
            termDate,
            'Dissatisfaction',
            40
        );
        Test.stopTest();

        System.assertEquals(true, res.success);
        System.assertNotEquals(null, res.activeOrderId);
        Contract reC = [
            SELECT Contract_Termination_Date__c, Early_Termination_Fee__c
            FROM Contract
            WHERE Id = :c.Id
        ];
        System.assertEquals(termDate, reC.Contract_Termination_Date__c);
        System.assertEquals(40, reC.Early_Termination_Fee__c);
    }

    /**
     * Termination date on/before max product end: order items -> order -> contract.
     */
    @isTest
    static void terminateContract_activatedOrder_onOrBeforeProductEnd() {
        bypassHeavyAutomation();
        Account acc = new Account(Name = 'TR OnOrBefore');
        insert acc;
        Contract c = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addMonths(-2),
            EndDate = Date.today().addYears(3),
            ContractTerm = 12
        );
        insert c;
        c.Status = 'Activated';
        update c;

        Date prodEnd = c.StartDate.addDays(200);
        activateOrderWithItems(c, prodEnd, c.StartDate.addDays(1));

        Date termDate = prodEnd.addDays(-10);
        Test.startTest();
        TerminateContractController.TerminationResult res = TerminateContractController.terminateContract(
            c.Id,
            termDate,
            'Dissatisfaction',
            null
        );
        Test.stopTest();

        System.assertEquals(true, res.success);
        Contract reC = [SELECT Contract_Termination_Date__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(termDate, reC.Contract_Termination_Date__c);
    }
}