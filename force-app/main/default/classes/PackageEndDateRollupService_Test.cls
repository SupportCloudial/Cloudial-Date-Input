@IsTest
private class PackageEndDateRollupService_Test {
  @IsTest
  static void testComputeOrderEndRollupState_boundedMax() {
    Account acc = new Account(Name = 'Rollup Acc');
    insert acc;
    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12
    );
    insert c;
    c.Status = 'Activated';
    update c;

    Id pbId = Test.getStandardPricebookId();
    Locations__c loc = new Locations__c(
      Name = 'Loc R',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test Site',
      Address__c = 'Address 1',
      Area__c = 'Ramat Gan'
    );
    insert loc;
    Product2 p = new Product2(
      Name = 'Rollup Prod',
      IsActive = true,
      Location__c = loc.Id
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pbId,
      Product2Id = p.Id,
      UnitPrice = 50,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = new Opportunity(
      Name = 'Rollup Opp',
      CloseDate = Date.today().addDays(30),
      StageName = 'New',
      Location__c = loc.Id,
      Pricebook2Id = pbId
    );
    insert opp;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pbId,
      Location__c = loc.Id,
      OpportunityId = opp.Id,
      ContractId = c.Id,
      EndDate = Date.today().addDays(20)
    );
    insert ord;

    Date lineEnd = Date.today().addDays(50);
    insert new OrderItem(
      OrderId = ord.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 50,
      Access_Type__c = 'Periodic',
      ServiceDate = Date.today(),
      EndDate = lineEnd,
      Contract__c = c.Id
    );

