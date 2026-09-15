/** Commercial-package subset: monthly payment read for filter UI. */
public without sharing class OpportunityService {
  @AuraEnabled
  public static List<MonthlyPayment__c> getMonthlyPayments(
    String oppId,
    String contractId
  ) {
    try {
      String query =
        'SELECT Start_date__c, End_date__c, Price__c, Products_Name__c, Monthly_Units__c, ' +
        'Discount__c, Id, ' +
        'OpportunityLineItem__c, OpportunityLineItem__r.Name, ' +
        'OpportunityLineItem__r.Aggregated_List_Price_Adjustment__c, ' +
        'OpportunityLineItem__r.Calculated_List_Price_Adjustment__c, ' +
        'OrderItem__r.Calculated_List_Price_Adjustment__c, ' +
        'OrderItem__r.Aggregated_List_Price_Adjustment__c ' +
        'FROM MonthlyPayment__c ';

      List<String> filters = new List<String>();
      if (contractId != null) {
        filters.add('Contract__c = :contractId');
        filters.add('Products_Name__c != null');
      } else if (oppId != null) {
        filters.add('Opportunity__c = :oppId');
      }
      filters.add('Start_date__c != null');

      if (!filters.isEmpty()) {
        query += 'WHERE ' + String.join(filters, ' AND ');
      }
      query += ' ORDER BY Start_date__c ASC';
      return Database.query(query);
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }
}
