public with sharing class ModifyContractActionController {
    public class ActiveContractOption {
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public String locationName;
    }

    @AuraEnabled(cacheable=true)
    public static List<ActiveContractOption> getActiveContracts(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('Account id is required.');
        }

        List<Contract> activeContracts = [
            SELECT Id, ContractNumber
            FROM Contract
            WHERE AccountId = :accountId
              AND Status = 'Activated'
            ORDER BY LastModifiedDate DESC
        ];

        List<ActiveContractOption> options = new List<ActiveContractOption>();
        for (Contract contractRecord : activeContracts) {
            ActiveContractOption option = new ActiveContractOption();
            option.contractId = contractRecord.Id;
            option.contractNumber = contractRecord.ContractNumber;
            option.locationName = null;
            options.add(option);
        }

        return options;
    }
}