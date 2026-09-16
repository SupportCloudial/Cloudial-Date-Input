jest.mock("@salesforce/i18n/locale", () => ({ default: "ar-EG" }), {
  virtual: true
});
jest.mock(
  "@salesforce/label/c.CloudialDateInput_BadInput",
  () => ({ default: "Enter a valid date." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_Label",
  () => ({ default: "Date" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_OpenCalendar",
  () => ({ default: "Open calendar" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_Required",
  () => ({ default: "required" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_RangeOverflow",
  () => ({ default: "Date must be on or before {0}." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_RangeUnderflow",
  () => ({ default: "Date must be on or after {0}." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.CloudialDateInput_ValueMissing",
  () => ({ default: "Complete this field." }),
  { virtual: true }
);
jest.mock(
  "lightning/flowSupport",
  () => ({
    FlowAttributeChangeEvent: class FlowAttributeChangeEvent extends CustomEvent {
      constructor(attributeName, newValue) {
        super("flowattributechange", {
          detail: { attributeName, newValue }
        });
      }
    }
  }),
  { virtual: true }
);

import { createElement } from "lwc";
import CloudialDateInput from "c/cloudialDateInput";

describe("c-cloudial-date-input RTL locale", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("formats and parses localized Arabic digits without changing ISO output", async () => {
    const element = createElement("c-cloudial-date-input", {
      is: CloudialDateInput
    });
    element.value = "2026-09-16";
    element.direction = "rtl";
    document.body.appendChild(element);
    await Promise.resolve();

    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    expect(input.value).toContain("٢٠٢٦");
    expect(
      element.shadowRoot.querySelector(".slds-form-element").getAttribute("dir")
    ).toBe("rtl");

    input.value = "١٧‏/٩‏/٢٠٢٦";
    input.dispatchEvent(new InputEvent("input"));
    input.dispatchEvent(new FocusEvent("blur"));
    await Promise.resolve();

    expect(element.value).toBe("2026-09-17");
  });

  it("accepts localized digits with an explicit display format", async () => {
    const element = createElement("c-cloudial-date-input", {
      is: CloudialDateInput
    });
    element.displayFormat = "DD/MM/YYYY";
    document.body.appendChild(element);
    await Promise.resolve();

    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    input.value = "١٧/٩/٢٠٢٦";
    input.dispatchEvent(new InputEvent("input"));
    input.dispatchEvent(new FocusEvent("blur"));
    await Promise.resolve();

    expect(element.value).toBe("2026-09-17");
  });

  it("keeps the ISO Gregorian calendar for locales with another default", async () => {
    const element = createElement("c-cloudial-date-input", {
      is: CloudialDateInput
    });
    element.value = "2026-09-16";
    element.locale = "ar-SA";
    document.body.appendChild(element);
    await Promise.resolve();

    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    expect(input.value).toContain("٢٠٢٦");
  });
});
