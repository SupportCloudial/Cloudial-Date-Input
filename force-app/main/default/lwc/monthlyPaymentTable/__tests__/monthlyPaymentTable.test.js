import { createElement } from "lwc";
import MonthlyPaymentTable from "c/monthlyPaymentTable";
import getMonthlyPayments from "@salesforce/apex/PackageBuilderService.getMonthlyPayments";
import updateDiscount from "@salesforce/apex/PackageBuilderService.updateDiscountWithEnteredPercentages";
import applyBulkAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.applyBulkAdjustment";
import applyIndividualAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.applyIndividualAdjustment";
import previewIndividualAdjustment from "@salesforce/apex/MonthlyPaymentAdjustmentService.previewIndividualAdjustment";
import bulkAddWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_BulkAddWarning";
import recurringAddWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_RecurringAddWarning";
import recurringReplaceWarning from "@salesforce/label/c.MonthlyPayment_Adjustment_RecurringReplaceWarning";

jest.mock(
  "@salesforce/apex/PackageBuilderService.getMonthlyPayments",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/PackageBuilderService.ensureMonthlyPaymentsForLineItems",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/PackageBuilderService.updateDiscountWithEnteredPercentages",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/MonthlyPaymentAdjustmentService.previewIndividualAdjustment",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/MonthlyPaymentAdjustmentService.applyIndividualAdjustment",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/MonthlyPaymentAdjustmentService.applyBulkAdjustment",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "c/packageBuilderRecurringPriceIncreaseModal",
  () => ({ default: { open: jest.fn() } }),
  { virtual: true }
);

const LINE_ID = "00k000000000001AAA";
const PAYMENT_ID = "a00000000000001AAA";
const PAYMENT_ID_2 = "a00000000000002AAA";

const flushPromises = async () => {
  await Promise.resolve();
  await Promise.resolve();
};

function payment(
  discount = 5,
  {
    id = PAYMENT_ID,
    startDate = "2099-01-01",
    endDate = "2099-01-31",
    recurringEnabled = false
  } = {}
) {
  return {
    Id: id,
    LastModifiedDate: "2098-12-01T00:00:00.000Z",
    Start_date__c: startDate,
    End_date__c: endDate,
    Price__c: 1000,
    FinalPrice__c: 1000 * (1 + discount / 100),
    Final_Adjusted_Price__c: 1000 * (1 + discount / 100),
    Discount__c: discount,
    Products_Name__c: "Suite A",
    Monthly_Units__c: 1,
    OpportunityLineItem__c: LINE_ID,
    OpportunityLineItem__r: {
      Quantity: 1,
      ServiceDate: "2099-01-01",
      End_date__c: "2099-01-31",
      Access_Type__c: "Periodic",
      Recurring_Price_Increase_Enabled__c: recurringEnabled,
      Recurring_Increase_Start_Date__c: recurringEnabled ? "2099-01-01" : null
    },
    Opportunity__r: { Start_Date__c: "2099-01-01" }
  };
}

function preview(
  action = "Replace",
  recurringPricingActive = false,
  inputType = "Percentage"
) {
  const amount = inputType === "Amount";
  return {
    paymentId: PAYMENT_ID,
    inputType,
    inputValue: amount ? 100 : 10,
    action,
    recurringPricingActive,
    currentStateExpectation: {
      discount: 5,
      finalPrice: 1050,
      lastModifiedDate: "2098-12-01T00:00:00.000Z"
    },
    calculatedOutcome: {
      originalPrice: 1000,
      existingAdjustment: amount ? 50 : 5,
      priceBefore: 1050,
      resultingAdjustment: amount
        ? action === "Add"
          ? 150
          : 100
        : action === "Add"
          ? 15.5
          : 10,
      finalPriceAfter: amount
        ? action === "Add"
          ? 1150
          : 1100
        : action === "Add"
          ? 1155
          : 1100
    }
  };
}

