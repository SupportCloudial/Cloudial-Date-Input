# Examples

## Locale-aware required field

```html
<c-cloudial-date-input
  label="Due date"
  value={dueDate}
  required
  field-level-help="Enter or select the contractual due date."
  onchange={handleDueDateChange}
></c-cloudial-date-input>
```

## Fixed format and optional range

```html
<c-cloudial-date-input
  label="Reporting date"
  display-format="DD.MM.YYYY"
  min="2026-01-01"
  max="2026-12-31"
  message-when-range-underflow="Choose {0} or a later date."
  message-when-range-overflow="Choose {0} or an earlier date."
></c-cloudial-date-input>
```

## Imperative validation

```js
const dateInput = this.template.querySelector("c-cloudial-date-input");
dateInput.setCustomValidity(
  this.dateIsUnavailable ? "That date is unavailable." : ""
);
return dateInput.reportValidity();
```

## Flow Screen

Add **Cloudial Date Input** to a screen, bind `value` to a Text variable, and
optionally configure the bounds in `YYYY-MM-DD`. The bound variable receives
only canonical values. The same component can be nested in another LWC without
additional metadata.
