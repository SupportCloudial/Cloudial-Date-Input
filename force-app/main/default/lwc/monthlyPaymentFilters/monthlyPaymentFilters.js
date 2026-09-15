import getMonthlyPayments from "@salesforce/apex/OpportunityService.getMonthlyPayments";
import { onError, subscribe, unsubscribe } from "lightning/empApi";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { getObjectInfo, getPicklistValues } from "lightning/uiObjectInfoApi";
import { getRecord } from "lightning/uiRecordApi";
import { api, LightningElement, track, wire } from "lwc";

import applyFilter_btn from "@salesforce/label/c.cp_applyFilter_btn";
import endMonth_label from "@salesforce/label/c.cp_endMonth_label";
import endYear_label from "@salesforce/label/c.cp_endYear_label";
import filtersCategory_Date from "@salesforce/label/c.cp_filtersCategory_Date";
import filtersCategory_Product from "@salesforce/label/c.cp_filtersCategory_Product";
import segmentationDisplay from "@salesforce/label/c.cp_forecast_segmentationDisplay";
import product_label from "@salesforce/label/c.cp_product_label";
import productSubType_label from "@salesforce/label/c.cp_productSubType_label";
import productType_label from "@salesforce/label/c.cp_productType_label";
import currency_btnGrp from "@salesforce/label/c.cp_currency_btnGrp";
import units_btnGrp from "@salesforce/label/c.cp_units_btnGrp";
import startMonth_label from "@salesforce/label/c.cp_startMonth_label";
import startYear_label from "@salesforce/label/c.cp_startYear_label";
import Product from "@salesforce/schema/Product2";
import Subtype from "@salesforce/schema/Product2.Sub_Type__c";
import ProductType from "@salesforce/schema/Product2.Type__c";

const DefaultProductType = "Standard Products";