async function render(
  discount = 5,
  {
    readOnly = false,
    paymentData = null,
    paymentList = null,
    accessType = "Periodic"
  } = {}
) {
  getMonthlyPayments.mockResolvedValue(
    paymentList || [paymentData || payment(discount)]
  );
  previewIndividualAdjustment.mockResolvedValue(preview());
  applyIndividualAdjustment.mockResolvedValue(preview());
  applyBulkAdjustment.mockResolvedValue([]);
  updateDiscount.mockResolvedValue(true);
  const element = createElement("c-monthly-payment-table", {
    is: MonthlyPaymentTable
  });
  element.recordId = "006000000000001AAA";
  element.objectApiName = "Opportunity";
  element.readOnly = readOnly;
  element.selectedLineItemMeta = [{ id: LINE_ID, accessType }];
  element.selectedLineItemIds = [LINE_ID];
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

async function editPercentage(element, value = "10") {
  const input = element.shadowRoot.querySelector('input[name="discount"]');
  input.value = value;
  input.dispatchEvent(new CustomEvent("change"));
  await flushPromises();
}

function clickButton(element, label) {
  const button = [
    ...element.shadowRoot.querySelectorAll("lightning-button")
  ].find((candidate) => candidate.label === label);
  button.click();
}

function clickPreviewButton(element, variant) {
  const buttons = [
    ...element.shadowRoot.querySelectorAll(
      ".slds-modal__footer lightning-button"
    )
  ];
  const button = buttons.find((candidate) => candidate.variant === variant);
  button.click();
}

async function applyBulkPercent(element, value = "10") {
  const allYear = element.shadowRoot.querySelector("lightning-combobox");
  allYear.value = "All";
  allYear.dispatchEvent(new CustomEvent("change"));
  const percentButton = element.shadowRoot.querySelector(
    'button[data-name="discountFormat"][data-value="Percentage"]'
  );
  percentButton.click();
  await flushPromises();
  const adjustment = element.shadowRoot.querySelector(
    "lightning-input.mp-year-adjustment-input"
  );
  adjustment.value = value;
  adjustment.dispatchEvent(new CustomEvent("change"));
  clickButton(element, "Apply to selected");
  await flushPromises();
}

async function applySingleAmount(element, value = "100") {
  const allYear = element.shadowRoot.querySelector("lightning-combobox");
  allYear.value = "All";
  allYear.dispatchEvent(new CustomEvent("change"));
  const amountButton = element.shadowRoot.querySelector(
    'button[data-name="discountFormat"][data-value="Amount"]'
  );
  amountButton.click();
  await flushPromises();
  const adjustment = element.shadowRoot.querySelector(
    "lightning-input.mp-year-adjustment-input"
  );
  adjustment.value = value;
  adjustment.dispatchEvent(new CustomEvent("change"));
  clickButton(element, "Apply to selected");
  await flushPromises();
}

describe("individual percentage Replace/Add", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("opens server preview only for an editable row with an existing adjustment", async () => {
    const element = await render(5);
    await editPercentage(element);
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).toHaveBeenCalledWith({
      request: expect.objectContaining({
        paymentId: PAYMENT_ID,
        inputType: "Percentage",
        inputValue: 10,
        action: "Replace"
      })
    });
    expect(updateDiscount).not.toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector('[data-id="adjustment-preview"]')
    ).not.toBeNull();
  });

  it("keeps first-time Set on the direct save flow", async () => {
    const element = await render(0);
    await editPercentage(element);
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(updateDiscount).toHaveBeenCalledWith({
      payments: [
        expect.objectContaining({
          Id: PAYMENT_ID,
          Discount__c: 10
        })
      ],
      enteredPercentageByPaymentId: { [PAYMENT_ID]: 10 }
    });
  });

  it("defaults Replace, recalculates Add, and shows recurring warning", async () => {
    const element = await render(5);
    previewIndividualAdjustment
      .mockResolvedValueOnce(preview("Replace"))
      .mockResolvedValueOnce(preview("Add", true));
    await editPercentage(element);
    clickButton(element, "Save");
    await flushPromises();

    const actions = element.shadowRoot.querySelector("lightning-radio-group");
    expect(actions.value).toBe("Replace");
    expect(element.shadowRoot.textContent).not.toContain(recurringAddWarning);
    actions.dispatchEvent(
      new CustomEvent("change", { detail: { value: "Add" } })
    );
    await flushPromises();

    expect(previewIndividualAdjustment).toHaveBeenLastCalledWith({
      request: expect.objectContaining({ action: "Add" })
    });
    expect(element.shadowRoot.textContent).toContain("1155");
    expect(element.shadowRoot.textContent).toContain(recurringAddWarning);
  });

  it("suppresses Replace/Add on read-only rows", async () => {
    const element = await render(5, { readOnly: true });
    const input = element.shadowRoot.querySelector('input[name="discount"]');
    input.value = "10";
    input.dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(
      [...element.shadowRoot.querySelectorAll("lightning-button")].find(
        (candidate) => candidate.label === "Save"
      )
    ).toBeUndefined();
  });

  it("keeps direct Final edits outside Replace/Add", async () => {
    const element = await render(5);
    const input = element.shadowRoot.querySelector('input[name="finalPrice"]');
    input.value = "1125";
    input.dispatchEvent(new CustomEvent("change"));
    await flushPromises();
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(updateDiscount).toHaveBeenCalledWith({
      payments: [
        expect.objectContaining({
          Id: PAYMENT_ID,
          Final_Adjusted_Price__c: 1125
        })
      ],
      enteredPercentageByPaymentId: {}
    });
  });

  it("cancel and Escape close preview without applying", async () => {
    const element = await render(5);
    await editPercentage(element);
    clickButton(element, "Save");
    await flushPromises();
    clickPreviewButton(element, "neutral");
    await flushPromises();
    expect(applyIndividualAdjustment).not.toHaveBeenCalled();

    clickButton(element, "Save");
    await flushPromises();
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    await flushPromises();
    expect(applyIndividualAdjustment).not.toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector('[data-id="adjustment-preview"]')
    ).toBeNull();
  });

  it("applies only after explicit confirmation with preview expectation", async () => {
    const element = await render(5);
    await editPercentage(element);
    clickButton(element, "Save");
    await flushPromises();
    clickPreviewButton(element, "brand");
    await flushPromises();

    expect(applyIndividualAdjustment).toHaveBeenCalledWith({
      request: expect.objectContaining({
        action: "Replace",
        currentStateExpectation: preview().currentStateExpectation
      })
    });
  });
});

