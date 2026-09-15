public without sharing class AddPackageProductController {
  /**
   * Package Builder global extras: Type = Contract Terms = null, unique Sub_Types.
   * Do not use Credits(Meeting rooms windows) here — many site-specific products share that value.
   */
  private static final String PRODUCT_TYPE_CONTRACT_TERMS = 'Contract Terms';
  private static final String PRODUCT_TYPE_EXTRA_FOR_ALL = 'Extra for all products';
  private static final String PRODUCT_TYPE_EXTRA_FOR_METER = 'Extra for meter Products';
  private static final Set<String> GLOBAL_PACKAGE_EXTRA_SUB_TYPES = new Set<String>{
    'Credits for MR',
    'Prints Color',
    'Prints B&W'
  };

  private static final String ERR_PRODUCT_START_BEFORE_ORDER = 'Product start date cannot be earlier than the contract start date.';
  private static final String ERR_PRODUCT_START_BEFORE_OPP = 'Product start date cannot be earlier than the opportunity start date.';
  private static final String ERR_PERIOD_END_BEFORE_ORDER_START = 'Period end date cannot be before the contract start date.';
  private static final String ERR_PERIOD_END_BEFORE_PRODUCT_START = 'Period end date cannot be before product start date.';

  /**
   * 869ddxhe8: Default CPI Date for the Add Products modal. Resolves the Opportunity that owns the
   * current context (Order -> Contract -> Opportunity__c -> Track_CPI_Date__c, Contract directly,
   * or Opportunity directly) and returns its Track_CPI_Date__c. The LWC seeds defaultCpiDateStr
   * from this value when empty and not in replace mode.
   */
  @AuraEnabled(cacheable=true)
  public static Date getDefaultCpiDateForContext(Id recordId) {
    if (recordId == null) {
      return null;
    }
    String sobjName = recordId.getSObjectType().getDescribe().getName();
    try {
      if (sobjName == 'Order') {
        List<Order> orders = [
          SELECT Opportunity__c
          FROM Order
          WHERE Id = :recordId
          LIMIT 1
        ];
        if (orders.isEmpty() || orders[0].Opportunity__c == null)
          return null;
        List<Opportunity> opps = [
          SELECT Track_CPI_Date__c
          FROM Opportunity
          WHERE Id = :orders[0].Opportunity__c
          LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0].Track_CPI_Date__c;
      } else if (sobjName == 'Contract') {
        return null;
      } else if (sobjName == 'Opportunity') {
        List<Opportunity> opps = [
          SELECT Track_CPI_Date__c
          FROM Opportunity
          WHERE Id = :recordId
          LIMIT 1
        ];
        if (opps.isEmpty())
          return null;
        return opps[0].Track_CPI_Date__c;
      }
    } catch (Exception e) {
      System.debug('getDefaultCpiDateForContext error: ' + e.getMessage());
    }
    return null;
  }

  private static Id getStandardPriceBookId() {
    // Query for the standard pricebook using IsStandard flag
    try {
      List<Pricebook2> standardPricebook = [
        SELECT Id
        FROM Pricebook2
        WHERE IsStandard = TRUE
        LIMIT 1
      ];
      if (standardPricebook.isEmpty()) {
        return null;
      }
      return standardPricebook[0].Id;
    } catch (Exception e) {
      System.debug('Error getting Standard Price Book: ' + e.getMessage());
      return null;
    }
  }

  private static Set<Id> getExistingLineItemProductIds(
    Id recordId,
    String sObjName
  ) {
    Set<Id> ids = new Set<Id>();
    if (sObjName == 'Opportunity') {
      for (OpportunityLineItem oli : [
        SELECT Product2Id, Product2.Type__c
        FROM OpportunityLineItem
        WHERE OpportunityId = :recordId AND Product2Id != NULL
      ]) {
        if (
          oli.Product2 != null &&
          (oli.Product2.Type__c == PRODUCT_TYPE_EXTRA_FOR_ALL ||
          oli.Product2.Type__c == PRODUCT_TYPE_EXTRA_FOR_METER)
        ) {
          continue;
        }
        ids.add(oli.Product2Id);
      }
    } else if (sObjName == 'Order') {
      for (OrderItem oi : [
        SELECT Product2Id, Product2.Type__c, Is_Line_Deleted__c
        FROM OrderItem
        WHERE OrderId = :recordId AND Product2Id != NULL
      ]) {
        if (!PackageBuilderService.isLineVisible(oi)) {
          continue;
        }
        if (
          oi.Product2 != null &&
          (oi.Product2.Type__c == PRODUCT_TYPE_EXTRA_FOR_ALL ||
          oi.Product2.Type__c == PRODUCT_TYPE_EXTRA_FOR_METER)
        ) {
          continue;
        }
        ids.add(oi.Product2Id);
      }
    }
    return ids;
  }

  @AuraEnabled(cacheable=true)
  public static List<Map<String, String>> getLocationsForPackageBuilder(
    String recordId
  ) {
    if (String.isBlank(recordId)) {
      return new List<Map<String, String>>();
    }
    Id recId = (Id) recordId;
    if (recId == null) {
      return new List<Map<String, String>>();
    }
    String sObjName = recId.getSobjectType().getDescribe().getName();
    Id pricebookId = null;

    if (sObjName == 'Opportunity') {
      Opportunity opp = [
        SELECT Pricebook2Id
        FROM Opportunity
        WHERE Id = :recId
        LIMIT 1
      ];
      pricebookId = opp.Pricebook2Id;
    } else if (sObjName == 'Order') {
      Order ord = [SELECT Pricebook2Id FROM Order WHERE Id = :recId LIMIT 1];
      pricebookId = ord.Pricebook2Id;
    }

    if (pricebookId == null) {
      pricebookId = getStandardPriceBookId();
    }
    if (pricebookId == null) {
      return new List<Map<String, String>>();
    }

    // Locations that have at least one product in the record's pricebook (no nested subquery - SOQL limit)
    // Cloudial: location catalog filter removed — return empty options.
    return new List<Map<String, String>>();
  }

  @AuraEnabled(cacheable=true)
  public static List<ProductData> getProductsByLocation(String recordId) {
    return getProductsByLocationWithPeriod(recordId, null, null, null);
  }

  // Not cacheable: result depends on dynamic Opportunity/Order line items (we exclude Product2s already on the package).
  // With cacheable=true the LDS client cache returned the pre-add catalog on the next modal open, so a just-added product was still selectable until a hard refresh.
  @AuraEnabled
  public static List<ProductData> getProductsByLocationWithPeriod(
    String recordId,
    String locationId,
    String periodStartStr,
    String periodEndStr
  ) {
    Id recId = (Id) recordId;
    String sObjName = recId.getSobjectType().getDescribe().getName();
    String location = '';
    Id pricebookId = null;

    System.debug('getProductsByLocation recordId: ' + recordId);
    if (sObjName == 'Opportunity') {
      Opportunity opp = [
        SELECT  Pricebook2Id
        FROM Opportunity
        WHERE Id = :recId
      ];
      location = locationId;
      pricebookId = opp.Pricebook2Id;
    } else if (sObjName == 'Order') {
      Order ord = [
        SELECT  Pricebook2Id
        FROM Order
        WHERE Id = :recId
      ];
      location = locationId;
      pricebookId = ord.Pricebook2Id;
    }
    System.debug('Location: ' + location + ', Pricebook: ' + pricebookId);

    // Use Standard Price Book if pricebook is empty
    if (pricebookId == null) {
      pricebookId = getStandardPriceBookId();
      System.debug(
        'Pricebook was null, using Standard Price Book: ' + pricebookId
      );
    }

    if (pricebookId == null) {
      System.debug('Missing pricebook.');
      return new List<ProductData>();
    }

    Set<Id> alreadyOnPackage = getExistingLineItemProductIds(recId, sObjName);
    Set<Id> includedProduct2Ids = new Set<Id>();
    List<PricebookEntry> pricebookEntries = new List<PricebookEntry>();

    // Commercial package: no Location filter. Load active pricebook catalog for the parent.
    // (Legacy rooms path filtered by Product2.Location__c when locationId was set.)
    String baseQuery =
      'SELECT Id, Name, Product2Id, UnitPrice, Floor__c, Window__c, Calculated_Price__c, Product2.Type__c, Product2.Sub_Type__c, Product2.State__c, Product2.Rent__c ' +
      'FROM PricebookEntry ' +
      'WHERE Pricebook2Id = :pricebookId AND IsActive = true AND Product2.IsActive = true';

    if (String.isNotBlank(location)) {
      // Location field removed from commercial package — ignore locationId if somehow passed.
      System.debug(
        'locationId ignored in commercial package catalog query: ' + location
      );
    }

    String recordTypeName = getRecordTypeName(recordId);
    System.debug('RecordTypeName: ' + recordTypeName);

    if (
      recordTypeName == 'Series Opportunity' ||
      recordTypeName == 'On demand Opportunity'
    ) {
      baseQuery +=
        ' AND (Product2.Type__c = \'On demand Products\' OR Product2.Type__c = \'Extra for all products\' OR Product2.Type__c = \'Extra for meter Products\')';
    }
    System.debug('Executing catalog query: ' + baseQuery);

    try {
      for (PricebookEntry pbe : Database.query(baseQuery)) {
        if (alreadyOnPackage.contains(pbe.Product2Id)) {
          continue;
        }
        pricebookEntries.add(pbe);
        includedProduct2Ids.add(pbe.Product2Id);
      }
    } catch (Exception e) {
      // Org may lack Product2 custom fields / FLS; fall back to core PBE columns.
      System.debug(
        LoggingLevel.WARN,
        'Catalog query failed, using fallback: ' + e.getMessage()
      );
      String fallbackQuery =
        'SELECT Id, Name, Product2Id, UnitPrice, Product2.Name ' +
        'FROM PricebookEntry ' +
        'WHERE Pricebook2Id = :pricebookId AND IsActive = true AND Product2.IsActive = true';
      for (PricebookEntry pbe : Database.query(fallbackQuery)) {
        if (alreadyOnPackage.contains(pbe.Product2Id)) {
          continue;
        }
        pricebookEntries.add(pbe);
        includedProduct2Ids.add(pbe.Product2Id);
      }
    }

    // Optional global Contract Terms extras (Credits/Prints) if not already included.
    List<String> globalSubTypes = new List<String>(
      GLOBAL_PACKAGE_EXTRA_SUB_TYPES
    );
    String contractTermsType = PRODUCT_TYPE_CONTRACT_TERMS;
    String globalQuery =
      'SELECT Id, Name, Product2Id, UnitPrice, Floor__c, Window__c, Calculated_Price__c, Product2.Type__c, Product2.Sub_Type__c, Product2.State__c, Product2.Rent__c ' +
      'FROM PricebookEntry ' +
      'WHERE Pricebook2Id = :pricebookId ' +
      'AND IsActive = true ' +
      'AND Product2.IsActive = true ' +
      'AND Product2.Type__c = :contractTermsType ' +
      'AND Product2.Sub_Type__c IN :globalSubTypes';

    try {
      for (PricebookEntry pbe : Database.query(globalQuery)) {
        if (
          alreadyOnPackage.contains(pbe.Product2Id) ||
          includedProduct2Ids.contains(pbe.Product2Id)
        ) {
          continue;
        }
        pricebookEntries.add(pbe);
        includedProduct2Ids.add(pbe.Product2Id);
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.WARN, 'Global extras query skipped: ' + e.getMessage());
    }
    System.debug('Combined pricebook entry count: ' + pricebookEntries.size());

    Set<Id> existingContractsByProduct = getExistingContracts(pricebookEntries);

    Date periodStart = null;
    Date periodEnd = null;
    if (String.isNotBlank(periodStartStr)) {
      try {
        periodStart = Date.valueOf(periodStartStr);
      } catch (Exception e) {
        System.debug('Invalid periodStart: ' + periodStartStr);
      }
    }
    if (String.isNotBlank(periodEndStr)) {
      try {
        periodEnd = Date.valueOf(periodEndStr);
      } catch (Exception e) {
        System.debug('Invalid periodEnd: ' + periodEndStr);
      }
    }
    // Occupancy / desk inventory removed for Cloudial commercial package.
    Map<Id, OccupancyInfo> occupancyByProduct = new Map<Id, OccupancyInfo>();

    List<ProductData> productsData = new List<ProductData>();

    for (PricebookEntry pbe : pricebookEntries) {
      ProductData prdData = new ProductData(pbe);

      if (
        pbe.Product2 != null &&
        pbe.Product2.getPopulatedFieldsAsMap().containsKey('Type__c') &&
        (String) pbe.Product2.get('Type__c') == 'Standard Products' &&
        (
          !pbe.Product2.getPopulatedFieldsAsMap().containsKey('Sub_Type__c') ||
          (String) pbe.Product2.get('Sub_Type__c') != 'Hot Desk'
        )
      ) {
        if (existingContractsByProduct.contains(pbe.Product2Id)) {
          prdData.Availability = '⚠️';
        } else {
          prdData.Availability = '🟢';
        }
      }
      if (
        occupancyByProduct != null &&
        occupancyByProduct.containsKey(pbe.Product2Id)
      ) {
        OccupancyInfo oi = occupancyByProduct.get(pbe.Product2Id);
        prdData.IsOccupiedInPeriod = oi.isOccupied;
        prdData.OccupiedFrom = oi.occupiedFrom;
        prdData.OccupiedTill = oi.occupiedTill;
        prdData.OccupyingAccountName = oi.occupyingAccountName;
        prdData.OccupyingAccountId = oi.occupyingAccountId != null
          ? String.valueOf(oi.occupyingAccountId)
          : null;
      }
      productsData.add(prdData);
    }

    return productsData;
  }

  /**
   * Returns the same catalog as getProductsByLocationWithPeriod, optionally appending one PricebookEntry by Id.
   * Not used by Package Builder LWC; wiring it to re-include a Product2 already on the package would contradict
   * duplicate prevention in Add/Replace pop-ups.
   */
  @AuraEnabled(cacheable=true)
  public static List<ProductData> getProductsByLocationWithPeriodIncludingEntry(
    String recordId,
    String locationId,
    String periodStartStr,
    String periodEndStr,
    String includePricebookEntryId
  ) {
    List<ProductData> out = getProductsByLocationWithPeriod(
      recordId,
      locationId,
      periodStartStr,
      periodEndStr
    );
    if (String.isBlank(includePricebookEntryId) || String.isBlank(recordId)) {
      return out;
    }

    // If already in the list, nothing to do.
    for (ProductData pd : out) {
      if (pd != null && pd.Id == includePricebookEntryId) {
        return out;
      }
    }

    // Fetch the target PBE from the record's pricebook and append it.
    Id recId = (Id) recordId;
    String sObjName = recId.getSobjectType().getDescribe().getName();
    Id pricebookId = null;
    if (sObjName == 'Opportunity') {
      Opportunity opp = [
        SELECT Pricebook2Id
        FROM Opportunity
        WHERE Id = :recId
        LIMIT 1
      ];
      pricebookId = opp.Pricebook2Id;
    } else if (sObjName == 'Order') {
      Order ord = [SELECT Pricebook2Id FROM Order WHERE Id = :recId LIMIT 1];
      pricebookId = ord.Pricebook2Id;
    }
    if (pricebookId == null) {
      pricebookId = getStandardPriceBookId();
    }
    if (pricebookId == null) {
      return out;
    }

    List<PricebookEntry> pbes = [
      SELECT
        Id,
        Name,
        Product2Id,
        UnitPrice,
        Floor__c,
        Window__c,
        Calculated_Price__c,
        Product2.Type__c,
        Product2.Sub_Type__c,
        Product2.State__c
      FROM PricebookEntry
      WHERE
        Id = :includePricebookEntryId
        AND Pricebook2Id = :pricebookId
        AND IsActive = TRUE
        AND Product2.IsActive = TRUE
      LIMIT 1
    ];
    if (pbes.isEmpty()) {
      return out;
    }

    out.add(new ProductData(pbes[0]));
    return out;
  }

  private class OccupancyInfo {
    Boolean isOccupied;
    String occupiedFrom;
    String occupiedTill;
    String occupyingAccountName;
    Id occupyingAccountId;
  }

  private static Map<Id, OccupancyInfo> getOccupancyByPeriod(
    Id recordId,
    List<PricebookEntry> pbes,
    Date periodStart,
    Date periodEnd
  ) {
    Map<Id, OccupancyInfo> result = new Map<Id, OccupancyInfo>();
    Set<Id> productIds = new Set<Id>();
    for (PricebookEntry pbe : pbes) {
      if (
        pbe.Product2 != null &&
        pbe.Product2.getPopulatedFieldsAsMap().containsKey('Type__c') &&
        (String) pbe.Product2.get('Type__c') == 'Standard Products' &&
        (
          !pbe.Product2.getPopulatedFieldsAsMap().containsKey('Sub_Type__c') ||
          (String) pbe.Product2.get('Sub_Type__c') != 'Hot Desk'
        )
      ) {
        productIds.add(pbe.Product2Id);
      }
    }
    if (productIds.isEmpty())
      return result;

    String sObjName = recordId.getSobjectType().getDescribe().getName();
    Id currentOrderId = (sObjName == 'Order') ? recordId : null;

    List<OrderItem> overlapping = [
      SELECT
        Id,
        Product2Id,
        OrderId,
        ServiceDate,
        EndDate,
        Contract__r.Account.Id,
        Contract__r.Account.Name,
        Contract__c
      FROM OrderItem
      WHERE
        Product2Id IN :productIds
        AND ServiceDate <= :periodEnd
        AND EndDate >= :periodStart
        AND Contract__r.Status = 'Activated'
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
    ];
    if (currentOrderId != null) {
      List<OrderItem> filtered = new List<OrderItem>();
      for (OrderItem oi : overlapping) {
        if (oi.OrderId != currentOrderId)
          filtered.add(oi);
      }
      overlapping = filtered;
    }

    for (Id pid : productIds) {
      OccupancyInfo oi = new OccupancyInfo();
      oi.isOccupied = false;
      oi.occupiedFrom = null;
      oi.occupiedTill = null;
      oi.occupyingAccountName = null;
      oi.occupyingAccountId = null;
      result.put(pid, oi);
    }
    for (OrderItem oi : overlapping) {
      OccupancyInfo oiInfo = result.get(oi.Product2Id);
      if (oiInfo == null)
        continue;
      oiInfo.isOccupied = true;
      if (oiInfo.occupiedFrom == null) {
        oiInfo.occupiedFrom = String.valueOf(oi.ServiceDate);
        oiInfo.occupiedTill = String.valueOf(oi.EndDate);
        if (oi.Contract__r != null && oi.Contract__r.Account != null) {
          oiInfo.occupyingAccountName = oi.Contract__r.Account.Name;
          oiInfo.occupyingAccountId = oi.Contract__r.Account.Id;
        }
      } else {
        oiInfo.occupyingAccountName = 'Multiple';
        oiInfo.occupyingAccountId = null;
      }
    }
    return result;
  }

  /**
   * Occupancy for a half-open modal period [periodStart, +infinity): activated contract lines that still
   * intersect the window (EndDate on/after period start, or null EndDate for open-ended lines).
   */
  private static Map<Id, OccupancyInfo> getOccupancyFromPeriodStartOpenEnded(
    Id recordId,
    List<PricebookEntry> pbes,
    Date periodStart
  ) {
    Map<Id, OccupancyInfo> result = new Map<Id, OccupancyInfo>();
    Set<Id> productIds = new Set<Id>();
    for (PricebookEntry pbe : pbes) {
      if (
        pbe.Product2 != null &&
        pbe.Product2.getPopulatedFieldsAsMap().containsKey('Type__c') &&
        (String) pbe.Product2.get('Type__c') == 'Standard Products' &&
        (
          !pbe.Product2.getPopulatedFieldsAsMap().containsKey('Sub_Type__c') ||
          (String) pbe.Product2.get('Sub_Type__c') != 'Hot Desk'
        )
      ) {
        productIds.add(pbe.Product2Id);
      }
    }
    if (productIds.isEmpty()) {
      return result;
    }

    String sObjName = recordId.getSobjectType().getDescribe().getName();
    Id currentOrderId = (sObjName == 'Order') ? recordId : null;

    List<OrderItem> overlapping = [
      SELECT
        Id,
        Product2Id,
        OrderId,
        ServiceDate,
        EndDate,
        Contract__r.Account.Id,
        Contract__r.Account.Name,
        Contract__c
      FROM OrderItem
      WHERE
        Product2Id IN :productIds
        AND (EndDate = NULL
        OR EndDate >= :periodStart)
        AND Contract__r.Status = 'Activated'
        AND (Is_Line_Deleted__c = FALSE
        OR Is_Line_Deleted__c = NULL)
    ];
    if (currentOrderId != null) {
      List<OrderItem> filtered = new List<OrderItem>();
      for (OrderItem oi : overlapping) {
        if (oi.OrderId != currentOrderId) {
          filtered.add(oi);
        }
      }
      overlapping = filtered;
    }

    for (Id pid : productIds) {
      OccupancyInfo oi = new OccupancyInfo();
      oi.isOccupied = false;
      oi.occupiedFrom = null;
      oi.occupiedTill = null;
      oi.occupyingAccountName = null;
      oi.occupyingAccountId = null;
      result.put(pid, oi);
    }
    for (OrderItem oi : overlapping) {
      OccupancyInfo oiInfo = result.get(oi.Product2Id);
      if (oiInfo == null) {
        continue;
      }
      oiInfo.isOccupied = true;
      if (oiInfo.occupiedFrom == null) {
        oiInfo.occupiedFrom = String.valueOf(oi.ServiceDate);
        oiInfo.occupiedTill = oi.EndDate != null
          ? String.valueOf(oi.EndDate)
          : null;
        if (oi.Contract__r != null && oi.Contract__r.Account != null) {
          oiInfo.occupyingAccountName = oi.Contract__r.Account.Name;
          oiInfo.occupyingAccountId = oi.Contract__r.Account.Id;
        }
      } else {
        oiInfo.occupyingAccountName = 'Multiple';
        oiInfo.occupyingAccountId = null;
      }
    }
    return result;
  }

  private static String getLocation(String recordId) {
    return null;
  }

  private static String getRecordTypeName(String recordId) {
    Id recId = (Id) recordId;
    String sObjName = recId.getSobjectType().getDescribe().getName();
    if (sObjName == 'Opportunity') {
      return '';
    }
    // Logic for Order? Maybe Order doesn't have Record Types or we don't filter products by Order Record Type yet.
    return '';
  }

  private static Set<Id> getExistingContracts(List<PricebookEntry> pbes) {
    Set<Id> existingContractsByProduct = new Set<Id>();
    List<string> productsIds = new List<string>();

    //get existing contracts for products:
    for (PricebookEntry pbe : pbes) {
      if (
        pbe.Product2 != null &&
        pbe.Product2.getPopulatedFieldsAsMap().containsKey('Type__c') &&
        (String) pbe.Product2.get('Type__c') == 'Standard Products' &&
        (
          !pbe.Product2.getPopulatedFieldsAsMap().containsKey('Sub_Type__c') ||
          (String) pbe.Product2.get('Sub_Type__c') != 'Hot Desk'
        )
      ) {
        productsIds.add(pbe.Product2Id);
      }
    }

    if (productsIds.size() > 0) {
      List<OrderItem> orderItems = [
        SELECT
          Id,
          Product2Id,
          Product2.Name,
          Access_Type__c,
          ServiceDate,
          EndDate,
          Contract__r.Account.Name,
          Contract__c,
          Contract__r.ContractNumber,
          Contract__r.Status
        FROM OrderItem
        WHERE Contract__r.Status = 'Activated' AND Product2Id IN :productsIds
      ];

      for (OrderItem item : orderItems) {
        existingContractsByProduct.add(item.Product2Id);
      }
    }

    return existingContractsByProduct;
  }

  private static String flipPackageBuilderAccessType(String current) {
    return PackageBuilderAccessTypePolicy.flipPackageBuilderAccessType(current);
  }

  private static String pastStartReplacementAccessType(
    String replacedAccessType,
    String replacementAccessTypeOverride
  ) {
    if (String.isNotBlank(replacementAccessTypeOverride)) {
      if ('FLIP'.equalsIgnoreCase(replacementAccessTypeOverride.trim())) {
        return flipPackageBuilderAccessType(replacedAccessType);
      }
      return replacementAccessTypeOverride.trim();
    }
    return flipPackageBuilderAccessType(replacedAccessType);
  }

  /** Resolve child Access Type for replace / past-start split (FLIP → flip helper). */
  private static String resolveReplacementChildAccessType(
    String replacedAccessType,
    String replacementAccessTypeOverride
  ) {
    if (String.isNotBlank(replacementAccessTypeOverride)) {
      if ('FLIP'.equalsIgnoreCase(replacementAccessTypeOverride.trim())) {
        return flipPackageBuilderAccessType(replacedAccessType);
      }
      return replacementAccessTypeOverride.trim();
    }
    return replacedAccessType;
  }

  private static String rollbackAndReturn(Savepoint sp, String message) {
    OrderItemTriggerHandler.cancelDeferredParentEndDateSync();
    if (sp != null) {
      Database.rollback(sp);
    }
    return message;
  }

  /** Test-only: after parent Removed update, fail so savepoint rollback can be asserted. */
  @TestVisible
  private static Boolean TEST_FORCE_FAIL_AFTER_PARENT_UPDATE = false;

  private static Boolean isMonthlyPackageAccess(String accessType) {
    return PackageBuilderAccessTypePolicy.isMonthlyPackageAccess(accessType);
  }

  @TestVisible
  private static String validateAccessTypeForAddProducts(
    List<String> productEntryIds,
    String accessTypeStr
  ) {
    if (productEntryIds == null || productEntryIds.isEmpty()) {
      return null;
    }
    if (String.isBlank(accessTypeStr)) {
      return 'Access Type is required.';
    }
    Set<Id> pbeIds = new Set<Id>();
    for (String raw : productEntryIds) {
      if (String.isNotBlank(raw)) {
        try {
          pbeIds.add((Id) raw);
        } catch (Exception ignored) {
        }
      }
    }
    if (pbeIds.isEmpty()) {
      return 'No products selected.';
    }
    for (PricebookEntry pbe : [
      SELECT Product2.Type__c, Product2.Rent__c
      FROM PricebookEntry
      WHERE Id IN :pbeIds
    ]) {
      if (
        !PackageBuilderAccessTypePolicy.isAccessTypeEligibleForProduct(
          accessTypeStr,
          pbe.Product2.Type__c,
          pbe.Product2.Rent__c == true
        )
      ) {
        return 'Access Type "' +
          accessTypeStr.trim() +
          '" is not allowed for one or more selected products.';
      }
    }
    return null;
  }

  @TestVisible
  private static void applyUsageBasedLinePricingAfterAdd(
    String sObjName,
    Id recId,
    Set<Id> selectedPricebookEntryIds,
    String accessTypeStr
  ) {
    if (
      !PackageBuilderAccessTypePolicy.isUsageBased(accessTypeStr) ||
      selectedPricebookEntryIds == null ||
      selectedPricebookEntryIds.isEmpty()
    ) {
      return;
    }
    if (sObjName == 'Order') {
      List<OrderItem> updates = new List<OrderItem>();
      for (OrderItem oi : [
        SELECT Id, Quantity, UnitPrice
        FROM OrderItem
        WHERE
          OrderId = :recId
          AND PricebookEntryId IN :selectedPricebookEntryIds
          AND Access_Type__c = :PackageBuilderAccessTypePolicy.ACCESS_TYPE_USAGE_BASED
      ]) {
        PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(oi);
        updates.add(oi);
      }
      if (!updates.isEmpty()) {
        update updates;
      }
    } else if (sObjName == 'Opportunity') {
      List<OpportunityLineItem> updates = new List<OpportunityLineItem>();
      for (OpportunityLineItem oli : [
        SELECT Id, Quantity, UnitPrice
        FROM OpportunityLineItem
        WHERE
          OpportunityId = :recId
          AND PricebookEntryId IN :selectedPricebookEntryIds
          AND Access_Type__c = :PackageBuilderAccessTypePolicy.ACCESS_TYPE_USAGE_BASED
      ]) {
        PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(oli);
        updates.add(oli);
      }
      if (!updates.isEmpty()) {
        update updates;
      }
    }
  }

  private static Date parsePeriodYmd(String ymd) {
    if (String.isBlank(ymd)) {
      return null;
    }
    String s = ymd.trim();
    if (s.length() >= 10) {
      s = s.substring(0, 10);
    }
    try {
      return Date.valueOf(s);
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * Resolves Order line ServiceDate/EndDate from modal period filters and order boundaries.
   * @return error message, or null if OK (entryDate/endDate populated).
   */
  private static Date orderStartDate(Order ord) {
    if (ord == null) {
      return null;
    }
    return ord.Order_Start_Date__c != null
      ? ord.Order_Start_Date__c
      : ord.EffectiveDate;
  }

  private static String resolveOrderAddProductDates(
    Order ord,
    String periodStartStr,
    String periodEndStr,
    Date[] entryDateOut,
    Date[] endDateOut
  ) {
    Date ps = parsePeriodYmd(periodStartStr);
    Date pe = parsePeriodYmd(periodEndStr);
    Date ordStart = orderStartDate(ord);

    if (ordStart != null && ps != null && ps < ordStart) {
      return ERR_PRODUCT_START_BEFORE_ORDER;
    }
    if (ordStart != null && pe != null && pe < ordStart) {
      return ERR_PERIOD_END_BEFORE_ORDER_START;
    }

    Date entryDate;
    if (ps != null) {
      entryDate = ps;
    } else {
      entryDate = Date.today();
      if (ordStart != null && entryDate < ordStart) {
        entryDate = ordStart;
      }
    }
    if (ordStart != null && entryDate < ordStart) {
      entryDate = ordStart;
    }

    Date endDate = pe;
    if (endDate != null && endDate < entryDate) {
      return ERR_PERIOD_END_BEFORE_PRODUCT_START;
    }
    if (ord.EndDate != null && endDate != null && endDate > ord.EndDate) {
      endDate = ord.EndDate;
    }
    entryDateOut[0] = entryDate;
    endDateOut[0] = endDate;
    return null;
  }

  @AuraEnabled(cacheable=true)
  public static String getContractAgreementType(String recordId) {
    if (String.isBlank(recordId))
      return null;

    Id recId = (Id) recordId;
    String sObjName = recId.getSobjectType().getDescribe().getName();

    try {
      // Avoid invalid relationship paths by first querying ContractId, then querying Contract.
      if (sObjName == 'Order') {
        List<Order> orders = [
          SELECT ContractId
          FROM Order
          WHERE Id = :recId
          LIMIT 1
        ];
        if (!orders.isEmpty() && orders[0].ContractId != null) {
          Contract c = [
            SELECT Agreement_Type__c
            FROM Contract
            WHERE Id = :orders[0].ContractId
            LIMIT 1
          ];
          return c.Agreement_Type__c;
        }
      } else if (sObjName == 'Opportunity') {
        List<Opportunity> opps = [
          SELECT ContractId
          FROM Opportunity
          WHERE Id = :recId
          LIMIT 1
        ];
        if (!opps.isEmpty() && opps[0].ContractId != null) {
          Contract c = [
            SELECT Agreement_Type__c
            FROM Contract
            WHERE Id = :opps[0].ContractId
            LIMIT 1
          ];
          return c.Agreement_Type__c;
        }
      }
    } catch (Exception e) {
      System.debug('getContractAgreementType error: ' + e.getMessage());
    }

    return null;
  }

  public static String addProducts(
    List<String> productEntryIds,
    String recordId,
    String periodStartStr,
    String periodEndStr,
    String accessTypeStr,
    String cpiDateStr
  ) {
    return addProducts(
      productEntryIds,
      recordId,
      periodStartStr,
      periodEndStr,
      accessTypeStr,
      cpiDateStr,
      null,
      false
    );
  }

  public static String addProducts(
    List<String> productEntryIds,
    String recordId,
    String periodStartStr,
    String periodEndStr,
    String accessTypeStr,
    String cpiDateStr,
    Map<String, Decimal> unitPriceOverrides
  ) {
    return addProducts(
      productEntryIds,
      recordId,
      periodStartStr,
      periodEndStr,
      accessTypeStr,
      cpiDateStr,
      unitPriceOverrides,
      false,
      null
    );
  }

  public static String addProducts(
    List<String> productEntryIds,
    String recordId,
    String periodStartStr,
    String periodEndStr,
    String accessTypeStr,
    String cpiDateStr,
    Map<String, Decimal> unitPriceOverrides,
    Boolean temporaryDefault
  ) {
    return addProducts(
      productEntryIds,
      recordId,
      periodStartStr,
      periodEndStr,
      accessTypeStr,
      cpiDateStr,
      unitPriceOverrides,
      temporaryDefault,
      null
    );
  }

  @AuraEnabled
  public static String addProducts(
    List<String> productEntryIds,
    String recordId,
    String periodStartStr,
    String periodEndStr,
    String accessTypeStr,
    String cpiDateStr,
    Map<String, Decimal> unitPriceOverrides,
    Boolean temporaryDefault,
    String notesDefault
  ) {
    System.debug(
      'addProducts recordId: ' +
        recordId +
        ', count: ' +
        (productEntryIds != null ? productEntryIds.size() : 0)
    );
    try {
      Id recId = (Id) recordId;
      String sObjName = recId.getSobjectType().getDescribe().getName();
      Set<Id> selectedPricebookEntryIds = new Set<Id>();
      if (productEntryIds != null) {
        for (String pbeId : productEntryIds) {
          if (String.isBlank(pbeId))
            continue;
          try {
            selectedPricebookEntryIds.add((Id) pbeId);
          } catch (Exception ignored) {
          }
        }
      }
      Map<Id, Decimal> overrideByPricebookEntryId = new Map<Id, Decimal>();
      if (unitPriceOverrides != null) {
        for (String key : unitPriceOverrides.keySet()) {
          if (String.isBlank(key))
            continue;
          Decimal value = unitPriceOverrides.get(key);
          if (value == null)
            continue;
          if (value < 0) {
            return 'Desk/Unit Price must be a non-negative number.';
          }
          try {
            overrideByPricebookEntryId.put((Id) key, value);
          } catch (Exception ignored) {
          }
        }
      }

      // Update opportunity/order with Standard Price Book if pricebook is empty
      Id standardPriceBookId = getStandardPriceBookId();
      if (standardPriceBookId != null) {
        if (sObjName == 'Opportunity') {
          Opportunity opp = [
            SELECT Pricebook2Id
            FROM Opportunity
            WHERE Id = :recId
          ];
          if (opp.Pricebook2Id == null) {
            opp.Pricebook2Id = standardPriceBookId;
            update opp;
            System.debug('Updated Opportunity with Standard Price Book');
          }
        } else if (sObjName == 'Order') {
          try {
            Order ord = [SELECT Pricebook2Id FROM Order WHERE Id = :recId];
            if (ord.Pricebook2Id == null) {
              ord.Pricebook2Id = standardPriceBookId;
              update ord;
              System.debug('Updated Order with Standard Price Book');
            }
          } catch (Exception e) {
            // Order pricebook might not be updatable after creation in some orgs
            // Continue anyway as getProductsByLocation will use Standard Price Book
            System.debug('Could not update Order pricebook: ' + e.getMessage());
          }
        }
      }

      String accessValidation = validateAccessTypeForAddProducts(
        productEntryIds,
        accessTypeStr
      );
      if (accessValidation != null) {
        return accessValidation;
      }

      Map<String, Object> inputVariables = new Map<String, Object>();
      inputVariables.put('InputVarProductEntryIds', productEntryIds);
      inputVariables.put(
        'VarAccessType',
        String.isNotBlank(accessTypeStr) ? accessTypeStr.trim() : null
      );
      // Defensive defaults: some flow versions use VarQuantity as a fallback when desk count is blank.
      // Always provide a non-null number so Create Records won't fail due to missing Quantity.
      inputVariables.put('VarQuantity', 1);

      if (sObjName == 'Opportunity') {
        Opportunity oppDates = [
          SELECT Start_Date__c
          FROM Opportunity
          WHERE Id = :recId
          LIMIT 1
        ];
        if (oppDates.Start_Date__c != null) {
          Date ps = parsePeriodYmd(periodStartStr);
          if (ps != null && ps < oppDates.Start_Date__c) {
            return ERR_PRODUCT_START_BEFORE_OPP;
          }
        }

        // Use the modal period filters as the OpportunityLineItem entry/end dates.
        // - Entry_Date__c = Period Start
        // - End_date__c = Period End (only when Available To is provided)
        Date entryDate = parsePeriodYmd(periodStartStr);
        if (entryDate == null) {
          entryDate = oppDates.Start_Date__c != null
            ? oppDates.Start_Date__c
            : Date.today();
        }

        Date endDate = parsePeriodYmd(periodEndStr);

        inputVariables.put('VarEntryDate', entryDate);
        inputVariables.put('VarEndDate', endDate);
        inputVariables.put('VarCpiDate', parsePeriodYmd(cpiDateStr));
      } else if (sObjName == 'Order') {
        List<Order> ordForFlow = [
          SELECT EffectiveDate, Order_Start_Date__c, EndDate, ContractId
          FROM Order
          WHERE Id = :recId
          LIMIT 1
        ];
        if (ordForFlow.isEmpty()) {
          return 'Order not found.';
        }
        Date psMerge = parsePeriodYmd(periodStartStr);
        Date peMerge = parsePeriodYmd(periodEndStr);
        Date ordStartMerge = orderStartDate(ordForFlow[0]);
        Date entryForMerge = psMerge;
        if (entryForMerge == null) {
          entryForMerge = Date.today();
          if (ordStartMerge != null && entryForMerge < ordStartMerge) {
            entryForMerge = ordStartMerge;
          }
        }
        if (
          ordStartMerge != null &&
          entryForMerge != null &&
          entryForMerge < ordStartMerge
        ) {
          entryForMerge = ordStartMerge;
        }
        Boolean proposedOpenEnded =
          PackageBuilderAccessTypePolicy.isMonthlyLike(accessTypeStr) &&
          String.isBlank(periodEndStr);
        PackageEndDateRollupService.OrderEndRollupState rollupState = PackageEndDateRollupService.computeOrderEndRollupState(
          recId
        );
        Date targetOrderEnd = PackageEndDateRollupService.mergeProposedIntoTargetOrderEnd(
          rollupState,
          entryForMerge,
          peMerge,
          proposedOpenEnded
        );
        Boolean orderEndNeedsApply =
          (targetOrderEnd == null && ordForFlow[0].EndDate != null) ||
          (targetOrderEnd != null &&
          (ordForFlow[0].EndDate == null ||
          targetOrderEnd != ordForFlow[0].EndDate));
        if (orderEndNeedsApply) {
          PackageEndDateRollupService.applyContractThenOrderEndForPackage(
            recId,
            targetOrderEnd
          );
          ordForFlow = [
            SELECT EffectiveDate, Order_Start_Date__c, EndDate, ContractId
            FROM Order
            WHERE Id = :recId
            LIMIT 1
          ];
        }
        Date[] entryOut = new Date[1];
        Date[] endOut = new Date[1];
        String dateErr = resolveOrderAddProductDates(
          ordForFlow[0],
          periodStartStr,
          periodEndStr,
          entryOut,
          endOut
        );
        if (String.isNotBlank(dateErr)) {
          return dateErr;
        }

        inputVariables.put('VarEntryDate', entryOut[0]);
        inputVariables.put('VarEndDate', endOut[0]);
        inputVariables.put('VarCpiDate', parsePeriodYmd(cpiDateStr));
      }

      Flow.Interview flowInterview;

      if (sObjName == 'Opportunity') {
        inputVariables.put('InputVarOportuntiyId', recordId);
        inputVariables.put('VarTemporary', temporaryDefault == true);
        // Package Builder "Add Products" is multi-select; the flow that accepts InputVarProductEntryIds is the 2_0 version.
        flowInterview = Flow.Interview.createInterview(
          'Opportunity_Package_Builder_Manage_Opportunity_Products_2_0',
          inputVariables
        );
      } else if (sObjName == 'Order') {
        inputVariables.put('InputVarOrderId', recordId);
        flowInterview = Flow.Interview.createInterview(
          'Order_Package_Builder_Manage_Order_Products',
          inputVariables
        );
      } else {
        return 'Unsupported Object Type: ' + sObjName;
      }

      // Start the flow
      Set<Id> orderItemIdsBeforeAdd = new Set<Id>();
      if (sObjName == 'Order' && !selectedPricebookEntryIds.isEmpty()) {
        for (OrderItem existingOi : [
          SELECT Id
          FROM OrderItem
          WHERE
            OrderId = :recId
            AND PricebookEntryId IN :selectedPricebookEntryIds
        ]) {
          orderItemIdsBeforeAdd.add(existingOi.Id);
        }
      }
      Set<Id> opportunityLineItemIdsBeforeAdd = new Set<Id>();
      if (sObjName == 'Opportunity' && !selectedPricebookEntryIds.isEmpty()) {
        for (OpportunityLineItem existingOli : [
          SELECT Id
          FROM OpportunityLineItem
          WHERE
            OpportunityId = :recId
            AND PricebookEntryId IN :selectedPricebookEntryIds
        ]) {
          opportunityLineItemIdsBeforeAdd.add(existingOli.Id);
        }
      }

      flowInterview.start();

      // Retrieve output variable 'AddErrorMessage'
      Object error = flowInterview.getVariableValue('AddErrorMessage');
      if (error != null && String.isNotBlank((String) error)) {
        System.debug('Flow returned error: ' + error);
        return (String) error;
      }

      applyUsageBasedLinePricingAfterAdd(
        sObjName,
        recId,
        selectedPricebookEntryIds,
        accessTypeStr
      );

      if (sObjName == 'Order' && !selectedPricebookEntryIds.isEmpty()) {
        applyTemporaryOnOrderProductsAfterAdd(
          recId,
          selectedPricebookEntryIds,
          temporaryDefault == true,
          orderItemIdsBeforeAdd
        );
        applyNotesOnOrderProductsAfterAdd(
          recId,
          selectedPricebookEntryIds,
          notesDefault,
          orderItemIdsBeforeAdd
        );
      }
      if (sObjName == 'Opportunity' && !selectedPricebookEntryIds.isEmpty()) {
        applyTemporaryOnOpportunityProductsAfterAdd(
          recId,
          selectedPricebookEntryIds,
          temporaryDefault == true,
          opportunityLineItemIdsBeforeAdd
        );
        applyNotesOnOpportunityProductsAfterAdd(
          recId,
          selectedPricebookEntryIds,
          notesDefault,
          opportunityLineItemIdsBeforeAdd
        );
      }

      if (
        !selectedPricebookEntryIds.isEmpty() &&
        !overrideByPricebookEntryId.isEmpty() &&
        !PackageBuilderAccessTypePolicy.isUsageBased(accessTypeStr)
      ) {
        if (sObjName == 'Order') {
          List<OrderItem> updates = new List<OrderItem>();
          for (OrderItem oi : [
            SELECT Id, PricebookEntryId, UnitPrice
            FROM OrderItem
            WHERE
              OrderId = :recId
              AND PricebookEntryId IN :selectedPricebookEntryIds
          ]) {
            Decimal overridePrice = overrideByPricebookEntryId.get(
              oi.PricebookEntryId
            );
            if (overridePrice == null)
              continue;
            if (oi.UnitPrice != overridePrice) {
              oi.UnitPrice = overridePrice;
              updates.add(oi);
            }
          }
          if (!updates.isEmpty()) {
            update updates;
          }
        } else if (sObjName == 'Opportunity') {
          List<OpportunityLineItem> updates = new List<OpportunityLineItem>();
          for (OpportunityLineItem oli : [
            SELECT Id, PricebookEntryId, UnitPrice
            FROM OpportunityLineItem
            WHERE
              OpportunityId = :recId
              AND PricebookEntryId IN :selectedPricebookEntryIds
          ]) {
            Decimal overridePrice = overrideByPricebookEntryId.get(
              oli.PricebookEntryId
            );
            if (overridePrice == null)
              continue;
            if (oli.UnitPrice != overridePrice) {
              oli.UnitPrice = overridePrice;
              updates.add(oli);
            }
          }
          if (!updates.isEmpty()) {
            update updates;
          }
        }
      }
      return '';
    } catch (Exception e) {
      System.debug(
        'Exception in addProducts: ' +
          e.getMessage() +
          ' at ' +
          e.getStackTraceString()
      );
      return 'Apex Error: ' + e.getMessage();
    }
  }

  /**
   * After Order Add Products flow: apply Temporary only on newly inserted lines
   * (Ids not present before the flow). Other-site products are forced Temporary true;
   * same-site uses the Add Products Temporary checkbox.
   */
  private static void applyTemporaryOnOrderProductsAfterAdd(
    Id orderId,
    Set<Id> selectedPricebookEntryIds,
    Boolean temporaryDefault,
    Set<Id> orderItemIdsBeforeAdd
  ) {
    if (
      orderId == null ||
      selectedPricebookEntryIds == null ||
      selectedPricebookEntryIds.isEmpty()
    ) {
      return;
    }
    Set<Id> beforeIds = orderItemIdsBeforeAdd != null
      ? orderItemIdsBeforeAdd
      : new Set<Id>();
    Order ord = [
      SELECT Id
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    List<OrderItem> updates = new List<OrderItem>();
    for (OrderItem oi : [
      SELECT Id, Temporary__c, PricebookEntryId
      FROM OrderItem
      WHERE
        OrderId = :orderId
        AND PricebookEntryId IN :selectedPricebookEntryIds
        AND Id NOT IN :beforeIds
    ]) {
      Boolean desired = temporaryDefault == true;
      if (oi.Temporary__c != desired) {
        oi.Temporary__c = desired;
        updates.add(oi);
      }
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  /**
   * After Opportunity Add Products flow: apply Temporary only on newly inserted lines.
   * Other-site products are forced Temporary true; same-site uses the checkbox.
   */
  private static void applyTemporaryOnOpportunityProductsAfterAdd(
    Id opportunityId,
    Set<Id> selectedPricebookEntryIds,
    Boolean temporaryDefault,
    Set<Id> opportunityLineItemIdsBeforeAdd
  ) {
    if (
      opportunityId == null ||
      selectedPricebookEntryIds == null ||
      selectedPricebookEntryIds.isEmpty()
    ) {
      return;
    }
    Set<Id> beforeIds = opportunityLineItemIdsBeforeAdd != null
      ? opportunityLineItemIdsBeforeAdd
      : new Set<Id>();
    Opportunity opp = [
      SELECT Id
      FROM Opportunity
      WHERE Id = :opportunityId
      LIMIT 1
    ];
    List<OpportunityLineItem> updates = new List<OpportunityLineItem>();
    for (OpportunityLineItem oli : [
      SELECT Id, Temporary__c, PricebookEntryId
      FROM OpportunityLineItem
      WHERE
        OpportunityId = :opportunityId
        AND PricebookEntryId IN :selectedPricebookEntryIds
        AND Id NOT IN :beforeIds
    ]) {
      Boolean desired = temporaryDefault == true;
      if (oli.Temporary__c != desired) {
        oli.Temporary__c = desired;
        updates.add(oli);
      }
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  private static String normalizeNotesDefault(String notesDefault) {
    if (String.isBlank(notesDefault)) {
      return null;
    }
    String notes = notesDefault.trim();
    if (String.isBlank(notes)) {
      return null;
    }
    return notes.length() > 255 ? notes.substring(0, 255) : notes;
  }

  /**
   * After Order Add Products flow: apply Notes (Description) only on newly inserted lines.
   * Blank Notes skips the update so existing Description is left unchanged.
   */
  private static void applyNotesOnOrderProductsAfterAdd(
    Id orderId,
    Set<Id> selectedPricebookEntryIds,
    String notesDefault,
    Set<Id> orderItemIdsBeforeAdd
  ) {
    String notes = normalizeNotesDefault(notesDefault);
    if (
      notes == null ||
      orderId == null ||
      selectedPricebookEntryIds == null ||
      selectedPricebookEntryIds.isEmpty()
    ) {
      return;
    }
    Set<Id> beforeIds = orderItemIdsBeforeAdd != null
      ? orderItemIdsBeforeAdd
      : new Set<Id>();
    List<OrderItem> updates = new List<OrderItem>();
    for (OrderItem oi : [
      SELECT Id, Description
      FROM OrderItem
      WHERE
        OrderId = :orderId
        AND PricebookEntryId IN :selectedPricebookEntryIds
        AND Id NOT IN :beforeIds
    ]) {
      if (oi.Description != notes) {
        oi.Description = notes;
        updates.add(oi);
      }
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  /**
   * After Opportunity Add Products flow: apply Notes (Description) only on newly inserted lines.
   */
  private static void applyNotesOnOpportunityProductsAfterAdd(
    Id opportunityId,
    Set<Id> selectedPricebookEntryIds,
    String notesDefault,
    Set<Id> opportunityLineItemIdsBeforeAdd
  ) {
    String notes = normalizeNotesDefault(notesDefault);
    if (
      notes == null ||
      opportunityId == null ||
      selectedPricebookEntryIds == null ||
      selectedPricebookEntryIds.isEmpty()
    ) {
      return;
    }
    Set<Id> beforeIds = opportunityLineItemIdsBeforeAdd != null
      ? opportunityLineItemIdsBeforeAdd
      : new Set<Id>();
    List<OpportunityLineItem> updates = new List<OpportunityLineItem>();
    for (OpportunityLineItem oli : [
      SELECT Id, Description
      FROM OpportunityLineItem
      WHERE
        OpportunityId = :opportunityId
        AND PricebookEntryId IN :selectedPricebookEntryIds
        AND Id NOT IN :beforeIds
    ]) {
      if (oli.Description != notes) {
        oli.Description = notes;
        updates.add(oli);
      }
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  public static String addReplacementProduct(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    String cpiDateStr,
    Decimal replacementQuantity,
    String replacementDescription,
    Boolean openEndedReplacement
  ) {
    return addReplacementProduct(
      productEntryId,
      orderId,
      replacedOrderItemId,
      periodStartStr,
      periodEndStr,
      cpiDateStr,
      replacementQuantity,
      replacementDescription,
      openEndedReplacement,
      null
    );
  }

  /**
   * Past-start split for Package Builder quantity or access-type change (869dk2u53).
   * @param splitMode quantity | accessType
   */
  public static String addPastStartSplitLine(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    Decimal replacementQuantity,
    String splitMode
  ) {
    return addPastStartSplitLine(
      productEntryId,
      orderId,
      replacedOrderItemId,
      periodStartStr,
      periodEndStr,
      replacementQuantity,
      splitMode,
      null
    );
  }

  @AuraEnabled
  public static String addPastStartSplitLine(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    Decimal replacementQuantity,
    String splitMode,
    String replacementAccessTypeStr
  ) {
    String mode = String.isBlank(splitMode)
      ? ''
      : splitMode.trim().toLowerCase();
    Boolean markChangedAccessType = mode == 'accesstype';
    String accessOverride = null;
    if (markChangedAccessType) {
      if (String.isNotBlank(replacementAccessTypeStr)) {
        accessOverride = replacementAccessTypeStr.trim();
        String accessValidation = validateAccessTypeForAddProducts(
          new List<String>{ productEntryId },
          accessOverride
        );
        if (accessValidation != null) {
          return accessValidation;
        }
      } else {
        accessOverride = 'FLIP';
      }
    }
    return addReplacementProductInternal(
      productEntryId,
      orderId,
      replacedOrderItemId,
      periodStartStr,
      periodEndStr,
      null,
      replacementQuantity,
      null,
      false,
      null,
      accessOverride,
      markChangedAccessType,
      true,
      false
    );
  }

  public static String addReplacementProduct(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    String cpiDateStr,
    Decimal replacementQuantity,
    String replacementDescription,
    Boolean openEndedReplacement,
    Decimal replacementUnitPrice
  ) {
    return addReplacementProduct(
      productEntryId,
      orderId,
      replacedOrderItemId,
      periodStartStr,
      periodEndStr,
      cpiDateStr,
      replacementQuantity,
      replacementDescription,
      openEndedReplacement,
      replacementUnitPrice,
      false
    );
  }

  @AuraEnabled
  public static String addReplacementProduct(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    String cpiDateStr,
    Decimal replacementQuantity,
    String replacementDescription,
    Boolean openEndedReplacement,
    Decimal replacementUnitPrice,
    Boolean transferPrice
  ) {
    return addReplacementProductInternal(
      productEntryId,
      orderId,
      replacedOrderItemId,
      periodStartStr,
      periodEndStr,
      cpiDateStr,
      replacementQuantity,
      replacementDescription,
      openEndedReplacement,
      replacementUnitPrice,
      null,
      false,
      false,
      transferPrice == true
    );
  }

  private static String addReplacementProductInternal(
    String productEntryId,
    String orderId,
    String replacedOrderItemId,
    String periodStartStr,
    String periodEndStr,
    String cpiDateStr,
    Decimal replacementQuantity,
    String replacementDescription,
    Boolean openEndedReplacement,
    Decimal replacementUnitPrice,
    String replacementAccessTypeOverride,
    Boolean markChangedAccessType,
    Boolean pastStartSplit,
    Boolean transferPrice
  ) {
    if (
      String.isBlank(productEntryId) ||
      String.isBlank(orderId) ||
      String.isBlank(replacedOrderItemId)
    ) {
      return 'Missing required parameters: productEntryId, orderId, or replacedOrderItemId.';
    }
    Savepoint mutationSp = null;
    try {
      Id ordId = (Id) orderId;
      Id repId = (Id) replacedOrderItemId;
      if (ordId.getSobjectType() != Order.SObjectType) {
        return 'Invalid order Id.';
      }

      Date periodStart = String.isNotBlank(periodStartStr)
        ? Date.valueOf(periodStartStr)
        : Date.today();
      Boolean openEnd = openEndedReplacement == true;
      Date periodEnd = openEnd
        ? null
        : (String.isNotBlank(periodEndStr) ? Date.valueOf(periodEndStr) : null);

      List<Order> orders = [
        SELECT
          Id,
          Status,
          EffectiveDate,
          Order_Start_Date__c,
          EndDate,
          Pricebook2Id,
          ContractId
        FROM Order
        WHERE Id = :ordId
        LIMIT 1
      ];
      if (orders.isEmpty()) {
        return 'Order not found.';
      }
      Order ord = orders[0];
      if (ord.Status == 'Activated') {
        return 'This order is Activated, so Order Products cannot be added or removed. Please move the order to Draft or use the change process.';
      }

      // Customer package end for line-item validation: prefer the tighter of Order vs linked Contract end.
      Date customerPackageEnd = ord.EndDate;
      if (ord.ContractId != null) {
        List<Contract> cons = [
          SELECT EndDate
          FROM Contract
          WHERE Id = :ord.ContractId
          LIMIT 1
        ];
        if (!cons.isEmpty() && cons[0].EndDate != null) {
          if (
            customerPackageEnd == null ||
            cons[0].EndDate < customerPackageEnd
          ) {
            customerPackageEnd = cons[0].EndDate;
          }
        }
      }

      List<OrderItem> replacedItems = [
        SELECT
          Id,
          ServiceDate,
          EndDate,
          Access_Type__c,
          UnitPrice,
          Quantity,
          CPI_Date__c,
          Description,
          Temporary__c
        FROM OrderItem
        WHERE Id = :repId AND OrderId = :ordId
        LIMIT 1
      ];
      if (replacedItems.isEmpty()) {
        return 'The product being replaced is not on this order.';
      }
      OrderItem replacedItem = replacedItems[0];
      Decimal replacedUnitPrice = replacedItem.UnitPrice;
      Decimal replacedQty = replacedItem.Quantity;
      String replacedAccessType = replacedItem.Access_Type__c;
      Boolean isPastStartSplit = pastStartSplit == true;
      Boolean replacedIsMonthly = isMonthlyPackageAccess(replacedAccessType);
      // Monthly is open-ended; ignore stale EndDate left from legacy data or pre-clear migrations.
      Date replacedOriginalEnd = replacedIsMonthly
        ? null
        : replacedItem.EndDate;

      Date today = Date.today();
      if (
        !replacedIsMonthly &&
        replacedItem.EndDate != null &&
        replacedItem.EndDate < today
      ) {
        if (isPastStartSplit) {
          return 'Extend the end date before changing quantity or access type.';
        }
        return 'This product has already ended (end date is before today). It cannot be replaced.';
      }
      if (periodEnd != null && periodStart > periodEnd) {
        return 'Period start date cannot be after period end date. Adjust the period filters or pick a different product.';
      }
      if (isPastStartSplit) {
        if (replacedItem.ServiceDate == null) {
          return 'Product start date is required for this change.';
        }
        if (replacedItem.ServiceDate >= today) {
          return 'Past-start split applies only when the product start date is before today.';
        }
        Date minStart = replacedItem.ServiceDate.addDays(1);
        Date contractStart = ord.Order_Start_Date__c;
        if (contractStart != null && contractStart > minStart) {
          minStart = contractStart;
        }
        if (periodStart < minStart) {
          return 'Start date must be on or after ' +
            String.valueOf(minStart) +
            (contractStart != null &&
              minStart == contractStart
              ? ' (Contract Start Date).'
              : ' (day after the current product start date).');
        }
        if (replacedOriginalEnd != null && periodStart > replacedOriginalEnd) {
          return 'Start date cannot be after the product end date (' +
            String.valueOf(replacedOriginalEnd) +
            ').';
        }
        if (replacedOriginalEnd == null) {
          if (
            markChangedAccessType == true && String.isNotBlank(periodEndStr)
          ) {
            Date newLineEnd = Date.valueOf(periodEndStr);
            if (newLineEnd < periodStart) {
              return 'End date cannot be before start date.';
            }
          } else if (
            !replacedIsMonthly &&
            !(markChangedAccessType == true &&
            isMonthlyPackageAccess(
              pastStartReplacementAccessType(
                replacedAccessType,
                replacementAccessTypeOverride
              )
            ))
          ) {
            return 'Product end date is required before changing quantity or access type.';
          }
        } else if (
          markChangedAccessType == true && String.isNotBlank(periodEndStr)
        ) {
          Date newLineEnd = Date.valueOf(periodEndStr);
          if (newLineEnd < periodStart) {
            return 'End date cannot be before start date.';
          }
        }
        if (
          markChangedAccessType == true &&
          !isMonthlyPackageAccess(
            pastStartReplacementAccessType(
              replacedAccessType,
              replacementAccessTypeOverride
            )
          ) &&
          String.isBlank(periodEndStr) &&
          replacedOriginalEnd == null
        ) {
          return 'End date is required for the new line.';
        }
      }

      if (isPastStartSplit && replacementQuantity != null) {
        if (replacementQuantity < 0) {
          return 'Quantity must be zero or greater.';
        }
        if (replacedQty != null && replacementQuantity == replacedQty) {
          return 'New quantity must differ from the current quantity.';
        }
      }

      if (openEnd) {
        PackageEndDateRollupService.OrderEndRollupState rollupState = PackageEndDateRollupService.computeOrderEndRollupState(
          ordId
        );
        if (rollupState != null && rollupState.openEndedIncluded != true) {
          Date maxStandardEnd = rollupState.maxBoundedEnd;
          if (maxStandardEnd != null && periodStart > maxStandardEnd) {
            return 'All products are ending on ' +
              String.valueOf(maxStandardEnd) +
              '. Extend the product end dates before replacing contract terms.';
          }
        }
      }

      Id pricebookId = ord.Pricebook2Id;
      if (pricebookId == null) {
        pricebookId = getStandardPriceBookId();
      }
      if (pricebookId == null) {
        return 'Order has no Pricebook and Standard Pricebook could not be determined.';
      }

      List<PricebookEntry> pbes = [
        SELECT
          Id,
          Product2Id,
          UnitPrice,
            Product2.Type__c,
          Product2.Rent__c
        FROM PricebookEntry
        WHERE Id = :productEntryId AND Pricebook2Id = :pricebookId
        LIMIT 1
      ];
      if (pbes.isEmpty()) {
        return 'Product not found in the order Pricebook.';
      }
      PricebookEntry pbe = pbes[0];
      Decimal effectiveUnitPrice = replacementUnitPrice;
      Boolean applyTransferPrice =
        transferPrice == true &&
        isPastStartSplit != true;
      if (
        isPastStartSplit &&
        effectiveUnitPrice == null &&
        replacedUnitPrice != null
      ) {
        effectiveUnitPrice = replacedUnitPrice;
      }
      if (effectiveUnitPrice != null && effectiveUnitPrice < 0) {
        return 'Desk/Unit Price must be a non-negative number.';
      }

      Decimal qty;
      if (replacementQuantity != null) {
        if (replacementQuantity < 0) {
          return 'Quantity must be zero or greater.';
        }
        qty = replacementQuantity;
      } else if (isPastStartSplit && replacedQty != null) {
        qty = replacedQty;
      } else {
        qty = (pbe.Product2.Type__c == 'Standard Products' &&
          false)
          ? null
          : 1;
      }

      if (applyTransferPrice) {
        effectiveUnitPrice = TransferPriceService.unitPriceFromTransferredDeal(
          replacedUnitPrice,
          replacedQty,
          qty
        );
      }

      String childAccessType = resolveReplacementChildAccessType(
        replacedAccessType,
        replacementAccessTypeOverride
      );
      if (String.isNotBlank(childAccessType)) {
        String accessValidation = validateAccessTypeForAddProducts(
          new List<String>{ productEntryId },
          childAccessType
        );
        if (accessValidation != null) {
          return accessValidation;
        }
      }

      // Replaced (old) product: EndDate = periodStart - 1, clamped to order boundaries
      Date replacedNewEnd = periodStart.addDays(-1);
      if (
        replacedItem.ServiceDate != null &&
        replacedNewEnd < replacedItem.ServiceDate
      ) {
        replacedNewEnd = replacedItem.ServiceDate;
      }
      if (customerPackageEnd != null && replacedNewEnd > customerPackageEnd) {
        replacedNewEnd = customerPackageEnd;
      }

      List<TransferPriceService.MonthTerm> transferSourceTerms = TransferPriceService.snapshotTermsFromOrderItem(
        repId,
        periodStart
      );

      mutationSp = Database.setSavepoint();
      OrderItemTriggerHandler.beginDeferredParentEndDateSync();
      replacedItem.EndDate = replacedNewEnd;
      replacedItem.Change_Type__c = 'Removed';
      update replacedItem;
      TransferPriceService.scaleCurtailedLineToReplaceStart(
        repId,
        periodStart,
        transferSourceTerms
      );

      if (TEST_FORCE_FAIL_AFTER_PARENT_UPDATE == true) {
        return rollbackAndReturn(
          mutationSp,
          'Forced failure after parent update (test).'
        );
      }

      ord = [
        SELECT
          Id,
          Status,
          EffectiveDate,
          Order_Start_Date__c,
          EndDate,
          Pricebook2Id,
          ContractId
        FROM Order
        WHERE Id = :ordId
        LIMIT 1
      ];

      // Replacement (new) product: start = periodStart (floor = order start only; package end extends forward when needed).
      Date serviceDate = periodStart;
      Date ordStart = orderStartDate(ord);
      if (ordStart != null && serviceDate < ordStart) {
        serviceDate = ordStart;
      }
      Date endDate;
      if (openEnd) {
        // Contract-term replace: new line stays open-ended (no EndDate / Original End).
        endDate = null;
      } else if (
        isPastStartSplit &&
        markChangedAccessType == true &&
        isMonthlyPackageAccess(
          pastStartReplacementAccessType(
            replacedAccessType,
            replacementAccessTypeOverride
          )
        )
      ) {
        endDate = null;
      } else if (
        isPastStartSplit &&
        markChangedAccessType == true &&
        String.isNotBlank(periodEndStr)
      ) {
        endDate = Date.valueOf(periodEndStr);
      } else if (
        isPastStartSplit &&
        markChangedAccessType != true &&
        isMonthlyPackageAccess(replacedAccessType)
      ) {
        endDate = null;
      } else if (isPastStartSplit && replacedOriginalEnd != null) {
        endDate = replacedOriginalEnd;
      } else {
        endDate = periodEnd;
        if (endDate == null && ord.EndDate != null) {
          endDate = ord.EndDate;
        }
        if (endDate == null) {
          endDate = serviceDate;
        }
        if (endDate != null && endDate < serviceDate) {
          endDate = serviceDate;
        }
      }

      PackageEndDateRollupService.OrderEndRollupState repRollupState = PackageEndDateRollupService.computeOrderEndRollupState(
        ordId
      );
      Date targetOrderEndForReplace = PackageEndDateRollupService.mergeProposedIntoTargetOrderEnd(
        repRollupState,
        serviceDate,
        endDate,
        openEnd
      );
      Boolean replaceOrderEndNeedsApply =
        (targetOrderEndForReplace == null && ord.EndDate != null) ||
        (targetOrderEndForReplace != null &&
        (ord.EndDate == null ||
        targetOrderEndForReplace != ord.EndDate));
      if (replaceOrderEndNeedsApply) {
        try {
          PackageEndDateRollupService.applyContractThenOrderEndForPackage(
            ordId,
            targetOrderEndForReplace
          );
        } catch (Exception rollupEx) {
          return rollbackAndReturn(
            mutationSp,
            'Apex Error: ' + rollupEx.getMessage()
          );
        }
        ord = [
          SELECT
            Id,
            Status,
            EffectiveDate,
            Order_Start_Date__c,
            EndDate,
            Pricebook2Id,
            ContractId
          FROM Order
          WHERE Id = :ordId
          LIMIT 1
        ];
      }
      if (
        !openEnd &&
        endDate != null &&
        ord.EndDate != null &&
        endDate > ord.EndDate
      ) {
        endDate = ord.EndDate;
      }
      if (endDate != null && endDate < serviceDate) {
        endDate = serviceDate;
      }

      OrderItem oi = new OrderItem(
        OrderId = ordId,
        PricebookEntryId = pbe.Id,
        Product2Id = pbe.Product2Id,
        Quantity = qty,
        UnitPrice = effectiveUnitPrice != null
          ? effectiveUnitPrice
          : pbe.UnitPrice,
        ServiceDate = serviceDate,
        EndDate = endDate,
        Change_Type__c = 'New',
        Replaced_Order_Product__c = repId,
        Temporary__c = replacedItem.Temporary__c == true,
        Transfer_Price__c = applyTransferPrice == true
      );
      if (String.isNotBlank(childAccessType)) {
        oi.Access_Type__c = childAccessType;
      }
      if (markChangedAccessType == true) {
        oi.Changed_Access_Type__c = true;
      }
      PackageBuilderAccessTypePolicy.syncLinePricingForAccessTypeChange(
        oi,
        replacedAccessType,
        oi.Access_Type__c,
        pbe.UnitPrice
      );
      oi.CPI_Date__c = isPastStartSplit && replacedItem.CPI_Date__c != null
        ? replacedItem.CPI_Date__c
        : parsePeriodYmd(cpiDateStr);
      if (String.isNotBlank(replacementDescription)) {
        oi.Description = replacementDescription.trim();
      } else if (
        isPastStartSplit && String.isNotBlank(replacedItem.Description)
      ) {
        oi.Description = replacedItem.Description;
      }
      try {
        insert oi;
      } catch (DmlException dmle) {
        // Some orgs enforce a customer package end not exposed on Order/Contract EndDate; retry minimal term.
        String msg = dmle.getNumDml() > 0
          ? dmle.getDmlMessage(0)
          : dmle.getMessage();
        if (msg != null && msg.contains('Customer Package')) {
          if (openEnd) {
            return rollbackAndReturn(mutationSp, 'Apex Error: ' + msg);
          }
          oi.EndDate = serviceDate;
          try {
            insert oi;
          } catch (DmlException dmle2) {
            String msg2 = dmle2.getNumDml() > 0
              ? dmle2.getDmlMessage(0)
              : dmle2.getMessage();
            return rollbackAndReturn(mutationSp, 'Apex Error: ' + msg2);
          }
        } else {
          return rollbackAndReturn(mutationSp, 'Apex Error: ' + msg);
        }
      }
      if (applyTransferPrice) {
        try {
          TransferPriceService.applyToReplacementLine(
            oi.Id,
            serviceDate,
            transferSourceTerms
          );
        } catch (Exception transferEx) {
          return rollbackAndReturn(
            mutationSp,
            'Apex Error: ' + transferEx.getMessage()
          );
        }
      }
      OrderItemTriggerHandler.endDeferredParentEndDateSync();
      return '';
    } catch (Exception e) {
      OrderItemTriggerHandler.cancelDeferredParentEndDateSync();
      if (mutationSp != null) {
        Database.rollback(mutationSp);
      }
      System.debug(
        'Exception in addReplacementProduct: ' +
          e.getMessage() +
          ' at ' +
          e.getStackTraceString()
      );
      return 'Apex Error: ' + e.getMessage();
    }
  }

  public class ProductData {
    @AuraEnabled
    public string Id { get; set; }
    @AuraEnabled
    public string Name { get; set; }
    @AuraEnabled
    public Decimal CapacityDesks { get; set; }
    @AuraEnabled
    public Decimal UnitPrice { get; set; }
    @AuraEnabled
    public Decimal Floor { get; set; }
    @AuraEnabled
    public Boolean Window { get; set; }
    @AuraEnabled
    public Decimal CalculatedPrice { get; set; }
    @AuraEnabled
    public string ProductType { get; set; }
    @AuraEnabled
    public string ProductSubType { get; set; }
    @AuraEnabled
    public string ProductState { get; set; }
    @AuraEnabled
    public string Availability { get; set; }
    @AuraEnabled
    public Boolean IsOccupiedInPeriod { get; set; }
    @AuraEnabled
    public String OccupiedFrom { get; set; }
    @AuraEnabled
    public String OccupiedTill { get; set; }
    @AuraEnabled
    public String OccupyingAccountName { get; set; }
    @AuraEnabled
    public String OccupyingAccountId { get; set; }
    @AuraEnabled
    public Boolean RentEligible { get; set; }

    public ProductData(PricebookEntry prod) {
      this.Id = prod.Id;
      this.Name = prod.Name;
      this.CapacityDesks = null;
      this.UnitPrice = prod.UnitPrice;
      Map<String, Object> pbeFields = prod.getPopulatedFieldsAsMap();
      this.Floor = pbeFields.containsKey('Floor__c')
        ? (Decimal) prod.get('Floor__c')
        : null;
      this.Window = pbeFields.containsKey('Window__c')
        ? (Boolean) prod.get('Window__c')
        : null;
      this.CalculatedPrice = pbeFields.containsKey('Calculated_Price__c')
        ? (Decimal) prod.get('Calculated_Price__c')
        : null;
      this.ProductType = null;
      this.ProductSubType = null;
      this.ProductState = null;
      this.RentEligible = false;
      if (prod.Product2 != null) {
        Map<String, Object> p2 = prod.Product2.getPopulatedFieldsAsMap();
        if (p2.containsKey('Type__c')) {
          this.ProductType = (String) prod.Product2.get('Type__c');
        }
        if (p2.containsKey('Sub_Type__c')) {
          this.ProductSubType = (String) prod.Product2.get('Sub_Type__c');
        }
        if (p2.containsKey('State__c')) {
          this.ProductState = (String) prod.Product2.get('State__c');
        }
        this.RentEligible =
          p2.containsKey('Rent__c') && prod.Product2.get('Rent__c') == true;
      }
      this.Availability = '';
    }
  }
}