export default class MonthlyPaymentFilters extends NavigationMixin(
  LightningElement
) {
  @track monthlyPayments = [];
  @track filteredMonthlyPayments = [];
  @track filters = {};
  @api recordId;

  productSelectedFilter;
  productSubTypeSelectedFilter;
  startMonthFilter;
  startYearFilter;
  endMonthFilter;
  endYearFilter;
  years = [];
  months = [];
  products = [];
  ordinateFormat = "totalFinalPrice";
  forecastDisplay = "segmentation";
  productTypeSelectedFilter = DefaultProductType;
  productTypeOptions = [];
  subscription = {};
  channelName = "/event/MonthlyPaymentAdded__e";
  objectApiName;
  textDirection = "ltr";

  customLabels = {
    startMonth_label,
    startYear_label,
    endMonth_label,
    endYear_label,
    product_label,
    productType_label,
    productSubType_label,
    applyFilter_btn,
    filtersCategory_Date,
    filtersCategory_Product,
    segmentationDisplay,
    currency_btnGrp,
    units_btnGrp
  };

  optionsOrdinate = [
    { label: currency_btnGrp, value: "totalFinalPrice" },
    { label: units_btnGrp, value: "monthlyUnits" }
  ];

  forecastDisplayOptions = [
    { label: segmentationDisplay, value: "segmentation" }
  ];

  @wire(getObjectInfo, { objectApiName: Product })
  ProductObject;

  @wire(getPicklistValues, {
    recordTypeId: "$ProductObject.data.defaultRecordTypeId",
    fieldApiName: ProductType
  })
  productTypeOptionsWire({ data }) {
    if (data) {
      this.productTypeOptions = [
        ...data.values,
        { label: "All Types", value: "All", validFor: [], attributes: null }
      ];
    }
  }

  @wire(getPicklistValues, {
    recordTypeId: "$ProductObject.data.defaultRecordTypeId",
    fieldApiName: Subtype
  })
  productSubTypes;

  @wire(getRecord, {
    recordId: "$recordId",
    layoutTypes: ["Full"],
    modes: ["View"]
  })
  wiredRecord({ data }) {
    if (data) {
      this.objectApiName = data.apiName;
    }
  }

  get productSubTypeOptions() {
    if (
      this.productSubTypes?.data &&
      this.productTypeSelectedFilter &&
      this.productTypeSelectedFilter !== "All"
    ) {
      return this.setDependentPicklist(
        this.productSubTypes.data,
        this.productTypeSelectedFilter
      );
    }
    return [];
  }

  setDependentPicklist(data, controllerValue) {
    const key = data.controllerValues[controllerValue];
    return data.values.filter((opt) => opt.validFor.includes(key));
  }

  connectedCallback() {
    this.textDirection =
      typeof document !== "undefined" && document.documentElement.dir === "rtl"
        ? "rtl"
        : "ltr";
    this.handleSubscribe();
    this.getData();
  }

  getData() {
    getMonthlyPayments({ oppId: null, contractId: null }).then((result) => {
      if (result) {
        this.monthlyPayments = this.transformData(result);
        this.filteredMonthlyPayments = this.monthlyPayments;
        this.generateComboboxOptions(this.monthlyPayments);
      }
    });
  }

  handleOrdinateChange(event) {
    this.ordinateFormat = event.target.value;
    this.dispatchEvent(
      new CustomEvent("ordinateformatchange", { detail: event.target.value })
    );
  }

  handleDisplayChange(event) {
    this.forecastDisplay = event.target.value;
    this.dispatchEvent(
      new CustomEvent("forecastdisplaychange", { detail: event.target.value })
    );
  }

  handleSubscribe() {
    subscribe(this.channelName, -1, () => this.getData()).then((response) => {
      this.subscription = response;
    });
    onError((error) => {
      console.error("Occurred an Error: ", JSON.stringify(error));
    });
  }

  disconnectedCallback() {
    unsubscribe(this.subscription, () => {});
  }

  handleFiltersChange(e) {
    const fieldName = e.target.name;
    const fieldValue = e.target.value;
    this[fieldName] =
      fieldValue === "All" ||
      fieldName === "productSelectedFilter" ||
      fieldName === "productSubTypeSelectedFilter" ||
      fieldName === "productTypeSelectedFilter"
        ? fieldValue
        : parseInt(fieldValue, 10);

    this.filters = { ...this.filters, [fieldName]: fieldValue };
    if (fieldName === "productTypeSelectedFilter") {
      delete this.filters.productSubTypeSelectedFilter;
      this.productSubTypeSelectedFilter = null;
    }
  }

  handleProductMultiChange(e) {
    this.productSelectedFilter = e.detail?.value || [];
    this.filters = {
      ...this.filters,
      productSelectedFilter: this.productSelectedFilter
    };
  }

  generateComboboxOptions(data) {
    const products = new Set();
    const months = new Set();
    const years = new Set();
    data.forEach((entry) => {
      months.add(entry.month);
      years.add(entry.year);
      entry.data.forEach((item) => {
        if (item.productName) {
          products.add(item.productName);
        }
      });
    });
    const toOptions = (set, allLabel) => {
      const options = Array.from(set)
        .filter((v) => v != null && v !== "")
        .map((value) => ({ label: String(value), value }));
      if (allLabel) {
        options.push({ label: allLabel, value: "All" });
      }
      return options;
    };
    this.products = toOptions(products, "All products");
    this.months = toOptions(months).sort((a, b) => a.value - b.value);
    this.years = toOptions(years);
  }

  transformData(data) {
    const groupedData = {};
    data.forEach((payment) => {
      const startdate = new Date(payment.Start_date__c);
      const month = startdate.getMonth() + 1;
      const year = startdate.getFullYear();
      const key = `${month}-${year}`;
      if (!groupedData[key]) {
        groupedData[key] = { month, year, data: [], total: 0 };
      }
      const listPrice = payment.Price__c || payment.price__c || 0;
      const discount = payment.Discount__c || 0;
      const finalPrice = listPrice - (listPrice * discount) / 100;
      groupedData[key].data.push({
        id: payment.Id,
        productName: payment.Products_Name__c,
        room: payment.Products_Name__c,
        listPrice,
        discount,
        finalPrice,
        productType: null,
        productSubType: null
      });
      groupedData[key].total += finalPrice;
    });
    return Object.values(groupedData);
  }

  resetFilters() {
    this.startYearFilter = null;
    this.startMonthFilter = null;
    this.endYearFilter = null;
    this.endMonthFilter = null;
    this.productSelectedFilter = null;
    this.productTypeSelectedFilter = DefaultProductType;
    this.productSubTypeSelectedFilter = null;
    this.filters = {};
    this.applyFilters();
  }

  applyFilters() {
    const selectedProducts = Array.isArray(this.productSelectedFilter)
      ? this.productSelectedFilter
      : this.productSelectedFilter
        ? [this.productSelectedFilter]
        : [];

    this.filteredMonthlyPayments = this.monthlyPayments
      .filter((entry) => {
        if (this.allNullForFilter()) {
          return true;
        }
        const roomDate = new Date(`${entry.year}-${entry.month}-01`);
        const startOk =
          this.startYearFilter == null ||
          roomDate >=
            new Date(
              `${this.startYearFilter}-${this.startMonthFilter || 1}-01`
            );
        const endOk =
          this.endYearFilter == null ||
          roomDate <=
            new Date(`${this.endYearFilter}-${this.endMonthFilter || 12}-01`);
        return startOk && endOk;
      })
      .map((item) => {
        const filtered = item.data.filter((dataItem) => {
          const productOk =
            selectedProducts.length === 0 ||
            selectedProducts.includes("All") ||
            selectedProducts.includes(dataItem.productName);
          return productOk;
        });
        if (!filtered.length) {
          return null;
        }
        return {
          ...item,
          data: filtered,
          total: filtered.reduce((acc, curr) => acc + curr.finalPrice, 0)
        };
      })
      .filter((item) => item !== null);

    this.generateComboboxOptions(
      this.allNullForFilter() && selectedProducts.length === 0
        ? this.monthlyPayments
        : this.filteredMonthlyPayments
    );

    this.dispatchEvent(
      new CustomEvent("submitfilters", { detail: this.filters })
    );
  }

  allNullForFilter() {
    return (
      this.startYearFilter == null &&
      this.startMonthFilter == null &&
      this.endYearFilter == null &&
      this.endMonthFilter == null
    );
  }

  displayToast(message, variant) {
    this.dispatchEvent(new ShowToastEvent({ message, variant }));
  }
}
