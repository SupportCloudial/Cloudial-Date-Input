@IsTest
private class ModifyContractActionController_Test {
    private static Account createAccount(String nameSuffix) {
        Account accountRecord = new Account(Name = 'MCA Account ' + nameSuffix);
        insert accountRecord;
        return accountRecord;
    }

    private static Opportunity createOpportunity(Id accountId, String nameSuffix) {
        Opportunity opp = new Opportunity(
            Name = 'MCA Opportunity ' + nameSuffix,
            AccountId = accountId,
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        return opp;
    }

    private static Locations__c createLocation(String nameSuffix) {
        Locations__c locationRecord = new Locations__c(Name = 'MCA Location ' + nameSuffix);
        insert locationRecord;
        return locationRecord;
    }

    private static Contract createContract(Id accountId, String statusValue, Id opportunityId, Id locationId) {
        Contract contractRecord = new Contract(
            AccountId = accountId,
            Status = statusValue,
            StartDate = Date.today(),
            ContractTerm = 12,
            Opportunity__c = opportunityId,
            Location__c = locationId
        );
        insert contractRecord;
        return contractRecord;
    }

    @IsTest
    static void getActiveContracts_requiresAccountId() {
        try {
            ModifyContractActionController.getActiveContracts(null);
            System.assert(false, 'Expected an AuraHandledException for missing account id.');
        } catch (AuraHandledException ex) {
            System.assert(
                ex.getMessage().contains('Account id is required.') ||
                ex.getMessage().contains('Script-thrown exception'),
                'Should return account id validation error.'
            );
        }
    }

    @IsTest
    static void getActiveContracts_returnsEmptyWhenNoActiveContracts() {
        Account accountRecord = createAccount('NoActive');
        createContract(accountRecord.Id, 'Draft', null, null);

        Test.startTest();
        List<ModifyContractActionController.ActiveContractOption> options =
            ModifyContractActionController.getActiveContracts(accountRecord.Id);
        Test.stopTest();

        System.assertEquals(0, options.size(), 'No activated contracts should produce an empty list.');
    }

    @IsTest
    static void getActiveContracts_returnsSingleActiveWithLocationName() {
        Account accountRecord = createAccount('Single');
        Locations__c locationRecord = createLocation('Single');
        Contract contractRecord = createContract(accountRecord.Id, 'Draft', null, locationRecord.Id);
        contractRecord.Status = 'Activated';
        update contractRecord;

        Test.startTest();
        List<ModifyContractActionController.ActiveContractOption> options =
            ModifyContractActionController.getActiveContracts(accountRecord.Id);
        Test.stopTest();

        System.assertEquals(1, options.size(), 'Exactly one active contract should be returned.');
        System.assertEquals(contractRecord.Id, options[0].contractId, 'Returned option should match the active contract.');
        System.assertEquals(locationRecord.Name, options[0].locationName, 'Location name should be projected.');
    }

    @IsTest
    static void getActiveContracts_returnsMultipleSortedByLastModifiedAndNullSafeOpportunity() {
        Account accountRecord = createAccount('Multiple');
        Locations__c oldLocation = createLocation('Old');

        Contract olderContract = createContract(accountRecord.Id, 'Draft', null, oldLocation.Id);
        Contract newerContract = createContract(accountRecord.Id, 'Draft', null, null);

        olderContract.Status = 'Activated';
        update olderContract;
        newerContract.Status = 'Activated';
        update newerContract;

        // Ensure olderContract becomes the most recently modified active record.
        olderContract.Description = 'Latest update to verify sort order';
        update olderContract;

        Test.startTest();
        List<ModifyContractActionController.ActiveContractOption> options =
            ModifyContractActionController.getActiveContracts(accountRecord.Id);
        Test.stopTest();

        System.assertEquals(2, options.size(), 'Both activated contracts should be returned.');
        System.assertEquals(olderContract.Id, options[0].contractId, 'Most recently modified active contract should come first.');
        System.assertEquals(newerContract.Id, options[1].contractId, 'Second option should be the older modified contract.');
        System.assertEquals(oldLocation.Name, options[0].locationName, 'Location name should be returned when available.');
        System.assertEquals(null, options[1].locationName, 'Location name should be null-safe when lookup is empty.');
    }
}