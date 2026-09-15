// WI-000168: Package Builder controller – product CRUD, draft order management
public without sharing class PackageBuilderController {
  private static final String PRODUCT_TYPE_STANDARD = 'Standard Products';

  /** Package Builder must not change these on OrderItem when Termination_Reason__c is already set.
   * Draft lines may still update EndDate so users can correct/extend termination dates.
   */
  private static final Set<String> TERMINATED_ORDER_ITEM_SAVE_BLOCKED_FIELDS = new Set<String>{
    'Access_Type__c',
    'ServiceDate',
    'EndDate',
    'Original_Start_Date__c',
    'Original_End_Date__c',
    'UnitPrice',
    'ListPrice',
    'Quantity',
    'CPI_Date__c',
    'Description'
  };

  @AuraEnabled(cacheable=true)
  public static List<PackageProductData> getProducts(String recordId) {
    String sObjectType = getSObjectType(recordId);
    List<SObject> lineItems = new List<SObject>();
    Map<Id, Decimal> oppAdjustedTotalByLineItem = new Map<Id, Decimal>();

    if (sObjectType == 'Opportunity') {
      lineItems = getOpportunityLineItems(recordId);
      Set<Id> oppLineItemIds = new Set<Id>();
      for (SObject item : lineItems) {
        Id lineItemId = (Id) item.get('Id');
        if (lineItemId != null) {
          oppLineItemIds.add(lineItemId);
        }
      }
      oppAdjustedTotalByLineItem = getOppAdjustedTotalByLineItem(
        oppLineItemIds
      );
    } else if (sObjectType == 'Order') {
      lineItems = getOrderItems(recordId);
    }

    Map<Id, List<OrderItem>> existingContractsByProduct = getExistingContracts(
      lineItems,
      sObjectType
    );

    List<PackageProductData> productsData = new List<PackageProductData>();

    // For Orders, calculate monthly list price sum from OrderItems
    // Aggregate_Total_price__c represents total over contract period (e.g., 24 months for Monthly)
    // We need to calculate the monthly list price sum: sum of (ListPrice * Quantity) for all OrderItems
    Decimal monthlyListPriceSum = null;
    if (sObjectType == 'Order' && !lineItems.isEmpty()) {
      monthlyListPriceSum = 0;
      for (SObject item : lineItems) {
        Decimal listPrice = (Decimal) item.get('ListPrice');
        Decimal quantity = (Decimal) item.get('Quantity');
        if (listPrice != null && quantity != null) {
          monthlyListPriceSum += (listPrice * quantity);
        } else if (listPrice != null) {
          monthlyListPriceSum += listPrice;
        }
      }
    }

    for (SObject item : lineItems) {
      PackageProductData prdData;
      if (sObjectType == 'Opportunity') {
        Id lineItemId = (Id) item.get('Id');
        Decimal adjustedTotal = oppAdjustedTotalByLineItem.containsKey(
            lineItemId
          )
          ? oppAdjustedTotalByLineItem.get(lineItemId)
          : null;
        prdData = new PackageProductData(item, adjustedTotal);
      } else {
        prdData = new PackageProductData(item);
      }

      // For Orders, override oppListPriceSum with calculated monthly list price
      if (sObjectType == 'Order' && monthlyListPriceSum != null) {
        prdData.oppListPriceSum = monthlyListPriceSum;
      }

      // Availability Logic
      if (sObjectType == 'Order') {
        String pType = (String) item.getSObject('Product2')?.get('Type__c');
        String pSubType = (String) item.getSObject('Product2')
          ?.get('Sub_Type__c');

        if (pType == PRODUCT_TYPE_STANDARD && pSubType != 'Hot Desk') {
          prdData.Availability = getProductAvailability(
            item,
            existingContractsByProduct,
            sObjectType
          );
        }
      } else {
        String productType = (String) item.get('Products_Type__c');
        String subType = (String) item.get('Product_Sub_Type__c');
        if (productType == PRODUCT_TYPE_STANDARD && subType != 'Hot Desk') {
          prdData.Availability = getProductAvailability(
            item,
            existingContractsByProduct,
            sObjectType
          );
        }
      }

      productsData.add(prdData);
    }

    if (sObjectType == 'Order') {
      Map<Id, PackageBuilderMonthPriceService.LinePriceResult> priceByLineId = PackageBuilderMonthPriceService.resolveForOrderItems(
        (List<OrderItem>) lineItems
      );
      for (PackageProductData productData : productsData) {
        // Contract Terms never have Monthly Payments — keep line prices, no info icon.
        if (productData.ProductsType == 'Contract Terms') {
          productData.ShowPriceProjectionInfo = false;
          productData.PriceProjectionInfoTooltip = null;
          continue;
        }
        Id lineId = (Id) productData.LineItemId;
        PackageBuilderMonthPriceService.LinePriceResult priceResult = priceByLineId.get(
          lineId
        );
        if (priceResult == null) {
          continue;
        }
        productData.UnitPrice = priceResult.unitPrice;
        productData.TotalPrice = priceResult.totalPrice;
        productData.PriceProjectionInfoTooltip = priceResult.infoTooltip;
        productData.ShowPriceProjectionInfo = String.isNotBlank(
          priceResult.infoTooltip
        );
      }
    }

    Map<Id, Integer> configuredByParent = getConfiguredIterationCounts(
      lineItems,
      sObjectType
    );
    for (PackageProductData productData : productsData) {
      Id lineId = (Id) productData.LineItemId;
      productData.ConfiguredIterations = configuredByParent.containsKey(lineId)
        ? configuredByParent.get(lineId)
        : 0;
    }

    return productsData;
  }

  /** Total Iteration rows configured on each Opportunity or Order line item. */
  private static Map<Id, Integer> getConfiguredIterationCounts(
    List<SObject> lineItems,
    String sObjectType
  ) {
    Map<Id, Integer> counts = new Map<Id, Integer>();
    Set<Id> parentIds = new Set<Id>();
    for (SObject item : lineItems) {
      Id lineId = (Id) item.get('Id');
      if (lineId != null) {
        parentIds.add(lineId);
      }
    }
    if (parentIds.isEmpty()) {
      return counts;
    }
    if (sObjectType == 'Opportunity') {
      for (AggregateResult ar : [
        SELECT Opportunity_Product__c parentId, COUNT(Id) cnt
        FROM Iteration__c
        WHERE Opportunity_Product__c IN :parentIds
        GROUP BY Opportunity_Product__c
      ]) {
        counts.put((Id) ar.get('parentId'), (Integer) ar.get('cnt'));
      }
    } else if (sObjectType == 'Order') {
      for (AggregateResult ar : [
        SELECT Order_Product__c parentId, COUNT(Id) cnt
        FROM Iteration__c
        WHERE Order_Product__c IN :parentIds
        GROUP BY Order_Product__c
      ]) {
        counts.put((Id) ar.get('parentId'), (Integer) ar.get('cnt'));
      }
    }
    return counts;
  }

  // Helper to determine SObject Type
  private static String getSObjectType(String recordId) {
    if (recordId == null)
      return '';
    Id recId = (Id) recordId;
    return recId.getSobjectType().getDescribe().getName();
  }

  private static List<OpportunityLineItem> getOpportunityLineItems(
    String oppId
  ) {
    return [
      SELECT
        Id,
        PricebookEntryId,
        
        
        Product2Id,
        Product2.Name,
        Product2.Type__c,
        Product2.Sub_Type__c,
        Product2.Rent__c,
        Product2.Size_m2__c,
        Product2.Window__c,
        Product2.IsActive,
        PricebookEntry.IsActive,
        UnitPrice,
        Access_Type__c,
        Entry_Date__c,
        End_date__c,
        CPI_Date__c,
        Products_Type__c,
        Product_Sub_Type__c,
        Quantity,
        TotalPrice,
        Temporary__c,
        Description,
        ListPrice,
        Products_List_Price__c,
        LastModifiedDate,
        Remaining_Iterations__c,
        
        
        Opportunity.Monthly_Price__c,
        Opportunity.Quantity_Sum__c,
        Opportunity.Total_Price_Non_Standard__c,
        Opportunity.List_Price_Adjustment__c,
        Opportunity.Start_Date__c,
        Opportunity.End_Date__c
      FROM OpportunityLineItem
      WHERE OpportunityId = :oppId
    ];
  }

  private static Map<Id, Decimal> getOppAdjustedTotalByLineItem(
    Set<Id> oppLineItemIds
  ) {
    Map<Id, Decimal> adjustedTotalByLineItem = new Map<Id, Decimal>();
    if (oppLineItemIds == null || oppLineItemIds.isEmpty()) {
      return adjustedTotalByLineItem;
    }

    for (MonthlyPayment__c payment : [
      SELECT
        OpportunityLineItem__c,
        Price__c,
        Discount__c,
        ListPrice__c,
        Access_Type__c,
        Final_Adjusted_Price__c
      FROM MonthlyPayment__c
      WHERE OpportunityLineItem__c IN :oppLineItemIds
    ]) {
      if (payment.OpportunityLineItem__c == null) {
        continue;
      }
      Decimal lineAmt = PackageBuilderService.payableAmountForMonthlyPayment(
        payment
      );

      adjustedTotalByLineItem.put(
        payment.OpportunityLineItem__c,
        (adjustedTotalByLineItem.containsKey(payment.OpportunityLineItem__c)
          ? adjustedTotalByLineItem.get(payment.OpportunityLineItem__c)
          : 0) + lineAmt
      );
    }
    return adjustedTotalByLineItem;
  }

  private static Map<String, String> terminationReasonLabelByApi;

  private static String terminationReasonPicklistLabel(String apiValue) {
    if (String.isBlank(apiValue)) {
      return '';
    }
    if (terminationReasonLabelByApi == null) {
      terminationReasonLabelByApi = new Map<String, String>();
      for (
        Schema.PicklistEntry pe : OrderItem.Termination_Reason__c.getDescribe()
          .getPicklistValues()
      ) {
        terminationReasonLabelByApi.put(pe.getValue(), pe.getLabel());
      }
    }
    String lbl = terminationReasonLabelByApi.get(apiValue);
    return lbl != null ? lbl : apiValue;
  }

  private static List<OrderItem> getOrderItems(String orderId) {
    List<OrderItem> allItems = [
      SELECT
        Id,
        PricebookEntryId,
        Product2Id,
        Product2.Name,
        Product2.Type__c,
        Product2.Sub_Type__c,
        Product2.Rent__c,
        Product2.Size_m2__c,
        Product2.Window__c,
        Product2.IsActive,
        PricebookEntry.IsActive,
        UnitPrice,
        Quantity,
        TotalPrice,
        Description,
        ListPrice,
        Products_List_Price__c,
        Access_Type__c,
        ServiceDate,
        EndDate,
        Original_Start_Date__c,
        Original_End_Date__c,
        CPI_Date__c,
        Product_Type_Name__c,
        Temporary__c,
        Termination_Reason__c,
        Early_Exit_Request__c,
        Change_Type__c,
        Is_Line_Deleted__c,
        Original_Order_Product__c,
        Replaced_Order_Product__c,
        Changed_Access_Type__c,
        LastModifiedDate,
        Original_Price__c,
        Adjusted_Total_Price__c,
        Show_Financial_Adjustment_Icon__c,
        Order.TotalAmount,
        Order.Aggregate_Calculated_Total_Price__c,
        Order.Aggregate_Total_price__c,
        Order.Total_Standard_Product_Count__c,
        Order.Aggregate_Price_Adjustment__c,
        Order.EffectiveDate,
        Order.Order_Start_Date__c,
        Order.EndDate,
        Remaining_Iterations__c
      FROM OrderItem
      WHERE OrderId = :orderId
    ];
    List<OrderItem> visible = new List<OrderItem>();
    for (OrderItem oi : allItems) {
      if (PackageBuilderService.isLineVisible(oi)) {
        visible.add(oi);
      }
    }
    return visible;
  }

  private static Map<Id, List<OrderItem>> getExistingContracts(
    List<SObject> lineItems,
    String sObjectType
  ) {
    Map<Id, List<OrderItem>> existingContractsByProduct = new Map<Id, List<OrderItem>>();
    List<String> productIds = new List<String>();

    for (SObject item : lineItems) {
      productIds.add((String) item.get('Product2Id'));
    }

    if (!productIds.isEmpty()) {
      List<OrderItem> orderItems = [
        SELECT
          Id,
          Product2Id,
          Product2.Name,
          Access_Type__c,
          ServiceDate,
          EndDate,
          Original_Start_Date__c,
          Original_End_Date__c,
          Contract__r.Account.Name,
          Contract__c,
          Contract__r.ContractNumber,
          Contract__r.Status
        FROM OrderItem
        WHERE Contract__r.Status = 'Activated' AND Product2Id IN :productIds
      ];

      for (OrderItem item : orderItems) {
        if (!existingContractsByProduct.containsKey(item.Product2Id)) {
          existingContractsByProduct.put(
            item.Product2Id,
            new List<OrderItem>()
          );
        }
        existingContractsByProduct.get(item.Product2Id).add(item);
      }
    }
    return existingContractsByProduct;
  }

  private static String getProductAvailability(
    SObject item,
    Map<Id, List<OrderItem>> existingContractsByProduct,
    String sObjectType
  ) {
    String productId = (String) item.get('Product2Id');
    if (!existingContractsByProduct.containsKey(productId)) {
      return Label.PackageBuilder_AvailableStatus;
    }

    List<OrderItem> existingContracts = existingContractsByProduct.get(
      productId
    );
    Date entryDate, endDate;

    if (sObjectType == 'Opportunity') {
      entryDate = (Date) item.get('Entry_Date__c');
      endDate = (Date) item.get('End_date__c');
    } else {
      entryDate = (Date) item.get('ServiceDate');
      endDate = (Date) item.get('EndDate');
    }

    for (OrderItem contractItem : existingContracts) {
      if (
        checkOverlap(
          entryDate,
          endDate,
          contractItem.ServiceDate,
          contractItem.EndDate
        )
      ) {
        return Label.PackageBuilder_NotAvailableStatus;
      }
    }

    return Label.PackageBuilder_PartlyAvailableStatus;
  }

  private static Boolean checkOverlap(
    Date start1,
    Date end1,
    Date start2,
    Date end2
  ) {
    if (start1 == null)
      return false;
    if (start2 == null)
      return false;

    Date e1 = (end1 == null) ? Date.newInstance(2999, 12, 31) : end1;
    Date e2 = (end2 == null) ? Date.newInstance(2999, 12, 31) : end2;

    return (start1 <= e2 && start2 <= e1);
  }

  private static String getLocation(String recordId) {
    return null;
  }

  @AuraEnabled(cacheable=true)
  public static Boolean hasEntryDateAdminOverride() {
    return PackageBuilderAccessPolicy.hasEntryDateAdminOverride();
  }

  @AuraEnabled(cacheable=true)
  public static Boolean hasTerminatedEndDateAdminOverride() {
    return PackageBuilderAccessPolicy.hasTerminatedEndDateAdminOverride();
  }

  /** Order_Start_Date__c floor; UI label is Contract Start Date — include that date in the message. */
  private static String productStartBeforeContractStartDateMessage(
    Date orderStartDate
  ) {
    if (orderStartDate == null) {
      return 'Product start date cannot be earlier than the Contract Start Date.';
    }
    return 'Product start date cannot be earlier than the Contract Start Date (' +
      String.valueOf(orderStartDate) +
      ').';
  }

  @AuraEnabled
  public static UpdateRecordResult saveLineItems(
    String recordTypeName,
    List<String> itemIds,
    List<SObject> lineItems
  ) {
    UpdateRecordResult result = new UpdateRecordResult();
    if (lineItems == null || lineItems.isEmpty())
      return result;

    try {
      String sObjectType = getSObjectType((String) lineItems[0].get('Id'));
      Boolean hasEntryDateOverride = PackageBuilderAccessPolicy.hasEntryDateAdminOverride();
      Date todayDate = Date.today();

      Boolean omitTotalPriceFromUpdate = false;
      if (
        'OrderItem'.equals(sObjectType) ||
        'OpportunityLineItem'.equals(sObjectType)
      ) {
        Schema.SObjectField totalPriceField = Schema.getGlobalDescribe()
          .get(sObjectType)
          .getDescribe()
          .fields.getMap()
          .get('TotalPrice');
        if (
          totalPriceField != null &&
          !totalPriceField.getDescribe().isUpdateable()
        ) {
          omitTotalPriceFromUpdate = true;
        }
      }

      // Draft semantics (OrderItem only): if a carried-over line is edited, mark as Modified.
      // Carried-over = has Original_Order_Product__c (set when cloning active → draft).
      Map<Id, OrderItem> existingOrderItemsById = new Map<Id, OrderItem>();
      Map<Id, OpportunityLineItem> existingOpportunityLineItemsById = new Map<Id, OpportunityLineItem>();
      if (sObjectType == 'OrderItem') {
        Set<Id> ids = new Set<Id>();
        for (SObject li : lineItems) {
          Object rawId = li.get('Id');
          if (rawId != null)
            ids.add((Id) rawId);
        }
        if (!ids.isEmpty()) {
          existingOrderItemsById = new Map<Id, OrderItem>(
            [
              SELECT
                Id,
                Change_Type__c,
                Original_Order_Product__c,
                Replaced_Order_Product__c,
                Original_Start_Date__c,
                ServiceDate,
                UnitPrice,
                Access_Type__c,
                PricebookEntryId,
                Termination_Reason__c,
                EndDate,
                Is_Line_Deleted__c,
                Temporary__c,
                OrderId,
                Order.Status,
                Order.EffectiveDate,
                Order.Order_Start_Date__c,
                Order.EndDate,
                Order.ContractId
              FROM OrderItem
              WHERE Id IN :ids
            ]
          );
        }
      } else if (sObjectType == 'OpportunityLineItem') {
        Set<Id> ids = new Set<Id>();
        for (SObject li : lineItems) {
          Object rawId = li.get('Id');
          if (rawId != null)
            ids.add((Id) rawId);
        }
        if (!ids.isEmpty()) {
          existingOpportunityLineItemsById = new Map<Id, OpportunityLineItem>(
            [
              SELECT
                Id,
                Access_Type__c,
                PricebookEntryId,
                UnitPrice,
                Temporary__c,
                OpportunityId
              FROM OpportunityLineItem
              WHERE Id IN :ids
            ]
          );
        }
      }

      List<SObject> concreteItems = new List<SObject>();
      for (SObject item : lineItems) {
        SObject concreteItem = Schema.getGlobalDescribe()
          .get(sObjectType)
          .newSObject();
        Map<String, Object> fields = item.getPopulatedFieldsAsMap();
        for (String fieldName : fields.keySet()) {
          if (
            omitTotalPriceFromUpdate && 'TotalPrice'.equalsIgnoreCase(fieldName)
          ) {
            continue;
          }
          concreteItem.put(fieldName, fields.get(fieldName));
        }

        if (sObjectType == 'OrderItem') {
          Id oiId = (Id) concreteItem.get('Id');
          OrderItem existing = existingOrderItemsById.get(oiId);
          Boolean isNewOrReplacementDraftLine =
            existing != null &&
            (existing.Change_Type__c == 'New' ||
            existing.Replaced_Order_Product__c != null ||
            existing.Original_Order_Product__c == null);
          Boolean isDraftOrder =
            existing != null &&
            existing.Order != null &&
            existing.Order.Status == 'Draft';
          Date incomingServiceDate = (Date) concreteItem.get('ServiceDate');
          Date candidateEntryDate = incomingServiceDate;

          if (
            isDraftOrder &&
            isNewOrReplacementDraftLine &&
            PackageBuilderService.isLineVisible(existing)
          ) {
            Date ordStart = existing.Order.Order_Start_Date__c != null
              ? existing.Order.Order_Start_Date__c
              : existing.Order.EffectiveDate;
            if (incomingServiceDate != null) {
              if (ordStart != null && incomingServiceDate < ordStart) {
                throw new AuraHandledException(
                  productStartBeforeContractStartDateMessage(ordStart)
                );
              }
              concreteItem.put('ServiceDate', incomingServiceDate);
              candidateEntryDate = incomingServiceDate;
            }
          }
          if (isDraftOrder && !hasEntryDateOverride) {
            Boolean isReplacementDraftLine =
              existing != null &&
              existing.Replaced_Order_Product__c != null;
            Date existingEntryDate = existing != null
              ? existing.ServiceDate
              : null;
            Boolean touchedEntryDate = fields.containsKey('ServiceDate');
            if (!isReplacementDraftLine && !isNewOrReplacementDraftLine) {
              if (
                touchedEntryDate &&
                candidateEntryDate != null &&
                candidateEntryDate < todayDate
              ) {
                throw new AuraHandledException(
                  System.Label.PackageBuilder_StartDate_PastEditError
                );
              }
              if (
                touchedEntryDate &&
                existingEntryDate != null &&
                existingEntryDate < todayDate
              ) {
                throw new AuraHandledException(
                  System.Label.PackageBuilder_StartDate_PastEditError
                );
              }
            }
          }
          if (
            existing != null &&
            existing.Original_Order_Product__c != null &&
            existing.Change_Type__c != 'New'
          ) {
            Boolean touchesBillingFields =
              fields.containsKey('ServiceDate') ||
              fields.containsKey('EndDate') ||
              fields.containsKey('CPI_Date__c') ||
              fields.containsKey('UnitPrice') ||
              fields.containsKey('ListPrice') ||
              fields.containsKey('Quantity') ||
              fields.containsKey('Termination_Reason__c');
            if (touchesBillingFields) {
              concreteItem.put('Change_Type__c', 'Modified');
            }
          }
          if (fields.containsKey('UnitPrice') && existing != null) {
            Decimal newUnit = (Decimal) concreteItem.get('UnitPrice');
            Decimal oldUnit = existing.UnitPrice;
            if (newUnit != oldUnit) {
              concreteItem.put('Show_Financial_Adjustment_Icon__c', true);
            }
          }
          if (
            existing != null &&
            String.isNotBlank(existing.Termination_Reason__c) &&
            existing.Order != null &&
            existing.Order.Status == 'Draft' &&
            fields.containsKey('EndDate')
          ) {
            Date incomingEnd = (Date) concreteItem.get('EndDate');
            Boolean terminateProductsSave = fields.containsKey(
              'Termination_Reason__c'
            );
            if (
              !terminateProductsSave &&
              !PackageBuilderAccessPolicy.canShortenTerminatedEndDate(
                existing.EndDate,
                incomingEnd
              )
            ) {
              throw new AuraHandledException(
                System.Label.PackageBuilder_TerminatedEndDateShortenBody
              );
            }
          }
          if (fields.containsKey('Temporary__c') && existing != null) {
            Boolean incomingTemporary =
              (Boolean) concreteItem.get('Temporary__c') == true;
            Boolean existingTemporary = existing.Temporary__c == true;
            if (
              existingTemporary &&
              !incomingTemporary &&
              PackageBuilderService.isOtherSiteProduct(null, null)
            ) {
              throw new AuraHandledException(
                System.Label.PackageBuilder_TemporaryOtherSiteError
              );
            }
          }
        } else if (sObjectType == 'OpportunityLineItem') {
          Id oliId = (Id) concreteItem.get('Id');
          OpportunityLineItem existing = existingOpportunityLineItemsById.get(
            oliId
          );
          if (fields.containsKey('Temporary__c') && existing != null) {
            Boolean incomingTemporary =
              (Boolean) concreteItem.get('Temporary__c') == true;
            Boolean existingTemporary = existing.Temporary__c == true;
            if (
              existingTemporary &&
              !incomingTemporary &&
              PackageBuilderService.isOtherSiteProduct(null, null)
            ) {
              throw new AuraHandledException(
                System.Label.PackageBuilder_TemporaryOtherSiteError
              );
            }
          }
        }
        concreteItems.add(concreteItem);
      }

      if (sObjectType == 'OrderItem') {
        assertMonthlyReplacementParentKeepsEndDate(
          concreteItems,
          existingOrderItemsById
        );
      }

      syncAccessTypeLinePricingOnSave(
        sObjectType,
        concreteItems,
        existingOrderItemsById,
        existingOpportunityLineItemsById
      );
      enforceUsageBasedUnitPriceOnSave(
        sObjectType,
        concreteItems,
        existingOrderItemsById,
        existingOpportunityLineItemsById
      );

      Set<Id> draftBillingChangedLineIds = new Set<Id>();
      Id draftBackfillOrderId = null;
      if (sObjectType == 'OrderItem') {
        assertPackageBuilderDoesNotEditTerminatedOrderItems(
          lineItems,
          existingOrderItemsById
        );
        extendParentPackageEndDatesBeforeOrderItemSave(
          concreteItems,
          existingOrderItemsById
        );
        for (SObject item : concreteItems) {
          Id oiId = (Id) item.get('Id');
          OrderItem existing = existingOrderItemsById.get(oiId);
          if (
            existing == null ||
            existing.Order == null ||
            existing.Order.Status != 'Draft'
          ) {
            continue;
          }
          Map<String, Object> fields = item.getPopulatedFieldsAsMap();
          Boolean billingChanged =
            fields.containsKey('ServiceDate') ||
            fields.containsKey('EndDate') ||
            fields.containsKey('Access_Type__c');
          if (billingChanged) {
            draftBillingChangedLineIds.add(oiId);
            draftBackfillOrderId = existing.OrderId;
          }
        }
      }

      update concreteItems;

      if (
        draftBackfillOrderId != null && !draftBillingChangedLineIds.isEmpty()
      ) {
        PackageBuilderService.backfillMissingMonthlyPaymentsForOrderItems(
          draftBackfillOrderId,
          new List<Id>(draftBillingChangedLineIds)
        );
      }

      result.hasErrors = false;
      PackageBuilderService.publishEvent();
    } catch (AuraHandledException ahe) {
      result.hasErrors = true;
      result.errorType = ahe.getTypeName();
      throw ahe;
    } catch (Exception e) {
      result.hasErrors = true;
      result.errorType = e.getTypeName();
      System.debug('Error in saveLineItems: ' + e.getMessage());
      throw new AuraHandledException(e.getMessage());
    }
    return result;
  }

  private static void extendParentPackageEndDatesBeforeOrderItemSave(
    List<SObject> concreteItems,
    Map<Id, OrderItem> existingOrderItemsById
  ) {
    PackageBuilderService.reconcileDraftOrderEndBeforeLineItemSave(
      concreteItems,
      existingOrderItemsById
    );
  }

  private static void syncAccessTypeLinePricingOnSave(
    String sObjectType,
    List<SObject> concreteItems,
    Map<Id, OrderItem> existingOrderItemsById,
    Map<Id, OpportunityLineItem> existingOpportunityLineItemsById
  ) {
    if (concreteItems == null || concreteItems.isEmpty()) {
      return;
    }
    Set<Id> pricebookEntryIds = new Set<Id>();
    for (SObject item : concreteItems) {
      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      if (!fields.containsKey('Access_Type__c')) {
        continue;
      }
      Id lineId = (Id) item.get('Id');
      String newAccessType = (String) item.get('Access_Type__c');
      if (sObjectType == 'OrderItem') {
        OrderItem existing = existingOrderItemsById.get(lineId);
        if (existing == null) {
          continue;
        }
        if (newAccessType == existing.Access_Type__c) {
          continue;
        }
        if (PackageBuilderAccessTypePolicy.isUsageBased(newAccessType)) {
          PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(
            (OrderItem) item
          );
        } else if (
          PackageBuilderAccessTypePolicy.isUsageBased(
            existing.Access_Type__c
          ) && existing.PricebookEntryId != null
        ) {
          pricebookEntryIds.add(existing.PricebookEntryId);
        }
      } else if (sObjectType == 'OpportunityLineItem') {
        OpportunityLineItem existing = existingOpportunityLineItemsById.get(
          lineId
        );
        if (existing == null) {
          continue;
        }
        if (newAccessType == existing.Access_Type__c) {
          continue;
        }
        if (PackageBuilderAccessTypePolicy.isUsageBased(newAccessType)) {
          PackageBuilderAccessTypePolicy.applyUsageBasedLinePricing(
            (OpportunityLineItem) item
          );
        } else if (
          PackageBuilderAccessTypePolicy.isUsageBased(
            existing.Access_Type__c
          ) && existing.PricebookEntryId != null
        ) {
          pricebookEntryIds.add(existing.PricebookEntryId);
        }
      }
    }
    if (pricebookEntryIds.isEmpty()) {
      return;
    }
    Map<Id, Decimal> unitPriceByPbeId = new Map<Id, Decimal>();
    for (PricebookEntry pbe : [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE Id IN :pricebookEntryIds
    ]) {
      unitPriceByPbeId.put(pbe.Id, pbe.UnitPrice);
    }
    for (SObject item : concreteItems) {
      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      if (!fields.containsKey('Access_Type__c')) {
        continue;
      }
      Id lineId = (Id) item.get('Id');
      String newAccessType = (String) item.get('Access_Type__c');
      if (sObjectType == 'OrderItem') {
        OrderItem existing = existingOrderItemsById.get(lineId);
        if (
          existing == null ||
          !PackageBuilderAccessTypePolicy.isUsageBased(
            existing.Access_Type__c
          ) ||
          PackageBuilderAccessTypePolicy.isUsageBased(newAccessType)
        ) {
          continue;
        }
        Decimal catalogUnit = unitPriceByPbeId.get(existing.PricebookEntryId);
        PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(
          (OrderItem) item,
          catalogUnit
        );
      } else if (sObjectType == 'OpportunityLineItem') {
        OpportunityLineItem existing = existingOpportunityLineItemsById.get(
          lineId
        );
        if (
          existing == null ||
          !PackageBuilderAccessTypePolicy.isUsageBased(
            existing.Access_Type__c
          ) ||
          PackageBuilderAccessTypePolicy.isUsageBased(newAccessType)
        ) {
          continue;
        }
        Decimal catalogUnit = unitPriceByPbeId.get(existing.PricebookEntryId);
        PackageBuilderAccessTypePolicy.restoreCatalogUnitPrice(
          (OpportunityLineItem) item,
          catalogUnit
        );
      }
    }
  }

  private static void enforceUsageBasedUnitPriceOnSave(
    String sObjectType,
    List<SObject> concreteItems,
    Map<Id, OrderItem> existingOrderItemsById,
    Map<Id, OpportunityLineItem> existingOpportunityLineItemsById
  ) {
    if (concreteItems == null || concreteItems.isEmpty()) {
      return;
    }
    for (SObject item : concreteItems) {
      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      if (!fields.containsKey('UnitPrice')) {
        continue;
      }
      Id lineId = (Id) item.get('Id');
      String resolvedAccessType = fields.containsKey('Access_Type__c')
        ? (String) item.get('Access_Type__c')
        : null;
      if (sObjectType == 'OrderItem') {
        OrderItem existing = existingOrderItemsById.get(lineId);
        if (String.isBlank(resolvedAccessType) && existing != null) {
          resolvedAccessType = existing.Access_Type__c;
        }
      } else if (sObjectType == 'OpportunityLineItem') {
        OpportunityLineItem existing = existingOpportunityLineItemsById.get(
          lineId
        );
        if (String.isBlank(resolvedAccessType) && existing != null) {
          resolvedAccessType = existing.Access_Type__c;
        }
      }
      PackageBuilderAccessTypePolicy.enforceUsageBasedUnitPriceOnSave(
        item,
        resolvedAccessType
      );
    }
  }

  @AuraEnabled
  public static String deleteLineItems(List<Id> itemIds) {
    if (itemIds == null || itemIds.isEmpty())
      return 'No items to delete';
    // Duplicate Ids in one DML delete can fail later rows with ENTITY_IS_DELETED and surface two toasts in the UI.
    Set<Id> seen = new Set<Id>();
    List<Id> uniqueIds = new List<Id>();
    for (Id itemId : itemIds) {
      if (itemId != null && !seen.contains(itemId)) {
        seen.add(itemId);
        uniqueIds.add(itemId);
      }
    }
    if (uniqueIds.isEmpty())
      return 'No items to delete';
    Boolean prevSkipDateSync = OrderItemTriggerHandler.SKIP_DATE_SYNC;
    Boolean prevMpSuppress = OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC;
    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = true;
    Map<Id, OrderItem> paymentDateSyncOldById = new Map<Id, OrderItem>();
    Boolean parentDatesUpdated = false;
    Savepoint deleteSavepoint = Database.setSavepoint();
    Map<Id, List<TransferPriceService.MonthTerm>> transferMapBackByParent = new Map<Id, List<TransferPriceService.MonthTerm>>();
    TransferPriceService.ParentTermSnapshot transferMapBackSnapshot = null;
    try {
      // Draft semantics (OrderItem only): delete is allowed only for New lines.
      List<Id> orderItemIds = new List<Id>();
      for (Id itemId : uniqueIds) {
        if (itemId.getSObjectType() == OrderItem.SObjectType) {
          orderItemIds.add(itemId);
        }
      }

      List<OrderItem> itemsToDelete = new List<OrderItem>();
      if (!orderItemIds.isEmpty()) {
        itemsToDelete = [
          SELECT
            Id,
            Original_Order_Product__c,
            Replaced_Order_Product__c,
            EndDate,
            ServiceDate,
            Access_Type__c,
            PricebookEntryId,
            Changed_Access_Type__c,
            Transfer_Price__c
          FROM OrderItem
          WHERE Id IN :orderItemIds
        ];
        for (OrderItem oi : itemsToDelete) {
          Boolean isExistingDraftLine = oi.Original_Order_Product__c != null;
          Boolean futureStart =
            oi.ServiceDate != null &&
            oi.ServiceDate > Date.today();
          if (isExistingDraftLine && !futureStart) {
            return 'Delete is allowed only for newly added products in this draft.';
          }
        }
      }

      // Snapshot transfer-price terms before replacement payments are hard-deleted.
      transferMapBackSnapshot = TransferPriceService.snapshotTermsByReplacedParent(
        itemsToDelete
      );
      transferMapBackByParent = transferMapBackSnapshot.termsByParentId;

      // Restore / retarget Iteration plans before replacement children are removed.
      IterationService.restoreFromReplacedOrderProducts(itemsToDelete);

      // If any deleted item is a replacement, restore end date on the replaced (old) product
      // clamped to the active (concluded) line when replacement end is earlier.
      Set<Id> replacedIds = new Set<Id>();
      Map<Id, Date> replacementEndDateByReplacedId = new Map<Id, Date>();
      Map<Id, Boolean> pastStartSplitUndoByReplacedId = new Map<Id, Boolean>();
      Map<Id, Boolean> accessTypeChangeUndoByReplacedId = new Map<Id, Boolean>();
      for (OrderItem oi : itemsToDelete) {
        if (oi.Replaced_Order_Product__c != null) {
          replacedIds.add(oi.Replaced_Order_Product__c);
          replacementEndDateByReplacedId.put(
            oi.Replaced_Order_Product__c,
            oi.EndDate
          );
          if (oi.Changed_Access_Type__c == true) {
            accessTypeChangeUndoByReplacedId.put(
              oi.Replaced_Order_Product__c,
              true
            );
          }
        }
      }
      Map<Id, OrderItem> replacedParentsById = new Map<Id, OrderItem>();
      if (!replacedIds.isEmpty()) {
        replacedParentsById = new Map<Id, OrderItem>(
          [
            SELECT
              Id,
              Change_Type__c,
              EndDate,
              ServiceDate,
              Original_Order_Product__c,
              OrderId,
              Access_Type__c,
              PricebookEntryId
            FROM OrderItem
            WHERE Id IN :replacedIds
          ]
        );
        for (OrderItem oi : itemsToDelete) {
          if (oi.Replaced_Order_Product__c == null) {
            continue;
          }
          OrderItem replacedParent = replacedParentsById.get(
            oi.Replaced_Order_Product__c
          );
          if (
            PackageBuilderService.isPastStartSplitReplacementForUndo(
              oi,
              replacedParent
            )
          ) {
            pastStartSplitUndoByReplacedId.put(
              oi.Replaced_Order_Product__c,
              true
            );
          }
        }
      }
      if (!replacedParentsById.isEmpty()) {
        List<OrderItem> replacedItems = replacedParentsById.values();
        Set<Id> activeLineIds = new Set<Id>();
        for (OrderItem replaced : replacedItems) {
          if (replaced.Original_Order_Product__c != null) {
            activeLineIds.add(replaced.Original_Order_Product__c);
          }
        }
        Map<Id, OrderItem> activeLinesById = new Map<Id, OrderItem>();
        if (!activeLineIds.isEmpty()) {
          activeLinesById = new Map<Id, OrderItem>(
            [
              SELECT Id, EndDate
              FROM OrderItem
              WHERE Id IN :activeLineIds
            ]
          );
        }
        List<OrderItem> toUpdate = new List<OrderItem>();
        for (OrderItem replaced : replacedItems) {
          replaced.Change_Type__c = null;
          Date priorEnd = replaced.EndDate;
          Date priorStart = replaced.ServiceDate;
          Date replacementEnd = replacementEndDateByReplacedId.get(replaced.Id);
          Date activeEnd = null;
          if (replaced.Original_Order_Product__c != null) {
            OrderItem activeLine = activeLinesById.get(
              replaced.Original_Order_Product__c
            );
            if (activeLine != null) {
              activeEnd = activeLine.EndDate;
            }
          }
          Date resolvedEnd = resolveReplacedEndDateOnReplacementDelete(
            replacementEnd,
            activeEnd,
            pastStartSplitUndoByReplacedId.get(replaced.Id) == true,
            replaced.Access_Type__c,
            accessTypeChangeUndoByReplacedId.get(replaced.Id) == true
          );
          if (resolvedEnd != priorEnd || priorStart != replaced.ServiceDate) {
            paymentDateSyncOldById.put(
              replaced.Id,
              new OrderItem(
                Id = replaced.Id,
                EndDate = priorEnd,
                ServiceDate = priorStart,
                Access_Type__c = replaced.Access_Type__c
              )
            );
          }
          replaced.EndDate = resolvedEnd;
          toUpdate.add(replaced);
        }
        if (!toUpdate.isEmpty()) {
          Map<Id, List<OrderItem>> pendingByOrderId = new Map<Id, List<OrderItem>>();
          for (OrderItem replaced : toUpdate) {
            if (replaced == null || replaced.OrderId == null) {
              continue;
            }
            if (!pendingByOrderId.containsKey(replaced.OrderId)) {
              pendingByOrderId.put(replaced.OrderId, new List<OrderItem>());
            }
            pendingByOrderId.get(replaced.OrderId).add(replaced);
          }
          for (Id pendingOrderId : pendingByOrderId.keySet()) {
            ensureDraftOrderEndCoversLineEndDates(
              pendingOrderId,
              pendingByOrderId.get(pendingOrderId),
              null
            );
          }
          update toUpdate;
          parentDatesUpdated = !paymentDateSyncOldById.isEmpty();
        }
      }

      List<Id> nonOrderItemIds = new List<Id>();
      for (Id itemId : uniqueIds) {
        if (itemId.getSObjectType() != OrderItem.SObjectType) {
          nonOrderItemIds.add(itemId);
        }
      }
      if (!nonOrderItemIds.isEmpty()) {
        Database.delete(nonOrderItemIds);
      }

      PackageBuilderService.hardDeleteLinesWithPayments(itemsToDelete);

      PackageBuilderService.publishEvent();
      return 'Success';
    } catch (Exception e) {
      Database.rollback(deleteSavepoint);
      parentDatesUpdated = false;
      paymentDateSyncOldById.clear();
      transferMapBackByParent.clear();
      transferMapBackSnapshot = null;
      return e.getMessage();
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = prevSkipDateSync;
      OrderItemTriggerHandler.TEST_SUPPRESS_MONTHLY_PAYMENT_SYNC = prevMpSuppress;
      if (parentDatesUpdated && !paymentDateSyncOldById.isEmpty()) {
        try {
          PackageBuilderService.syncMonthlyPaymentsForVisibleOrderItemDateChanges(
            paymentDateSyncOldById
          );
        } catch (Exception syncEx) {
          System.debug(
            LoggingLevel.ERROR,
            'Payment sync after deleteLineItems parent date restore failed: ' +
            syncEx.getMessage()
          );
        }
      }
      if (transferMapBackSnapshot != null) {
        try {
          TransferPriceService.applyMapBackToParents(transferMapBackSnapshot);
        } catch (Exception mapBackEx) {
          System.debug(
            LoggingLevel.ERROR,
            'Transfer price map-back after deleteLineItems failed: ' +
            mapBackEx.getMessage()
          );
        }
      }
    }
  }

  public class PackageProductData {
    @AuraEnabled
    public String LineItemId { get; set; }
    @AuraEnabled
    public String PricebookEntryId { get; set; }
    @AuraEnabled
    public String Name { get; set; }
    @AuraEnabled
    public String ChangeType { get; set; }
    @AuraEnabled
    public String OriginalOrderProductId { get; set; }
    @AuraEnabled
    public String ReplacedOrderProductId { get; set; }
    @AuraEnabled
    public Decimal UnitPrice { get; set; }
    @AuraEnabled
    public Decimal Quantity { get; set; }
    @AuraEnabled
    public Decimal DeskCount { get; set; }
    @AuraEnabled
    public Decimal TotalPrice { get; set; }
    @AuraEnabled
    public Boolean ShowPriceProjectionInfo { get; set; }
    @AuraEnabled
    public String PriceProjectionInfoTooltip { get; set; }
    /** Sum of monthly FinalPrice at baseline; immutable after first set. */
    @AuraEnabled
    public Decimal OriginalPrice { get; set; }
    /** Current sum of monthly FinalPrice for this line. */
    @AuraEnabled
    public Decimal AdjustedTotalPrice { get; set; }
    /** Package Builder status column: money icon from manual monthly save or desk UnitPrice edit. */
    @AuraEnabled
    public Boolean ShowFinancialAdjustmentIcon { get; set; }
    @AuraEnabled
    public Decimal ListPrice { get; set; }
    /** Extended list price (ListPrice × Quantity) for Package Builder grid. */
    @AuraEnabled
    public Decimal Products_List_Price { get; set; }
    @AuraEnabled
    public String Description { get; set; }
    /** OrderItem termination reason label for Package Builder grid (contract only). */
    @AuraEnabled
    public String TerminationReasonLabel { get; set; }
    /** OrderItem termination reason API value (drives inline picklist combobox on Draft tab). */
    @AuraEnabled
    public String TerminationReason { get; set; }
    @AuraEnabled
    public String Availability { get; set; }
    @AuraEnabled
    public String AccessType { get; set; }
    /** True when line was created by past-start split (qty or access type change). */
    @AuraEnabled
    public Boolean ChangedAccessType { get; set; }
    /** Product row last modified timestamp used to prioritize recently modified rows in the grid. */
    @AuraEnabled
    public Datetime LineLastModifiedDateTime { get; set; }
    @AuraEnabled
    public Date EntryDate { get; set; }
    @AuraEnabled
    public Date OriginalStartDate { get; set; }
    @AuraEnabled
    public Date OriginalEndDate { get; set; }
    /** YYYY-MM-DD from Original_Start_Date__c — reliable in LWC when Date deserialization fails on the wire. */
    @AuraEnabled
    public String OriginalStartDateIso { get; set; }
    /** YYYY-MM-DD from Original_End_Date__c — reliable in LWC when Date deserialization fails on the wire. */
    @AuraEnabled
    public String OriginalEndDateIso { get; set; }
    @AuraEnabled
    public Date CpiDate { get; set; }
    /** YYYY-MM-DD from CPI_Date__c — reliable in LWC when Date deserialization fails on the wire. */
    @AuraEnabled
    public String CpiDateIso { get; set; }
    @AuraEnabled
    public Date EndDate { get; set; }
    @AuraEnabled
    public Date ParentStartDate { get; set; }
    @AuraEnabled
    public Date ParentEndDate { get; set; }
    @AuraEnabled
    public String ProductsType { get; set; }
    @AuraEnabled
    public String ProductSubType { get; set; }
    @AuraEnabled
    public String ProductTypeName { get; set; }
    @AuraEnabled
    public Boolean Temporary { get; set; }
    /** Manual early-exit flag on contract OrderItem (Package Builder Rooms/Extra). */
    @AuraEnabled
    public Boolean EarlyExitRequest { get; set; }
    /** True when Product location differs from Order location (blank product location = false). */
    @AuraEnabled
    public Boolean OtherSiteProduct { get; set; }
    @AuraEnabled
    public Boolean ProductIsActive { get; set; }
    @AuraEnabled
    public Boolean PricebookEntryIsActive { get; set; }

    // Opportunity Specific (can be null for Orders)
    @AuraEnabled
    public String oppRecordTypeName { get; set; }
    @AuraEnabled
    public String oppRecordTypeId { get; set; }
    @AuraEnabled
    public Decimal oppAverageDeskPrice { get; set; }
    @AuraEnabled
    public Decimal oppDesks { get; set; }
    @AuraEnabled
    public Decimal oppListPriceSum { get; set; }
    @AuraEnabled
    public Decimal oppMonthlyPrice { get; set; }
    @AuraEnabled
    public Decimal oppQuantitySum { get; set; }
    @AuraEnabled
    public Decimal oppTotalPriceNonStandard { get; set; }
    @AuraEnabled
    public Decimal oppListPriceAdjustment { get; set; }
    @AuraEnabled
    public String oppTemporaryProductCheck { get; set; }
    @AuraEnabled
    public String currencyCode { get; set; }
    @AuraEnabled
    public Decimal SizeM2 { get; set; }
    @AuraEnabled
    public Boolean RentEligible { get; set; }
    @AuraEnabled
    public Decimal RemainingIterations { get; set; }
    @AuraEnabled
    public Integer ConfiguredIterations { get; set; }

    public PackageProductData(SObject item) {
      this(item, null);
    }

    public PackageProductData(SObject item, Decimal oppAdjustedTotalOverride) {
      this.LineItemId = (String) item.get('Id');
      this.PricebookEntryId = (String) item.get('PricebookEntryId');

      SObject product = item.getSObject('Product2');
      SObject pricebookEntry = item.getSObject('PricebookEntry');
      if (product != null) {
        this.Name = (String) product.get('Name');
        this.ProductIsActive = (Boolean) product.get('IsActive');
        this.SizeM2 = (Decimal) product.get('Size_m2__c');
        this.RentEligible = (Boolean) product.get('Rent__c') == true;
      }
      this.RemainingIterations = (Decimal) item.get('Remaining_Iterations__c');
      if (pricebookEntry != null) {
        this.PricebookEntryIsActive = (Boolean) pricebookEntry.get('IsActive');
      }

      this.UnitPrice = (Decimal) item.get('UnitPrice');
      this.Quantity = (Decimal) item.get('Quantity');
      this.TotalPrice = (Decimal) item.get('TotalPrice');
      this.ListPrice = (Decimal) item.get('ListPrice');
      this.Products_List_Price = (Decimal) item.get('Products_List_Price__c');
      this.Description = (String) item.get('Description');
      this.AccessType = (String) item.get('Access_Type__c');
      this.LineLastModifiedDateTime = (Datetime) item.get('LastModifiedDate');

      String sType = String.valueOf(item.getSObjectType());
      if (sType == 'OpportunityLineItem') {
        this.DeskCount = null;
        this.EntryDate = (Date) item.get('Entry_Date__c');
        this.EndDate = (Date) item.get('End_date__c');
        this.AdjustedTotalPrice = oppAdjustedTotalOverride;
        Date oppCpiDt = (Date) item.get('CPI_Date__c');
        this.CpiDate = oppCpiDt;
        this.CpiDateIso = oppCpiDt != null ? String.valueOf(oppCpiDt) : null;
        // Align with Order: use live Product2.Type__c for section splits / grid (Products_Type__c can lag after catalog changes).
        if (product != null) {
          this.ProductTypeName = (String) product.get('Type__c');
          this.ProductsType = (String) product.get('Type__c');
        } else {
          this.ProductsType = (String) item.get('Products_Type__c');
        }
        // Use line item field first; fall back to Product2.Sub_Type__c
        String oliSubType = (String) item.get('Product_Sub_Type__c');
        if (String.isNotBlank(oliSubType)) {
          this.ProductSubType = oliSubType;
        } else if (product != null) {
          this.ProductSubType = (String) product.get('Sub_Type__c');
        }
        this.Temporary = (Boolean) item.get('Temporary__c');
        Id productLocationId = product != null
          ? null
          : null;
        Id oppLocationId = null;

        // Opp fields
        try {
          SObject opp = item.getSObject('Opportunity');
          if (opp != null) {
            oppLocationId = null;
            this.ParentStartDate = (Date) opp.get('Start_Date__c');
            this.ParentEndDate = (Date) opp.get('End_Date__c');
            this.oppRecordTypeId = null;
            this.oppRecordTypeName = null;
            this.oppAverageDeskPrice = null;
            this.oppDesks = null;
            this.oppListPriceSum = null;
            this.oppMonthlyPrice = (Decimal) opp.get('Monthly_Price__c');
            this.oppQuantitySum = (Decimal) opp.get('Quantity_Sum__c');
            this.oppTotalPriceNonStandard = (Decimal) opp.get(
              'Total_Price_Non_Standard__c'
            );
            this.oppListPriceAdjustment = (Decimal) opp.get(
              'List_Price_Adjustment__c'
            );
            this.oppTemporaryProductCheck = null;
          }
        } catch (Exception e) {
          System.debug('Error mapping Opportunity fields: ' + e.getMessage());
        }
        this.OtherSiteProduct = PackageBuilderService.isOtherSiteProduct(
          productLocationId,
          oppLocationId
        );
      } else if (sType == 'OrderItem') {
        this.OriginalPrice = (Decimal) item.get('Original_Price__c');
        this.AdjustedTotalPrice = (Decimal) item.get('Adjusted_Total_Price__c');
        this.ShowFinancialAdjustmentIcon =
          (Boolean) item.get('Show_Financial_Adjustment_Icon__c') == true;
        this.ChangeType = (String) item.get('Change_Type__c');
        this.OriginalOrderProductId = (String) item.get(
          'Original_Order_Product__c'
        );
        this.ReplacedOrderProductId = (String) item.get(
          'Replaced_Order_Product__c'
        );
        this.ChangedAccessType =
          (Boolean) item.get('Changed_Access_Type__c') == true;
        this.DeskCount = null;
        this.EntryDate = (Date) item.get('ServiceDate');
        Date startDt = (Date) item.get('ServiceDate');
        Date endDt = (Date) item.get('EndDate');
        if (startDt == null) {
          startDt = (Date) item.get('Original_Start_Date__c');
        }
        if (endDt == null) {
          endDt = (Date) item.get('Original_End_Date__c');
        }
        this.OriginalStartDate = startDt;
        this.OriginalEndDate = endDt;
        this.OriginalStartDateIso = startDt != null
          ? String.valueOf(startDt)
          : null;
        this.OriginalEndDateIso = endDt != null ? String.valueOf(endDt) : null;
        Date cpiDt = (Date) item.get('CPI_Date__c');
        this.CpiDate = cpiDt;
        this.CpiDateIso = cpiDt != null ? String.valueOf(cpiDt) : null;
        this.EndDate = (Date) item.get('EndDate');
        if (product != null) {
          this.ProductTypeName = (String) product.get('Type__c');
          this.ProductsType = (String) product.get('Type__c');
          this.ProductSubType = (String) product.get('Sub_Type__c');
        } else {
          this.ProductTypeName = (String) item.get('Product_Type_Name__c');
        }
        this.Temporary = (Boolean) item.get('Temporary__c');
        this.EarlyExitRequest =
          (Boolean) item.get('Early_Exit_Request__c') == true;
        Id productLocationId = product != null
          ? null
          : null;
        Id orderLocationId = null;
        try {
          SObject ordLoc = item.getSObject('Order');
          if (ordLoc != null) {
            orderLocationId = null;
          }
        } catch (Exception ignore) {
        }
        this.OtherSiteProduct = PackageBuilderService.isOtherSiteProduct(
          productLocationId,
          orderLocationId
        );
        String terminationReasonValue = (String) item.get(
          'Termination_Reason__c'
        );
        this.TerminationReason = terminationReasonValue;
        this.TerminationReasonLabel = terminationReasonPicklistLabel(
          terminationReasonValue
        );

        // Order fields mapping
        try {
          SObject ord = item.getSObject('Order');
          if (ord != null) {
            Date osd = (Date) ord.get('Order_Start_Date__c');
            this.ParentStartDate = osd != null
              ? osd
              : (Date) ord.get('EffectiveDate');
            this.ParentEndDate = (Date) ord.get('EndDate');
            // Use TotalAmount for monthly price (represents monthly amount)
            // Aggregate_Calculated_Total_Price__c represents total over contract period (e.g., 24 months for Monthly access type)
            this.oppMonthlyPrice = (Decimal) ord.get('TotalAmount');
            this.oppDesks = null;
            this.oppListPriceSum = (Decimal) ord.get(
              'Aggregate_Total_price__c'
            );
            this.oppQuantitySum = (Decimal) ord.get(
              'Total_Standard_Product_Count__c'
            );
            this.oppListPriceAdjustment = (Decimal) ord.get(
              'Aggregate_Price_Adjustment__c'
            );

            if (
              this.oppMonthlyPrice != null &&
              this.oppDesks != null &&
              this.oppDesks > 0
            ) {
              this.oppAverageDeskPrice = (this.oppMonthlyPrice / this.oppDesks)
                .setScale(2);
            } else {
              this.oppAverageDeskPrice = 0;
            }
          }
        } catch (Exception e) {
          System.debug('Error mapping Order fields: ' + e.getMessage());
        }
      }

      // Default to ILS (Israeli Shekel) if currency is not set
      if (String.isBlank(this.currencyCode)) {
        this.currencyCode = 'ILS';
      }

      this.Availability = 'Available'; // Default
    }
  }

  @AuraEnabled(cacheable=true)
  public static List<PackageProductData> getContracts(String recordId) {
    // Location-based contract browse removed for Cloudial commercial package.
    return new List<PackageProductData>();
  }

  public class UpdateRecordResult {
    @AuraEnabled
    public Boolean hasErrors { get; set; }
    @AuraEnabled
    public String errorType { get; set; }
    @AuraEnabled
    public Map<String, Map<String, String>> recordErrors { get; set; }
  }

  // ========== DRAFT ORDER MANAGEMENT (Contract context) ==========

  /**
   * Returns contract start/end dates and summary fields for Package Builder (date validation + contract section).
   */
  @AuraEnabled(cacheable=true)
  public static ContractDatesResult getContractDates(Id contractId) {
    if (contractId == null)
      return null;
    List<Contract> contracts = [
      SELECT
        Id,
        ContractNumber,
        AccountId,
        Account.Name,
        
        Status,
        StartDate,
        EndDate,
        Quarterly_Payment__c
      FROM Contract
      WHERE Id = :contractId
      LIMIT 1
    ];
    if (contracts.isEmpty())
      return null;
    Contract c = contracts[0];
    ContractDatesResult result = new ContractDatesResult();
    result.startDate = c.StartDate;
    result.endDate = c.EndDate;
    result.contractNumber = c.ContractNumber;
    result.accountName = c.AccountId != null
      ? (String) c.getSObject('Account')?.get('Name')
      : null;
    result.locationName = null;
    result.status = c.Status;
    result.quarterlyPayment = c.Quarterly_Payment__c == true;
    return result;
  }

  public class ContractDatesResult {
    @AuraEnabled
    public Date startDate { get; set; }
    @AuraEnabled
    public Date endDate { get; set; }
    @AuraEnabled
    public String contractNumber { get; set; }
    @AuraEnabled
    public String accountName { get; set; }
    @AuraEnabled
    public String locationName { get; set; }
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public Boolean quarterlyPayment { get; set; }
  }

  /**
   * Picklist options for OrderItem.Termination_Reason__c (Package Builder bulk update modal).
   * Uses field describe so options load regardless of UI API record type defaults.
   */
  @AuraEnabled(cacheable=true)
  public static List<PicklistLabelValue> getOrderItemTerminationReasonPicklistOptions() {
    List<PicklistLabelValue> options = new List<PicklistLabelValue>();
    Schema.DescribeFieldResult dfr = OrderItem.Termination_Reason__c.getDescribe();
    for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
      if (!pe.isActive()) {
        continue;
      }
      PicklistLabelValue row = new PicklistLabelValue();
      row.label = pe.getLabel();
      row.value = pe.getValue();
      options.add(row);
    }
    return options;
  }

  /**
   * Picklist options for Order.Moved_To__c (Package Builder terminate modal).
   */
  @AuraEnabled(cacheable=true)
  public static List<PicklistLabelValue> getOrderMovedToPicklistOptions() {
    List<PicklistLabelValue> options = new List<PicklistLabelValue>();
    Schema.DescribeFieldResult dfr = Order.Moved_To__c.getDescribe();
    for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
      if (!pe.isActive()) {
        continue;
      }
      PicklistLabelValue row = new PicklistLabelValue();
      row.label = pe.getLabel();
      row.value = pe.getValue();
      options.add(row);
    }
    return options;
  }

  /**
   * Picklist options for Order.Payment_Method__c (Package Builder in-memory order section).
   */
  @AuraEnabled(cacheable=true)
  public static List<PicklistLabelValue> getOrderPaymentMethodPicklistOptions() {
    List<PicklistLabelValue> options = new List<PicklistLabelValue>();
    Schema.DescribeFieldResult dfr = Order.Payment_Method__c.getDescribe();
    for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
      if (!pe.isActive()) {
        continue;
      }
      PicklistLabelValue row = new PicklistLabelValue();
      row.label = pe.getLabel();
      row.value = pe.getValue();
      options.add(row);
    }
    return options;
  }

  public class PicklistLabelValue {
    @AuraEnabled
    public String label { get; set; }
    @AuraEnabled
    public String value { get; set; }
  }

  /**
   * Returns the active and draft orders for a contract.
   */
  @AuraEnabled(cacheable=true)
  public static Map<String, Order> getContractOrders(Id contractId) {
    Map<String, Order> orders = new Map<String, Order>();

    List<Order> contractOrders = [
      SELECT
        Id,
        Status,
        EffectiveDate,
        Order_Start_Date__c,
        EndDate,
        Previous_Order__c,
        Replacement_Start_Date__c
      FROM Order
      WHERE
        ContractId = :contractId
        AND (Status = 'Activated'
        OR Status = 'Draft'
        OR Status = 'Negotiation'
        OR Status = 'Cancelled')
      ORDER BY CreatedDate DESC
    ];

    for (Order ord : contractOrders) {
      if (ord.Status == 'Activated' && !orders.containsKey('active')) {
        orders.put('active', ord);
      } else if (
        (ord.Status == 'Draft' || ord.Status == 'Negotiation') &&
        !orders.containsKey('draft')
      ) {
        orders.put('draft', ord);
      }
    }

    return orders;
  }

  /**
   * Ensures a draft order exists for a contract, optionally seeding business start date on first create.
   */
  @AuraEnabled
  public static PackageBuilderService.DraftOrderResult ensureDraftOrderWithStartDate(
    Id contractId,
    Date initialOrderStartDate
  ) {
    return PackageBuilderService.ensureDraftOrderWithStartDate(
      contractId,
      initialOrderStartDate
    );
  }

  /**
   * Activates a draft order with the given replacement start date.
   */
  @AuraEnabled
  public static void activateDraftOrder(Id orderId, Date replacementStartDate) {
    PackageBuilderService.activateDraftOrder(orderId, replacementStartDate);
  }

  @AuraEnabled
  public static void reconcileContractTermsForCutoff(
    Id draftOrderId,
    Date cutoffDate
  ) {
    PackageBuilderService.reconcileContractTermsForCutoff(
      draftOrderId,
      cutoffDate
    );
  }

  @AuraEnabled
  public static void updateOrderItemEarlyExitRequest(
    Id orderItemId,
    Boolean earlyExitRequest
  ) {
    if (orderItemId == null) {
      throw new AuraHandledException('Order product Id is required.');
    }
    OrderItem oi = [
      SELECT Id, Early_Exit_Request__c
      FROM OrderItem
      WHERE Id = :orderItemId
      LIMIT 1
    ];
    oi.Early_Exit_Request__c = earlyExitRequest == true;
    update oi;
  }

  @AuraEnabled
  public static void finalizeTerminateAll(
    Id contractId,
    Id draftOrderId,
    String terminationReason,
    Date exitDate
  ) {
    PackageBuilderService.finalizeTerminateAll(
      contractId,
      draftOrderId,
      terminationReason,
      exitDate
    );
  }

  /**
   * Updates the working order status between Draft and Negotiation.
   */
  @AuraEnabled
  public static void setOrderStatus(Id orderId, String newStatus) {
    PackageBuilderService.setOrderStatus(orderId, newStatus);
  }

  /**
   * Soft-removes a draft order from Package Builder by setting Status to Cancelled.
   */
  @AuraEnabled
  public static void cancelDraftOrder(Id draftOrderId) {
    PackageBuilderService.cancelDraftOrder(draftOrderId);
  }

  /**
   * Aligns OrderItem ServiceDate / Original_Start_Date__c to a new business order start (Order_Start_Date__c).
   * Moving the start earlier: update Order_Start_Date__c first, then call this —
   * otherwise Salesforce returns FIELD_INTEGRITY_EXCEPTION (line start before Customer Package Start Date).
   * Moving later: call this before updating the Order.
   *
   * Existing copied products  → keep ServiceDate / Original_Start_Date__c unchanged.
   * When {@code alignChangeTypeNewLines} is true: New / replacement products whose start is before
   * the new order start → ServiceDate AND Original_Start_Date__c = newOrderStartDate (never pull later starts back).
   * When false (backdate path): New / replacement line starts are left unchanged.
   * Non-replacement new lines with EndDate strictly before the new order start are skipped for start alignment.
   * Replacement children (Replaced_Order_Product__c set) with start before the new order start are aligned so end dates can be repaired afterward.
   * Replacement pairs: replaced line EndDate / Original_End_Date__c = replacement ServiceDate minus one calendar day.
   * Repairs degenerate child EndDate (start == end or end before start). Replacement lookups are kept
   * so backdating contract start restores correct pair ordering and icons in Package Builder.
   */
  @AuraEnabled
  public static void alignOrderItemDatesForStartDateChange(
    Id orderId,
    Date newOrderStartDate,
    Boolean alignChangeTypeNewLines
  ) {
    if (orderId == null || newOrderStartDate == null) {
      return;
    }
    validateOrderStartNotBeforePreviousActivated(orderId, newOrderStartDate);
    Boolean alignNewLines = alignChangeTypeNewLines == null
      ? true
      : alignChangeTypeNewLines;
    alignOrderItemDatesForStartDateChangeCore(
      orderId,
      newOrderStartDate,
      alignNewLines,
      true
    );
  }

  /**
   * Shared alignment for LWC toolbar and OrderTriggerHandler draft start changes.
   * @param wrapAuraErrors when true, DML failures become AuraHandledException (UI path).
   */
  public static void alignOrderItemDatesForStartDateChangeCore(
    Id orderId,
    Date newOrderStartDate,
    Boolean alignNewLines,
    Boolean wrapAuraErrors
  ) {
    if (orderId == null || newOrderStartDate == null) {
      return;
    }
    if (alignNewLines == null) {
      alignNewLines = true;
    }

    OrderItemTriggerHandler.SKIP_DATE_SYNC = true;
    try {
      Order ord = [
        SELECT Id, EndDate, ContractId, Status
        FROM Order
        WHERE Id = :orderId
        LIMIT 1
      ];

      List<OrderItem> items = [
        SELECT
          Id,
          ServiceDate,
          Original_Start_Date__c,
          EndDate,
          Original_End_Date__c,
          Original_Order_Product__c,
          Change_Type__c,
          Replaced_Order_Product__c,
          Termination_Reason__c,
          Is_Line_Deleted__c
        FROM OrderItem
        WHERE OrderId = :orderId
      ];
      Map<Id, OrderItem> originalsById = snapshotOrderItemsForAlign(items);
      Map<Id, OrderItem> toUpdateById = new Map<Id, OrderItem>();

      if (alignNewLines) {
        for (OrderItem oi : items) {
          if (oi.Is_Line_Deleted__c == true) {
            continue;
          }
          Boolean isExistingLine =
            oi.Original_Order_Product__c != null &&
            oi.Change_Type__c != 'New';
          if (isExistingLine) {
            continue;
          }
          // Replacement children may have EndDate before the new order start until repaired below.
          if (
            oi.EndDate != null &&
            oi.EndDate < newOrderStartDate &&
            oi.Replaced_Order_Product__c == null
          ) {
            continue;
          }
          if (oi.ServiceDate != null && oi.ServiceDate >= newOrderStartDate) {
            continue;
          }
          Boolean changed = false;
          if (oi.ServiceDate != newOrderStartDate) {
            oi.ServiceDate = newOrderStartDate;
            changed = true;
          }
          if (changed) {
            toUpdateById.put(oi.Id, oi);
          }
        }
      }

      Map<Id, OrderItem> byId = new Map<Id, OrderItem>();
      for (OrderItem oi : items) {
        byId.put(oi.Id, oi);
      }

      reconcileReplacedParentEndsForReplacementChildren(
        items,
        byId,
        toUpdateById
      );

      // Backdate: restore replacement lookup when parent becomes visible again (link may have
      // been cleared by an earlier forward align in the same draft session).
      if (!alignNewLines) {
        restoreReplacementLinksAfterBackdate(items, toUpdateById);
        reconcileReplacedParentEndsForReplacementChildren(
          items,
          byId,
          toUpdateById
        );
      }

      if (!toUpdateById.isEmpty()) {
        Date coveredOrderEnd = ensureDraftOrderEndCoversLineEndDates(
          orderId,
          toUpdateById.values(),
          originalsById
        );
        if (coveredOrderEnd != null) {
          ord.EndDate = coveredOrderEnd;
        }

        for (OrderItem oi : items) {
          OrderItem workingChild = effectiveOrderItem(oi, toUpdateById);
          Boolean isNewOrReplacement =
            workingChild.Change_Type__c == 'New' ||
            workingChild.Replaced_Order_Product__c != null ||
            workingChild.Original_Order_Product__c == null;
          if (!isNewOrReplacement) {
            continue;
          }
          repairReplacementChildEndDate(
            workingChild,
            ord.EndDate,
            toUpdateById
          );
        }

        coveredOrderEnd = ensureDraftOrderEndCoversLineEndDates(
          orderId,
          toUpdateById.values(),
          originalsById
        );
        if (coveredOrderEnd != null) {
          ord.EndDate = coveredOrderEnd;
        }

        List<OrderItem> alignPatches = buildOrderItemAlignUpdatePatches(
          originalsById,
          toUpdateById
        );
        if (!alignPatches.isEmpty()) {
          update alignPatches;
        }
      }
    } catch (Exception e) {
      if (!wrapAuraErrors) {
        throw e;
      }
      String detail;
      if (e instanceof DmlException) {
        DmlException de = (DmlException) e;
        detail = de.getNumDml() > 0 ? de.getDmlMessage(0) : de.getMessage();
      } else {
        detail = e.getMessage();
      }
      throw new AuraHandledException(
        'Could not update product lines to match the new order start date. ' +
        detail
      );
    } finally {
      OrderItemTriggerHandler.SKIP_DATE_SYNC = false;
    }
  }

  @TestVisible
  private static Map<Id, OrderItem> snapshotOrderItemsForAlign(
    List<OrderItem> items
  ) {
    Map<Id, OrderItem> originalsById = new Map<Id, OrderItem>();
    if (items == null) {
      return originalsById;
    }
    for (OrderItem oi : items) {
      if (oi == null || oi.Id == null) {
        continue;
      }
      originalsById.put(
        oi.Id,
        new OrderItem(
          Id = oi.Id,
          ServiceDate = oi.ServiceDate,
          EndDate = oi.EndDate,
          Replaced_Order_Product__c = oi.Replaced_Order_Product__c
        )
      );
    }
    return originalsById;
  }

  @TestVisible
  private static List<OrderItem> buildOrderItemAlignUpdatePatches(
    Map<Id, OrderItem> originalsById,
    Map<Id, OrderItem> toUpdateById
  ) {
    List<OrderItem> patches = new List<OrderItem>();
    if (toUpdateById == null || toUpdateById.isEmpty()) {
      return patches;
    }
    for (OrderItem working : toUpdateById.values()) {
      OrderItem before = originalsById != null
        ? originalsById.get(working.Id)
        : null;
      if (before != null && !PackageBuilderService.isLineVisible(before)) {
        continue;
      }
      OrderItem patch = buildSingleOrderItemAlignPatch(before, working);
      if (patch != null) {
        patches.add(patch);
      }
    }
    return patches;
  }

  @TestVisible
  private static OrderItem buildSingleOrderItemAlignPatch(
    OrderItem before,
    OrderItem after
  ) {
    if (after == null || after.Id == null) {
      return null;
    }
    OrderItem patch = new OrderItem(Id = after.Id);
    Boolean changed = false;
    if (before == null || before.ServiceDate != after.ServiceDate) {
      patch.ServiceDate = after.ServiceDate;
      changed = true;
    }
    if (before == null || before.EndDate != after.EndDate) {
      patch.EndDate = after.EndDate;
      changed = true;
    }
    if (
      before == null ||
      before.Replaced_Order_Product__c != after.Replaced_Order_Product__c
    ) {
      patch.Replaced_Order_Product__c = after.Replaced_Order_Product__c;
      changed = true;
    }
    return changed ? patch : null;
  }

  private static void validateOrderStartNotBeforePreviousActivated(
    Id orderId,
    Date newOrderStartDate
  ) {
    Order orderForValidation = [
      SELECT Id, Previous_Order__c
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (orderForValidation.Previous_Order__c == null) {
      return;
    }
    List<Order> previousOrders = [
      SELECT Id, Status, Order_Start_Date__c, EffectiveDate
      FROM Order
      WHERE Id = :orderForValidation.Previous_Order__c
      LIMIT 1
    ];
    if (previousOrders.isEmpty() || previousOrders[0].Status != 'Activated') {
      return;
    }
    Date previousStart = previousOrders[0].Order_Start_Date__c != null
      ? previousOrders[0].Order_Start_Date__c
      : previousOrders[0].EffectiveDate;
    if (previousStart != null && newOrderStartDate < previousStart) {
      throw new AuraHandledException(
        'Order start date cannot be earlier than previous activated order start date (' +
          String.valueOf(previousStart) +
          ').'
      );
    }
  }

  @TestVisible
  private static Date effectiveServiceDate(
    OrderItem oi,
    Map<Id, OrderItem> pendingUpdates
  ) {
    if (oi == null) {
      return null;
    }
    OrderItem pending = pendingUpdates != null
      ? pendingUpdates.get(oi.Id)
      : null;
    if (pending != null && pending.ServiceDate != null) {
      return pending.ServiceDate;
    }
    return oi.ServiceDate;
  }

  @TestVisible
  private static OrderItem effectiveOrderItem(
    OrderItem oi,
    Map<Id, OrderItem> pendingUpdates
  ) {
    if (oi == null) {
      return null;
    }
    OrderItem pending = pendingUpdates != null
      ? pendingUpdates.get(oi.Id)
      : null;
    return pending != null ? pending : oi;
  }

  /**
   * Resolve the draft replaced (moving-out) line for a replacement child. The lookup may point
   * at the draft Removed/Modified row, or at the activated line id stored on Original_Order_Product__c.
   */
  @TestVisible
  private static OrderItem resolveReplacedParentForReplacement(
    OrderItem replacement,
    Map<Id, OrderItem> byId,
    List<OrderItem> items
  ) {
    if (replacement == null || replacement.Replaced_Order_Product__c == null) {
      return null;
    }
    Id linkId = replacement.Replaced_Order_Product__c;
    if (byId.containsKey(linkId)) {
      return byId.get(linkId);
    }
    for (OrderItem candidate : items) {
      if (candidate.Id == linkId) {
        return candidate;
      }
    }
    for (OrderItem candidate : items) {
      if (
        candidate.Original_Order_Product__c == linkId &&
        (candidate.Change_Type__c == 'Removed' ||
        candidate.Change_Type__c == 'Modified' ||
        candidate.Change_Type__c == 'No Change')
      ) {
        return candidate;
      }
    }
    return null;
  }

  /**
   * Sets each superseded (moving-out) line EndDate / Original_End_Date__c to the linked
   * replacement ServiceDate minus one calendar day.
   */
  @TestVisible
  private static void reconcileReplacedParentEndsForReplacementChildren(
    List<OrderItem> items,
    Map<Id, OrderItem> byId,
    Map<Id, OrderItem> toUpdateById
  ) {
    if (items == null || items.isEmpty()) {
      return;
    }
    for (OrderItem oi : items) {
      OrderItem workingChild = effectiveOrderItem(oi, toUpdateById);
      if (workingChild.Is_Line_Deleted__c == true) {
        continue;
      }
      if (workingChild.Replaced_Order_Product__c == null) {
        continue;
      }
      Date childStart = effectiveServiceDate(workingChild, toUpdateById);
      if (childStart == null) {
        continue;
      }
      OrderItem replaced = resolveReplacedParentForReplacement(
        workingChild,
        byId,
        items
      );
      if (replaced == null) {
        continue;
      }
      applyReplacedEndBeforeReplacementStart(
        replaced,
        childStart,
        toUpdateById
      );
    }
  }

  @TestVisible
  private static void applyReplacedEndBeforeReplacementStart(
    OrderItem replaced,
    Date replacementStart,
    Map<Id, OrderItem> toUpdateById
  ) {
    if (replaced == null || replacementStart == null) {
      return;
    }
    if (!PackageBuilderService.isLineVisible(replaced)) {
      return;
    }
    if (String.isNotBlank(replaced.Termination_Reason__c)) {
      return;
    }
    Date targetEnd = replacementStart.addDays(-1);
    if (replaced.ServiceDate != null && targetEnd < replaced.ServiceDate) {
      targetEnd = replaced.ServiceDate;
    }
    OrderItem working = toUpdateById.containsKey(replaced.Id)
      ? toUpdateById.get(replaced.Id)
      : replaced;
    if (working.EndDate != targetEnd) {
      working.EndDate = targetEnd;
      toUpdateById.put(working.Id, working);
    }
  }

  /**
   * Re-links New replacement rows to Removed parents when the lookup was cleared during a prior
   * forward order-start align and the user backdates (alignChangeTypeNewLines = false).
   */
  @TestVisible
  private static void restoreReplacementLinksAfterBackdate(
    List<OrderItem> items,
    Map<Id, OrderItem> toUpdateById
  ) {
    if (items == null || items.isEmpty()) {
      return;
    }
    List<OrderItem> supersededParents = new List<OrderItem>();
    for (OrderItem oi : items) {
      if (
        (oi.Change_Type__c == 'Removed' || oi.Change_Type__c == 'Modified') &&
        PackageBuilderService.isLineVisible(oi)
      ) {
        supersededParents.add(oi);
      }
    }
    if (supersededParents.isEmpty()) {
      return;
    }
    for (OrderItem oi : items) {
      OrderItem workingChild = effectiveOrderItem(oi, toUpdateById);
      if (
        workingChild.Change_Type__c != 'New' ||
        workingChild.Replaced_Order_Product__c != null
      ) {
        continue;
      }
      Date childStart = effectiveServiceDate(workingChild, toUpdateById);
      if (childStart == null) {
        continue;
      }
      List<OrderItem> matches = new List<OrderItem>();
      for (OrderItem parent : supersededParents) {
        if (parent.Id == null) {
          continue;
        }
        if (supersededParentMatchesOrphanReplacement(parent, childStart)) {
          matches.add(parent);
        }
      }
      if (matches.isEmpty()) {
        continue;
      }
      OrderItem bestParent = selectBestSupersededParentForReplacement(
        matches,
        childStart
      );
      if (bestParent != null) {
        workingChild.Replaced_Order_Product__c = bestParent.Id;
        toUpdateById.put(workingChild.Id, workingChild);
      }
    }
  }

  /**
   * True when a Removed/Modified parent can pair with an orphan replacement child on backdate.
   * Uses child start minus one day so a reverted package end on the parent does not block re-link.
   */
  @TestVisible
  private static Boolean supersededParentMatchesOrphanReplacement(
    OrderItem parent,
    Date childStart
  ) {
    if (parent == null || childStart == null) {
      return false;
    }
    Date expectedParentEnd = childStart.addDays(-1);
    if (
      parent.EndDate != null &&
      replacementStartFollowsRemovedEnd(parent.EndDate, childStart)
    ) {
      return true;
    }
    if (parent.ServiceDate == null || parent.ServiceDate > expectedParentEnd) {
      return false;
    }
    return parent.Change_Type__c == 'Removed' ||
      parent.Change_Type__c == 'Modified';
  }

  @TestVisible
  private static OrderItem selectBestSupersededParentForReplacement(
    List<OrderItem> candidates,
    Date childStart
  ) {
    if (candidates == null || candidates.isEmpty()) {
      return null;
    }
    if (candidates.size() == 1) {
      return candidates[0];
    }
    Date expectedEnd = childStart != null ? childStart.addDays(-1) : null;
    OrderItem best = null;
    Integer bestScore = -1;
    for (OrderItem parent : candidates) {
      Integer score = 0;
      if (expectedEnd != null && parent.EndDate == expectedEnd) {
        score += 100;
      } else if (
        parent.EndDate != null &&
        replacementStartFollowsRemovedEnd(parent.EndDate, childStart)
      ) {
        score += 80;
      } else if (parent.Change_Type__c == 'Removed') {
        score += 40;
      } else if (parent.Change_Type__c == 'Modified') {
        score += 20;
      }
      if (score > bestScore) {
        bestScore = score;
        best = parent;
      }
    }
    return best != null ? best : candidates[0];
  }

  @TestVisible
  private static Date resolveReplacedEndDateOnReplacementDelete(
    Date replacementEnd,
    Date activeEnd,
    Boolean undoPastStartSplit,
    String replacedAccessType,
    Boolean undoAccessTypeChangeReplacement
  ) {
    if (
      undoPastStartSplit == true &&
      String.isNotBlank(replacedAccessType) &&
      'Monthly'.equalsIgnoreCase(replacedAccessType.trim())
    ) {
      return null;
    }
    if (undoAccessTypeChangeReplacement == true && replacementEnd == null) {
      return activeEnd;
    }
    if (replacementEnd == null) {
      return null;
    }
    if (activeEnd == null) {
      return replacementEnd;
    }
    return replacementEnd > activeEnd ? replacementEnd : activeEnd;
  }

  /**
   * Extends draft Order.EndDate (and Contract when linked) so pending line EndDate(s)
   * pass platform validation, including when the order was previously open-ended (EndDate null).
   * @return effective Order.EndDate after extension, or null when order stays open-ended
   */
  @TestVisible
  private static Date ensureDraftOrderEndCoversLineEndDates(
    Id orderId,
    Iterable<OrderItem> lines,
    Map<Id, OrderItem> originalsById
  ) {
    if (orderId == null || lines == null) {
      return null;
    }
    Date maxLineEnd = null;
    for (OrderItem oi : lines) {
      if (oi == null || oi.EndDate == null) {
        continue;
      }
      if (!PackageBuilderService.isLineVisible(oi)) {
        continue;
      }
      if (originalsById != null) {
        OrderItem before = originalsById.get(oi.Id);
        if (before != null && before.EndDate == oi.EndDate) {
          continue;
        }
      }
      if (maxLineEnd == null || oi.EndDate > maxLineEnd) {
        maxLineEnd = oi.EndDate;
      }
    }

    if (maxLineEnd != null) {
      for (AggregateResult ar : [
        SELECT MAX(EndDate) maxEnd
        FROM OrderItem
        WHERE
          OrderId = :orderId
          AND EndDate != NULL
          AND (Is_Line_Deleted__c = FALSE
          OR Is_Line_Deleted__c = NULL)
      ]) {
        Date persistedMax = (Date) ar.get('maxEnd');
        if (
          persistedMax != null &&
          (maxLineEnd == null ||
          persistedMax > maxLineEnd)
        ) {
          maxLineEnd = persistedMax;
        }
      }
    }

    if (maxLineEnd == null) {
      return null;
    }

    List<Order> orders = [
      SELECT Id, Status, EndDate, ContractId
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (orders.isEmpty()) {
      return null;
    }
    Order ord = orders[0];
    if (ord.Status == 'Cancelled' || ord.Status == 'Archived') {
      return ord.EndDate;
    }
    if (ord.EndDate != null && maxLineEnd <= ord.EndDate) {
      return ord.EndDate;
    }

    PackageBuilderService.prepareDraftOrderEndForLineSave(orderId, maxLineEnd);
    return maxLineEnd;
  }

  @TestVisible
  private static Boolean replacementStartFollowsRemovedEnd(
    Date replacedEnd,
    Date replacementStart
  ) {
    if (replacedEnd == null || replacementStart == null) {
      return false;
    }
    if (replacementStart == replacedEnd) {
      return true;
    }
    return replacementStart == replacedEnd.addDays(1);
  }

  @TestVisible
  private static void repairReplacementChildEndDate(
    OrderItem replacement,
    Date orderEndDate,
    Map<Id, OrderItem> toUpdateById
  ) {
    if (replacement == null || replacement.ServiceDate == null) {
      return;
    }
    if (String.isNotBlank(replacement.Termination_Reason__c)) {
      return;
    }
    Date svc = replacement.ServiceDate;
    Date lineEnd = replacement.EndDate;
    if (lineEnd == null) {
      return;
    }
    if (lineEnd >= svc && lineEnd != svc) {
      return;
    }
    Date priorEnd = lineEnd;
    Date repairedEnd;
    if (orderEndDate != null && orderEndDate >= svc) {
      repairedEnd = orderEndDate;
    } else if (orderEndDate == null) {
      repairedEnd = null;
    } else {
      repairedEnd = svc;
    }
    if (repairedEnd == replacement.EndDate) {
      return;
    }
    replacement.EndDate = repairedEnd;
    toUpdateById.put(replacement.Id, replacement);
  }

  /**
   * Returns KPI summary metrics for an order.
   */
  @AuraEnabled(cacheable=true)
  public static PackageBuilderService.OrderSummary getOrderSummary(Id orderId) {
    return PackageBuilderService.getOrderSummary(orderId);
  }

  /**
   * Returns key Order fields for display in Package Builder (e.g. Draft order section).
   * So users can see Order info without leaving the page.
   */
  /**
   * Package Builder KPI: sum of monthly payment line payables (Price + Discount rules) keyed by
   * OpportunityLineItem Id or OrderItem Id (string keys for LWC).
   *
   * @param parentRecordId Opportunity Id or Order Id
   */
  @AuraEnabled(cacheable=true)
  public static Map<String, Decimal> getMonthlyPaymentPayableSumsForPackageBuilder(
    String parentRecordId
  ) {
    Map<String, Decimal> out = new Map<String, Decimal>();
    if (String.isBlank(parentRecordId)) {
      return out;
    }
    try {
      Id pid = (Id) parentRecordId;
      Map<Id, Decimal> sums = PackageBuilderService.getMonthlyPaymentPayableSumsForParentRecord(
        pid
      );
      for (Id k : sums.keySet()) {
        out.put(String.valueOf(k), sums.get(k));
      }
    } catch (Exception e) {
      // Invalid id — return empty map for stable LWC wire
    }
    return out;
  }

  /**
   * Package Builder KPI: periodic-rooms tile — sum of Price * (1 + discount rate) per monthly payment with the same
   * discount normalization as payables (10 = 10%); see PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord.
   */
  @AuraEnabled(cacheable=true)
  public static Map<String, Decimal> getMonthlyPaymentOneMinusDiscountSumsForPackageBuilder(
    String parentRecordId
  ) {
    Map<String, Decimal> out = new Map<String, Decimal>();
    if (String.isBlank(parentRecordId)) {
      return out;
    }
    try {
      Id pid = (Id) parentRecordId;
      Map<Id, Decimal> sums = PackageBuilderService.getMonthlyPaymentOneMinusDiscountSumsForParentRecord(
        pid
      );
      for (Id k : sums.keySet()) {
        out.put(String.valueOf(k), sums.get(k));
      }
    } catch (Exception e) {
    }
    return out;
  }

  @AuraEnabled(cacheable=true)
  public static OrderDetailsResult getOrderDetails(Id orderId) {
    if (orderId == null)
      return null;
    List<Order> orders = [
      SELECT
        Id,
        OrderNumber,
        EffectiveDate,
        Order_Start_Date__c,
        EndDate,
        Status,
        TotalAmount,
        Description,
        Depusit_Amount_DM__c,
        Number_of_members__c,
        Early_Termination_Fee__c,
        Moved_To__c,
        CreatedDate,
        LastModifiedDate,
        Lease_Termination_Notice_Months__c,
        Agreement_language__c,
        Payment_Method__c,
        Auto_Renewal__c,
        Renewal_Status__c,
        Renewal_Total_Iterations__c,
        Renewal_end_date__c,
        Last_Status_Change_Date__c,
        Non_Renewal_Reason__c,
        Renewal_Period_Months__c,
        Renewal_Price_Increase_Percent__c,
        Google_Drive_Link__c,
        ContractId
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (orders.isEmpty())
      return null;
    Order o = orders[0];
    OrderDetailsResult r = new OrderDetailsResult();
    r.status = o.Status;
    r.orderNumber = o.OrderNumber;
    r.effectiveDate = o.Order_Start_Date__c != null
      ? o.Order_Start_Date__c
      : o.EffectiveDate;
    /** Order_Start_Date__c only (no EffectiveDate fallback) — for Package Builder modals that must key off the custom field. */
    r.orderStartDateOnly = o.Order_Start_Date__c;
    r.endDate = o.EndDate;
    r.totalAmount = o.TotalAmount;
    r.description = o.Description;
    r.depositAmountDm = o.Depusit_Amount_DM__c;
    r.earlyTerminationFee = o.Early_Termination_Fee__c;
    r.movedTo = o.Moved_To__c;
    r.numberOfMembers = o.Number_of_members__c;
    r.createdDateTime = o.CreatedDate;
    r.lastModifiedDateTime = o.LastModifiedDate;
    r.noticePeriodMonths = o.Lease_Termination_Notice_Months__c;
    r.agreementLanguage = o.Agreement_language__c;
    r.paymentMethod = o.Payment_Method__c;
    r.autoRenewal = o.Auto_Renewal__c;
    r.renewalStatus = o.Renewal_Status__c;
    r.renewalTotalIterations = o.Renewal_Total_Iterations__c;
    r.renewalEndDate = o.Renewal_end_date__c;
    r.lastStatusChangeDate = o.Last_Status_Change_Date__c;
    r.nonRenewalReason = o.Non_Renewal_Reason__c;
    r.renewalPeriodMonths = o.Renewal_Period_Months__c;
    r.renewalPriceIncreasePercent = o.Renewal_Price_Increase_Percent__c;
    r.googleDriveLink = o.Google_Drive_Link__c;
    r.nextRenewalDate = null;
    r.autoRenewalCancellationDeadline = null;
    return r;
  }

  /**
   * Monthly replaced-parent lines must keep EndDate when a replacement child exists (or when
   * Change_Type__c is Removed). Mirrors LWC _lineMustKeepCurtailedEndForReplacement.
   */
  private static void assertMonthlyReplacementParentKeepsEndDate(
    List<SObject> lineItems,
    Map<Id, OrderItem> existingOrderItemsById
  ) {
    if (
      lineItems == null ||
      lineItems.isEmpty() ||
      existingOrderItemsById == null ||
      existingOrderItemsById.isEmpty()
    ) {
      return;
    }
    Set<Id> parentIdsClearingEnd = new Set<Id>();
    for (SObject item : lineItems) {
      Id oiId = (Id) item.get('Id');
      OrderItem existing = existingOrderItemsById.get(oiId);
      if (existing == null) {
        continue;
      }
      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      if (!fields.containsKey('EndDate')) {
        continue;
      }
      if (item.get('EndDate') != null) {
        continue;
      }
      if (String.isNotBlank(existing.Termination_Reason__c)) {
        continue;
      }
      String accessType = fields.containsKey('Access_Type__c')
        ? (String) item.get('Access_Type__c')
        : existing.Access_Type__c;
      if (!PackageBuilderAccessTypePolicy.isMonthlyLike(accessType)) {
        continue;
      }
      parentIdsClearingEnd.add(oiId);
    }
    if (parentIdsClearingEnd.isEmpty()) {
      return;
    }
    Set<Id> parentsWithReplacementChild = new Set<Id>();
    for (OrderItem child : [
      SELECT Replaced_Order_Product__c
      FROM OrderItem
      WHERE
        Replaced_Order_Product__c IN :parentIdsClearingEnd
        AND Is_Line_Deleted__c = FALSE
    ]) {
      if (child.Replaced_Order_Product__c != null) {
        parentsWithReplacementChild.add(child.Replaced_Order_Product__c);
      }
    }
    for (Id parentId : parentIdsClearingEnd) {
      OrderItem existing = existingOrderItemsById.get(parentId);
      if (existing == null) {
        continue;
      }
      Boolean mustKeepEnd =
        parentsWithReplacementChild.contains(parentId) ||
        'Removed'.equals(existing.Change_Type__c);
      if (mustKeepEnd) {
        throw new AuraHandledException(
          System.Label.PackageBuilder_MonthlyReplacementEndDateRequired
        );
      }
    }
  }

  /**
   * Terminated contract products (Termination_Reason__c) must not receive Package Builder line edits
   * for access type, start date, pricing, or description. Draft terminated lines may update EndDate.
   */
  private static void assertPackageBuilderDoesNotEditTerminatedOrderItems(
    List<SObject> lineItems,
    Map<Id, OrderItem> existingOrderItemsById
  ) {
    if (
      lineItems == null ||
      lineItems.isEmpty() ||
      existingOrderItemsById == null ||
      existingOrderItemsById.isEmpty()
    ) {
      return;
    }
    for (SObject item : lineItems) {
      Id oid = (Id) item.get('Id');
      if (oid == null) {
        continue;
      }
      OrderItem existing = existingOrderItemsById.get(oid);
      if (existing == null || String.isBlank(existing.Termination_Reason__c)) {
        continue;
      }
      Map<String, Object> fields = item.getPopulatedFieldsAsMap();
      Boolean clearingTermination =
        fields.containsKey('Termination_Reason__c') &&
        String.isBlank((String) item.get('Termination_Reason__c'));
      for (String fieldName : fields.keySet()) {
        if (fieldName == null || 'Id'.equalsIgnoreCase(fieldName)) {
          continue;
        }
        if (
          'EndDate'.equalsIgnoreCase(fieldName) &&
          existing.Order != null &&
          existing.Order.Status == 'Draft'
        ) {
          continue;
        }
        if (
          clearingTermination &&
          ('Termination_Reason__c'.equalsIgnoreCase(fieldName) ||
          'EndDate'.equalsIgnoreCase(fieldName) ||
          'Original_End_Date__c'.equalsIgnoreCase(fieldName))
        ) {
          continue;
        }
        if (TERMINATED_ORDER_ITEM_SAVE_BLOCKED_FIELDS.contains(fieldName)) {
          throw new AuraHandledException(
            System.Label.PackageBuilder_TerminatedOrderItemNoEdit
          );
        }
      }
    }
  }

  public class OrderDetailsResult {
    /** Order.Status — drives Package Builder draft status path (Draft / Negotiation / Activated). */
    @AuraEnabled
    public String status { get; set; }
    @AuraEnabled
    public String orderNumber { get; set; }
    @AuraEnabled
    public Date effectiveDate { get; set; }
    @AuraEnabled
    public Date orderStartDateOnly { get; set; }
    @AuraEnabled
    public Date endDate { get; set; }
    @AuraEnabled
    public Decimal totalAmount { get; set; }
    @AuraEnabled
    public String description { get; set; }
    @AuraEnabled
    public Decimal depositAmountDm { get; set; }
    @AuraEnabled
    public Decimal earlyTerminationFee { get; set; }
    @AuraEnabled
    public String movedTo { get; set; }
    @AuraEnabled
    public Decimal numberOfMembers { get; set; }
    @AuraEnabled
    public Datetime createdDateTime { get; set; }
    @AuraEnabled
    public Datetime lastModifiedDateTime { get; set; }
    @AuraEnabled
    public String noticePeriodMonths { get; set; }
    @AuraEnabled
    public String agreementLanguage { get; set; }
    @AuraEnabled
    public String paymentMethod { get; set; }
    @AuraEnabled
    public Boolean autoRenewal { get; set; }
    @AuraEnabled
    public String renewalStatus { get; set; }
    @AuraEnabled
    public String renewalTotalIterations { get; set; }
    @AuraEnabled
    public Date renewalEndDate { get; set; }
    @AuraEnabled
    public Date lastStatusChangeDate { get; set; }
    @AuraEnabled
    public String nonRenewalReason { get; set; }
    @AuraEnabled
    public Decimal renewalPeriodMonths { get; set; }
    @AuraEnabled
    public Decimal renewalPriceIncreasePercent { get; set; }
    @AuraEnabled
    public String googleDriveLink { get; set; }
    @AuraEnabled
    public Date nextRenewalDate { get; set; }
    @AuraEnabled
    public Date autoRenewalCancellationDeadline { get; set; }
  }
}
