# Cloudial Date Input API

## Value contract

`value`, `min`, `max`, event output, and Flow output use `YYYY-MM-DD`. No time
or timezone is part of the contract. Invalid external values are treated as
empty. `min` and `max` are optional and inclusive.

## Public properties

- `value` (`String`): canonical date or empty.
- `displayFormat` (`String`): `locale` (default), `DD.MM.YYYY`,
  `DD/MM/YYYY`, `MM/DD/YYYY`, or `YYYY-MM-DD`.
- `locale` (`String`): optional BCP 47 locale such as `en-GB`; empty uses
  the Salesforce user locale. It controls locale display and permits localized
  digits during manual entry for every display format. Dates remain Gregorian.
- `min`, `max` (`String`): optional canonical bounds.
- `label` (`String`): field label; defaults to `Date`.
- `name`, `placeholder` (`String`): text-input attributes.
- `fieldLevelHelp` (`String`): help text shown beside a visible label.
- `required`, `disabled`, `readOnly` (`Boolean`): field state.
- `variant` (`String`): `standard` or `label-hidden`.
- `direction` (`String`): optional `ltr` or `rtl`; empty inherits direction.
- `messageWhenValueMissing`, `messageWhenBadInput`,
  `messageWhenRangeUnderflow`, `messageWhenRangeOverflow` (`String`):
  overrides for validation messages. Range messages may contain `{0}`, which
  is replaced with the formatted bound.

English defaults are Salesforce Custom Labels and can be translated.

## Public methods

- `checkValidity()` returns whether the current text satisfies all constraints.
- `validate()` returns Flow's `{ isValid, errorMessage? }` validation result
  without rendering an error.
- `reportValidity()` returns validity and displays an inline error when invalid.
- `setCustomValidity(message)` sets or clears a custom validation error.
- `focus()` moves focus to the manual text input.

Disabled and read-only instances do not accept changes and are excluded from
validation.

## Events

`change` bubbles and crosses the shadow boundary. Its detail is exactly:

```js
{ value: "2026-09-16" }
```

It is emitted only for a valid value different from the current value. A Flow
`FlowAttributeChangeEvent` for `value` is emitted at the same commit point.

## Exposure

The component is exposed directly only as a Flow Screen component. It is not
listed for App, Home, or Record pages. Other LWCs can use it as a nested
component through the public contract above.

After installing the managed package, a subscriber LWC references the package
namespace exactly as registered:

```html
<cloudialPackage-cloudial-date-input
  label="Start date"
  value={startDate}
  display-format="DD/MM/YYYY"
  onchange={handleDateChange}
></cloudialPackage-cloudial-date-input>
```

Cross-namespace LWC composition requires Lightning Web Security in the
subscriber org.

## Styling hooks

- `--cloudial-date-input-width`
- `--cloudial-date-input-background`
- `--cloudial-date-input-border-color`
- `--cloudial-date-input-border-radius`
- `--cloudial-date-input-text-color`
- `--cloudial-date-input-error-color`
- `--cloudial-date-input-icon-color`
- `--cloudial-date-input-inline-padding`

Every hook has a standalone default. Layout uses logical inline properties for
inherited or explicit RTL direction.