describe("individual amount and Final parity", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("opens an amount Replace preview for one adjusted cell", async () => {
    const element = await render(5);
    previewIndividualAdjustment.mockResolvedValue(
      preview("Replace", false, "Amount")
    );
    await applySingleAmount(element);
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).toHaveBeenCalledWith({
      request: expect.objectContaining({
        paymentId: PAYMENT_ID,
        inputType: "Amount",
        inputValue: 100,
        action: "Replace"
      })
    });
    expect(element.shadowRoot.textContent).toContain("100");
    expect(element.shadowRoot.textContent).not.toContain("100%");
  });

  it("saves a first amount as Set without opening a preview", async () => {
    const element = await render(0);
    applyIndividualAdjustment.mockResolvedValue(
      preview("Set", false, "Amount")
    );
    await applySingleAmount(element);
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(applyIndividualAdjustment).toHaveBeenCalledWith({
      request: expect.objectContaining({
        inputType: "Amount",
        inputValue: 100,
        action: "Set"
      })
    });
    expect(updateDiscount).not.toHaveBeenCalled();
  });

  it("styles every displayed negative Final red", async () => {
    const element = await render(-120);
    const finalInput = element.shadowRoot.querySelector(
      'input[name="finalPrice"]'
    );
    expect(finalInput.classList).toContain("final-price-negative");
  });

  it("keeps Usage Based Final-only editing and negative validation unchanged", async () => {
    const usage = payment(0);
    usage.Access_Type__c = "Usage Based";
    usage.OpportunityLineItem__r.Access_Type__c = "Usage Based";
    usage.ListPrice__c = 25;
    const element = await render(0, {
      paymentData: usage,
      accessType: "Usage Based"
    });

    expect(
      element.shadowRoot.querySelector('input[name="discount"]')
    ).toBeNull();
    const finalInput = element.shadowRoot.querySelector(
      'input[name="finalPrice"]'
    );
    finalInput.value = "-5";
    finalInput.dispatchEvent(new CustomEvent("change"));
    await flushPromises();
    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(updateDiscount).not.toHaveBeenCalled();
    expect(
      [...element.shadowRoot.querySelectorAll("lightning-button")].find(
        (candidate) => candidate.label === "Save"
      )
    ).toBeUndefined();
  });
});

