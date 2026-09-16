jest.mock("@salesforce/i18n/locale", () => ({ default: "en-US" }), {
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

const flushPromises = () => Promise.resolve();

function createDateInput(properties = {}) {
  const element = createElement("c-cloudial-date-input", {
    is: CloudialDateInput
  });
  Object.assign(element, properties);
  document.body.appendChild(element);
  return element;
}

function typeAndBlur(element, value) {
  const input = element.shadowRoot.querySelector('[data-id="display-input"]');
  input.value = value;
  input.dispatchEvent(new InputEvent("input"));
  input.dispatchEvent(new FocusEvent("blur"));
  return input;
}

describe("c-cloudial-date-input", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it.each([
    ["DD.MM.YYYY", "16.09.2026"],
    ["DD/MM/YYYY", "16/09/2026"],
    ["MM/DD/YYYY", "09/16/2026"],
    ["YYYY-MM-DD", "2026-09-16"],
    ["locale", "09/16/2026"]
  ])("displays %s without changing the ISO value", async (format, display) => {
    const element = createDateInput({ value: "2026-09-16", displayFormat: format });
    await flushPromises();
    expect(element.value).toBe("2026-09-16");
    expect(
      element.shadowRoot.querySelector('[data-id="display-input"]').value
    ).toBe(display);
  });

  it("allows the developer to override the Salesforce user locale", async () => {
    const element = createDateInput({
      value: "2026-09-16",
      displayFormat: "locale",
      locale: "en-GB"
    });
    await flushPromises();

    expect(
      element.shadowRoot.querySelector('[data-id="display-input"]').value
    ).toBe("16/09/2026");
  });

  it("falls back to the Salesforce user locale for an invalid locale override", async () => {
    const element = createDateInput({
      value: "2026-09-16",
      displayFormat: "locale",
      locale: "not_a_locale"
    });
    await flushPromises();

    expect(
      element.shadowRoot.querySelector('[data-id="display-input"]').value
    ).toBe("09/16/2026");
  });

  it.each([
    ["DD.MM.YYYY", "7.9.2026"],
    ["DD/MM/YYYY", "7/9/2026"],
    ["MM/DD/YYYY", "9/7/2026"],
    ["YYYY-MM-DD", "2026-9-7"],
    ["locale", "9/7/2026"]
  ])("parses typed %s values to ISO", async (format, typedValue) => {
    const element = createDateInput({ displayFormat: format });
    const changeHandler = jest.fn();
    const flowHandler = jest.fn();
    element.addEventListener("change", changeHandler);
    element.addEventListener("flowattributechange", flowHandler);
    await flushPromises();

    typeAndBlur(element, typedValue);
    await flushPromises();

    expect(element.value).toBe("2026-09-07");
    expect(changeHandler).toHaveBeenCalledTimes(1);
    expect(changeHandler.mock.calls[0][0].detail).toEqual({ value: "2026-09-07" });
    expect(flowHandler.mock.calls[0][0].detail).toEqual({
      attributeName: "value",
      newValue: "2026-09-07"
    });
  });

  it("retains invalid and out-of-range drafts without emitting change", async () => {
    const element = createDateInput({
      value: "2026-09-16",
      min: "2026-09-01",
      max: "2026-09-30",
      displayFormat: "DD/MM/YYYY"
    });
    const changeHandler = jest.fn();
    element.addEventListener("change", changeHandler);
    await flushPromises();

    let input = typeAndBlur(element, "31/02/2026");
    await flushPromises();
    expect(input.value).toBe("31/02/2026");
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Enter a valid date.");

    input = typeAndBlur(element, "01/10/2026");
    await flushPromises();
    expect(input.value).toBe("01/10/2026");
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Date must be on or before 30/09/2026.");
    expect(input.getAttribute("aria-invalid")).toBe("true");
    expect(element.value).toBe("2026-09-16");
    expect(changeHandler).not.toHaveBeenCalled();
  });

  it("supports inclusive bounds and customized validation messages", async () => {
    const element = createDateInput({
      min: "2026-09-01",
      max: "2026-09-30",
      displayFormat: "YYYY-MM-DD",
      messageWhenRangeUnderflow: "Choose {0} or later.",
      messageWhenRangeOverflow: "Choose {0} or earlier."
    });
    await flushPromises();

    typeAndBlur(element, "2026-08-31");
    await flushPromises();
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Choose 2026-09-01 or later.");

    typeAndBlur(element, "2026-10-01");
    await flushPromises();
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Choose 2026-09-30 or earlier.");

    typeAndBlur(element, "2026-09-01");
    await flushPromises();
    expect(element.value).toBe("2026-09-01");
    typeAndBlur(element, "2026-09-30");
    await flushPromises();
    expect(element.value).toBe("2026-09-30");
  });

  it("implements required and custom validity methods", async () => {
    const element = createDateInput({
      required: true,
      messageWhenValueMissing: "A date is required."
    });
    await flushPromises();

    expect(element.checkValidity()).toBe(false);
    expect(
      element.shadowRoot
        .querySelector('[data-id="display-input"]')
        .hasAttribute("aria-describedby")
    ).toBe(false);
    expect(element.reportValidity()).toBe(false);
    await flushPromises();
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("A date is required.");
    expect(
      element.shadowRoot
        .querySelector('[data-id="display-input"]')
        .getAttribute("aria-describedby")
    ).toBe(
      element.shadowRoot.querySelector('[data-id="error-message"]').getAttribute("id")
    );

    element.setCustomValidity("Server rejected this date.");
    expect(element.reportValidity()).toBe(false);
    await flushPromises();
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Server rejected this date.");
    element.setCustomValidity("");
    typeAndBlur(element, "09/16/2026");
    await flushPromises();
    expect(element.checkValidity()).toBe(true);
  });

  it("returns Flow-compatible validation without rendering the error", async () => {
    const element = createDateInput({
      required: true,
      messageWhenValueMissing: "A date is required."
    });
    await flushPromises();

    expect(element.validate()).toEqual({
      isValid: false,
      errorMessage: "A date is required."
    });
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]')
    ).toBeNull();

    typeAndBlur(element, "09/16/2026");
    await flushPromises();
    expect(element.validate()).toEqual({ isValid: true });
  });

  it("keeps Flow external errors separate from internal validation", async () => {
    const element = createDateInput();
    await flushPromises();

    element.setCustomValidity("Flow rejected this date.");
    expect(element.validate()).toEqual({ isValid: true });
    expect(element.checkValidity()).toBe(false);
    expect(element.reportValidity()).toBe(false);
  });

  it("does not emit when a valid typed value is unchanged", async () => {
    const element = createDateInput({
      value: "2026-09-16",
      displayFormat: "MM/DD/YYYY"
    });
    const handler = jest.fn();
    element.addEventListener("change", handler);
    await flushPromises();
    typeAndBlur(element, "09/16/2026");
    expect(handler).not.toHaveBeenCalled();
  });

  it("commits on Enter and allows an optional value to be cleared", async () => {
    const element = createDateInput({ value: "2026-09-16" });
    const handler = jest.fn();
    element.addEventListener("change", handler);
    await flushPromises();

    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    input.value = "09/17/2026";
    input.dispatchEvent(new InputEvent("input"));
    const enterEvent = new KeyboardEvent("keydown", {
      key: "Enter",
      cancelable: true
    });
    input.dispatchEvent(enterEvent);
    await flushPromises();
    expect(enterEvent.defaultPrevented).toBe(true);
    expect(element.value).toBe("2026-09-17");

    typeAndBlur(element, "");
    await flushPromises();
    expect(element.value).toBe("");
    expect(handler).toHaveBeenCalledTimes(2);
    expect(handler.mock.calls[1][0].detail).toEqual({ value: "" });
  });

  it("rejects a typed year that is not four digits", async () => {
    const element = createDateInput({ displayFormat: "MM/DD/YYYY" });
    await flushPromises();

    const input = typeAndBlur(element, "09/16/26");
    await flushPromises();
    expect(element.value).toBe("");
    expect(input.value).toBe("09/16/26");
    expect(
      element.shadowRoot.querySelector('[data-id="error-message"]').textContent
    ).toBe("Enter a valid date.");
  });

  it("accepts native picker values and opens the native picker", async () => {
    const element = createDateInput({
      min: "2026-09-01",
      max: "2026-09-30",
      displayFormat: "MM/DD/YYYY"
    });
    const changeHandler = jest.fn();
    element.addEventListener("change", changeHandler);
    await flushPromises();

    const picker = element.shadowRoot.querySelector('[data-id="native-picker"]');
    picker.showPicker = jest.fn();
    expect(picker.min).toBe("2026-09-01");
    expect(picker.max).toBe("2026-09-30");
    expect(picker.required).toBe(false);
    element.shadowRoot
      .querySelector(".cloudial-date-input__picker-button")
      .click();
    expect(picker.showPicker).toHaveBeenCalledTimes(1);

    picker.value = "2026-09-18";
    picker.dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    expect(element.value).toBe("2026-09-18");
    expect(input.value).toBe("09/18/2026");
    expect(changeHandler.mock.calls[0][0].detail.value).toBe("2026-09-18");
  });

  it("falls back to clicking the native picker when showPicker throws", async () => {
    const element = createDateInput();
    await flushPromises();
    const picker = element.shadowRoot.querySelector('[data-id="native-picker"]');
    picker.showPicker = jest.fn(() => {
      throw new Error("showPicker unavailable");
    });
    picker.click = jest.fn();

    expect(() =>
      element.shadowRoot
        .querySelector(".cloudial-date-input__picker-button")
        .click()
    ).not.toThrow();
    expect(picker.click).toHaveBeenCalledTimes(1);
  });

  it("reflects label, help, placeholder, name, variant, and direction", async () => {
    const element = createDateInput({
      label: "Start date",
      name: "startDate",
      placeholder: "MM/DD/YYYY",
      fieldLevelHelp: "Use the contract start date.",
      direction: "rtl"
    });
    await flushPromises();

    const root = element.shadowRoot.querySelector(".slds-form-element");
    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    expect(root.getAttribute("dir")).toBe("rtl");
    expect(element.shadowRoot.querySelector("label").textContent).toContain(
      "Start date"
    );
    expect(element.shadowRoot.querySelector("lightning-helptext").content).toBe(
      "Use the contract start date."
    );
    expect(input.name).toBe("startDate");
    expect(input.placeholder).toBe("MM/DD/YYYY");

    element.variant = "label-hidden";
    element.direction = "";
    await flushPromises();
    expect(
      element.shadowRoot.querySelector("label").classList
    ).toContain("slds-assistive-text");
    expect(element.shadowRoot.querySelector("lightning-helptext")).toBeNull();
    expect(
      element.shadowRoot.querySelector(".slds-form-element").hasAttribute("dir")
    ).toBe(false);
  });

  it.each(["disabled", "readOnly"])(
    "prevents editing and calendar use when %s",
    async (property) => {
      const element = createDateInput({ value: "2026-09-16", [property]: true });
      const handler = jest.fn();
      element.addEventListener("change", handler);
      await flushPromises();

      const input = element.shadowRoot.querySelector('[data-id="display-input"]');
      const picker = element.shadowRoot.querySelector('[data-id="native-picker"]');
      picker.showPicker = jest.fn();
      typeAndBlur(element, "09/17/2026");
      element.shadowRoot
        .querySelector(".cloudial-date-input__picker-button")
        .click();

      expect(element.value).toBe("2026-09-16");
      expect(handler).not.toHaveBeenCalled();
      expect(picker.disabled).toBe(true);
      expect(picker.showPicker).not.toHaveBeenCalled();
      expect(element.checkValidity()).toBe(true);
      expect(input[property === "disabled" ? "disabled" : "readOnly"]).toBe(true);
    }
  );

  it("exposes focus and rejects non-ISO public values", async () => {
    const element = createDateInput({ value: "09/16/2026" });
    await flushPromises();
    const input = element.shadowRoot.querySelector('[data-id="display-input"]');
    const focusSpy = jest.spyOn(input, "focus");
    element.focus();
    expect(focusSpy).toHaveBeenCalledTimes(1);
    expect(element.value).toBe("");
  });
});