    PackageEndDateRollupService.OrderEndRollupState st = PackageEndDateRollupService.computeOrderEndRollupState(
      ord.Id
    );
    System.assertEquals(
      false,
      st.openEndedIncluded,
      'Single bounded line should not be open-ended rollup'
    );
    System.assertEquals(lineEnd, st.maxBoundedEnd);
  }

  @IsTest
  static void testAlignContract_whenOrderEndCleared_opensContract() {
    Account acc = new Account(Name = 'Align Acc');
    insert acc;
    Date contractEnd = Date.today().addMonths(6);
    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12,
      EndDate = contractEnd
    );
    insert c;
    c.Status = 'Activated';
    update c;

    Id pbId = Test.getStandardPricebookId();
    Locations__c loc = new Locations__c(
      Name = 'Loc Align',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test Site',
      Address__c = 'Address 1',
      Area__c = 'Ramat Gan'
    );
    insert loc;
    Product2 p = new Product2(
      Name = 'Align Prod',
      IsActive = true,
      Location__c = loc.Id
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pbId,
      Product2Id = p.Id,
      UnitPrice = 50,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = new Opportunity(
      Name = 'Align Opp',
      CloseDate = Date.today().addDays(30),
      StageName = 'New',
      Location__c = loc.Id,
      Pricebook2Id = pbId
    );
    insert opp;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pbId,
      Location__c = loc.Id,
      OpportunityId = opp.Id,
      ContractId = c.Id,
      EndDate = contractEnd
    );
    insert ord;

    ord.EndDate = null;
    update ord;

    PackageEndDateRollupService.alignContractEndsToOrderPackageRollups(
      new Set<Id>{ c.Id }
    );

    Contract cAfter = [SELECT EndDate FROM Contract WHERE Id = :c.Id];
    System.assertEquals(
      null,
      cAfter.EndDate,
      'Contract should open when the only package order has no end date'
    );
  }

  @IsTest
  static void testMergeProposedExtendsBeyondExistingMax() {
    PackageEndDateRollupService.OrderEndRollupState st = new PackageEndDateRollupService.OrderEndRollupState();
    st.openEndedIncluded = false;
    st.maxBoundedEnd = Date.today().addDays(10);
    Date ps = Date.today().addDays(40);
    Date pe = Date.today().addDays(45);
    Date merged = PackageEndDateRollupService.mergeProposedIntoTargetOrderEnd(
      st,
      ps,
      pe,
      false
    );
    System.assertEquals(pe, merged);
  }

  @IsTest
  static void testApplyContractThenOrder_extendsContractBeforeOrder() {
    Account acc = new Account(Name = 'Apply Acc');
    insert acc;
    Date contractEnd = Date.today().addMonths(2);
    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12,
      EndDate = contractEnd
    );
    insert c;
    c.Status = 'Activated';
    update c;

    Id pbId = Test.getStandardPricebookId();
    Locations__c loc = new Locations__c(
      Name = 'Loc A',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test Site',
      Address__c = 'Address 1',
      Area__c = 'Ramat Gan'
    );
    insert loc;
    Product2 p = new Product2(
      Name = 'Apply Prod',
      IsActive = true,
      Location__c = loc.Id
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pbId,
      Product2Id = p.Id,
      UnitPrice = 50,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = new Opportunity(
      Name = 'Apply Opp',
      CloseDate = Date.today().addDays(30),
      StageName = 'New',
      Location__c = loc.Id,
      Pricebook2Id = pbId
    );
    insert opp;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pbId,
      Location__c = loc.Id,
      OpportunityId = opp.Id,
      ContractId = c.Id,
      EndDate = contractEnd
    );
    insert ord;

    Date target = contractEnd.addMonths(3);
    PackageEndDateRollupService.applyContractThenOrderEndForPackage(
      ord.Id,
      target
    );

    Contract cAfter = [SELECT EndDate FROM Contract WHERE Id = :c.Id];
    Order ordAfter = [SELECT EndDate FROM Order WHERE Id = :ord.Id];
    System.assert(
      cAfter.EndDate >= target,
      'Contract.EndDate should extend to at least target before order can hold that end'
    );
    System.assertEquals(target, ordAfter.EndDate);
  }

  @isTest
  static void testComputeOrderEndRollupStateFromLines_openEndedAndSoftDeleted() {
    Product2 terms = new Product2(
      Name = 'Terms Rollup',
      IsActive = true,
      Type__c = PackageEndDateRollupService.PRODUCT_TYPE_CONTRACT_TERMS
    );
    insert terms;

    Date bounded = Date.today().addDays(40);
    OrderItem termsLine = new OrderItem(
      EndDate = bounded,
      Is_Line_Deleted__c = false
    );
    termsLine.Product2 = terms;
    List<OrderItem> lines = new List<OrderItem>{
      termsLine,
      new OrderItem(
        EndDate = Date.today().addDays(90),
        Is_Line_Deleted__c = true
      ),
      new OrderItem(EndDate = null, Is_Line_Deleted__c = false)
    };

    PackageEndDateRollupService.OrderEndRollupState st = PackageEndDateRollupService.computeOrderEndRollupStateFromLines(
      lines
    );
    System.assertEquals(true, st.openEndedIncluded);
    System.assertEquals(null, st.maxBoundedEnd);

    System.assertEquals(
      null,
      PackageEndDateRollupService.derivePackageEndDateFromLines(lines)
    );
    System.assertEquals(
      bounded,
      PackageEndDateRollupService.derivePackageEndDateFromLines(
        new List<OrderItem>{
          new OrderItem(EndDate = bounded, Is_Line_Deleted__c = false)
        }
      )
    );
    System.assertEquals(
      null,
      PackageEndDateRollupService.targetOrderEndFromRollupState(null)
    );
    System.assertEquals(
      null,
      PackageEndDateRollupService.mergeProposedIntoTargetOrderEnd(
        st,
        Date.today(),
        Date.today().addDays(5),
        true
      )
    );
    System.assertEquals(
      null,
      PackageEndDateRollupService.computeOrderEndRollupState(null).maxBoundedEnd
    );
  }

  @isTest
  static void testApplyContractThenOrderEndForPackage_nullClearsOrderOnly() {
    Account acc = new Account(Name = 'Null End Acc');
    insert acc;
    Contract c = new Contract(
      AccountId = acc.Id,
      Status = 'Draft',
      StartDate = Date.today(),
      ContractTerm = 12,
      EndDate = Date.today().addMonths(3)
    );
    insert c;
    c.Status = 'Activated';
    update c;

    Id pbId = Test.getStandardPricebookId();
    Locations__c loc = new Locations__c(
      Name = 'Loc N',
      City__c = 'Petah Tikva',
      Site_Name__c = 'Test Site',
      Address__c = 'Address 1',
      Area__c = 'Ramat Gan'
    );
    insert loc;
    Product2 p = new Product2(
      Name = 'Null End Prod',
      IsActive = true,
      Location__c = loc.Id
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pbId,
      Product2Id = p.Id,
      UnitPrice = 50,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = new Opportunity(
      Name = 'Null End Opp',
      CloseDate = Date.today().addDays(30),
      StageName = 'New',
      Location__c = loc.Id,
      Pricebook2Id = pbId
    );
    insert opp;

    Order ord = new Order(
      AccountId = acc.Id,
      Status = 'Draft',
      EffectiveDate = Date.today(),
      Pricebook2Id = pbId,
      Location__c = loc.Id,
      OpportunityId = opp.Id,
      ContractId = c.Id,
      EndDate = Date.today().addMonths(2)
    );
    insert ord;

    PackageEndDateRollupService.applyContractThenOrderEndForPackage(
      ord.Id,
      null
    );
    ord = [SELECT EndDate FROM Order WHERE Id = :ord.Id];
    System.assertEquals(null, ord.EndDate);
  }
}
