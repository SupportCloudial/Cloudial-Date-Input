# Cloudial Date Input

A generic Lightning Web Component date field for Salesforce. It keeps its public
`value` in `YYYY-MM-DD` form while supporting locale-aware display, manual
typing, a native calendar picker, inclusive bounds, Flow, and RTL layouts.

The source namespace is `CloudialPackage`, now linked to the Cloudial Partner
Business Org's Dev Hub. Creating and validating the first managed 2GP version
is the next release step.

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

## Salesforce Flow

The component is available in Flow Screen Builder. It is intentionally not
exposed directly on App, Home, or Record pages. Other LWCs can compose it
through its public API. In a Flow, `value` is an input/output property and is
updated with `FlowAttributeChangeEvent`.

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