describe("bulk Replace/Add", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows inline Replace/Add and Add warning without a preview modal", async () => {
    const element = await render(5, {
      paymentList: [
        payment(5),
        payment(0, {
          id: PAYMENT_ID_2,
          startDate: "2099-02-01",
          endDate: "2099-02-28"
        })
      ]
    });
    await applyBulkPercent(element);
    const bulkActions = [
      ...element.shadowRoot.querySelectorAll("lightning-radio-group")
    ].find((group) => group.name === "bulkAdjustmentAction");
    expect(bulkActions).not.toBeUndefined();
    expect(bulkActions.value).toBe("Replace");
    expect(element.shadowRoot.textContent).not.toContain(bulkAddWarning);
    bulkActions.dispatchEvent(
      new CustomEvent("change", { detail: { value: "Add" } })
    );
    await flushPromises();
    expect(element.shadowRoot.textContent).toContain(bulkAddWarning);
    expect(
      element.shadowRoot.querySelector('[data-id="adjustment-preview"]')
    ).toBeNull();
    expect(element.shadowRoot.textContent).not.toContain(
      "Will update: 1 products"
    );
  });

  it("shows recurring Replace and Add warnings for affected bulk scope", async () => {
    const element = await render(5, {
      paymentList: [payment(5, { recurringEnabled: true })]
    });
    await applyBulkPercent(element);
    expect(element.shadowRoot.textContent).toContain(recurringReplaceWarning);
    const bulkActions = [
      ...element.shadowRoot.querySelectorAll("lightning-radio-group")
    ].find((group) => group.name === "bulkAdjustmentAction");
    bulkActions.dispatchEvent(
      new CustomEvent("change", { detail: { value: "Add" } })
    );
    await flushPromises();
    expect(element.shadowRoot.textContent).toContain(recurringAddWarning);
  });

  it("saves mixed bulk percentage edits through applyBulkAdjustment", async () => {
    const element = await render(5, {
      paymentList: [
        payment(5),
        payment(0, {
          id: PAYMENT_ID_2,
          startDate: "2099-02-01",
          endDate: "2099-02-28"
        })
      ]
    });
    await applyBulkPercent(element);
    clickButton(element, "Save");
    await flushPromises();

    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(applyBulkAdjustment).toHaveBeenCalledWith({
      bulkRequest: expect.objectContaining({
        inputType: "Percentage",
        inputValue: 10,
        action: "Replace",
        items: expect.arrayContaining([
          expect.objectContaining({ paymentId: PAYMENT_ID }),
          expect.objectContaining({ paymentId: PAYMENT_ID_2 })
        ])
      })
    });
    expect(updateDiscount).not.toHaveBeenCalled();
  });
  it("blocks different multi-cell percentage edits on adjusted months", async () => {
    const element = await render(5, {
      paymentList: [
        payment(5),
        payment(5, {
          id: PAYMENT_ID_2,
          startDate: "2099-02-01",
          endDate: "2099-02-28"
        })
      ]
    });
    const inputs = [
      ...element.shadowRoot.querySelectorAll('input[name="discount"]')
    ];
    expect(inputs.length).toBeGreaterThanOrEqual(2);
    inputs[0].value = "10";
    inputs[0].dispatchEvent(new CustomEvent("change"));
    await flushPromises();
    inputs[1].value = "20";
    inputs[1].dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);
    clickButton(element, "Save");
    await flushPromises();

    expect(applyBulkAdjustment).not.toHaveBeenCalled();
    expect(previewIndividualAdjustment).not.toHaveBeenCalled();
    expect(updateDiscount).not.toHaveBeenCalled();
    expect(toastHandler).toHaveBeenCalled();
  });
});
