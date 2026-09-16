# Cloudial Date Input

A generic Lightning Web Component date field for Salesforce. It keeps its public
`value` in `YYYY-MM-DD` form while supporting locale-aware display, manual
typing, a native calendar picker, inclusive bounds, Flow, and RTL layouts.

The source namespace is `CloudialPackage`. The managed 2GP release remains
pending until that namespace is linked to the Cloudial Partner Business Org.

## Use in another LWC

```html
<c-cloudial-date-input
  label="Start date"
  name="startDate"
  value={startDate}
  min="2026-01-01"
  display-format="DD/MM/YYYY"
  required
  onchange={handleStartDateChange}
></c-cloudial-date-input>
```

```js
handleStartDateChange(event) {
  this.startDate = event.detail.value;
}
```

Invalid text stays visible with an inline message. No `change` or Flow
attribute event is emitted until the text is a valid, in-range date different
from the current value.

## Salesforce builders

The component is available on App, Home, Record, and Flow Screen pages. In a
Flow, `value` is an input/output property and is updated with
`FlowAttributeChangeEvent`.

See [API documentation](docs/API.md) and [more examples](docs/examples.md).
When source validation is complete, follow the
[managed 2GP setup and release guide](docs/MANAGED-PACKAGE-SETUP.md).

## Development

```sh
npm install
npm test
npm run test:coverage
npm run lint
npm run validate:identity
```

Only `force-app` is a Salesforce package directory. This repository does not
contain a released package version or install URL yet.