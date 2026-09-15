# Cloudial-Packages

Inventory repo of reusable Salesforce packages. Start here when you need a commercial capability kit for a new org or product.

**Do not edit `rooms-devops` from this workstream.** That folder (if open in the same Cursor workspace) is read-only reference only.

## Package

| id | name | path | status |
| --- | --- | --- | --- |
| `commercial-package` | Commercial Package | `force-app` | partial |

Metadata inventory for MDAPI-style deploy/retrieve is in [`package.xml`](package.xml) (generated from `force-app`). Package directory config lives in [`sfdx-project.json`](sfdx-project.json).

## Commercial Package

One Salesforce package covering:

- Package Builder on **Opportunity** and **Contract** (same UI/process intent as rooms-devops)
- **Monthly Payments** (`MonthlyPayment__c` + services + LWC grid)
- **Order** as technical version under Contract (draft / activate / archive) — no Order Package Builder UI target
- **Iterations** + history + auto-renew
- **Recurring Price Increase**
- Modify Contract (Account action) + Terminate Contract
- Access Type policy: Monthly / Periodic / Rent / Usage Based (no location/desk/occupancy)

### Build notes

- LWC adapted from rooms-devops (occupancy columns off; desk KPIs removed; site/location filters stripped from Add Products and Monthly Payment Filters).
- Labels: `cp_*` prefix for commercial package (former `rooms_*`); desk wording softened to units.
- RTL: logical CSS properties + SLDS horizontal margins; host inherits document `dir`.
- Apex ported then stripped of Location / desk / occupancy paths; further thinning can continue module-by-module.
- Large rooms-devops Apex tests that require `Location__c` / `Locations__c` remain in `.forceignore`. Use `CommercialPackageSmoke_Test`, `CommercialPackageCoverage_Test`, `PackageBuilderAccessTypePolicy_Test`, `PackageBuilderAccessPolicy_Test`, and `TriggerHandler_Test`.

### Out of scope

Quote Package Builder UI, Forecast, Braze, Lead/web intake, legacy Renewal Price Adjustment, Rooms extras (room swap, barter, temporary other-site, extra-credit), vendored `ers_*` / `fsc_*`.

### Source

Behavior and UI parity are derived from **rooms-devops** (read-only). Familiar API names kept (`Iteration__c`, `MonthlyPayment__c`, etc.).

## Delivery slices (parity checklist)

Mark when verified in a target org (manual; no seed data in-repo):

1. [ ] Opp Package Builder + Monthly Payments — open PB on Opportunity; add/edit lines; MP grid
2. [ ] Contract Package Builder — PB on Contract against underlying Order lines
3. [ ] Draft Order + activate / Sign + archive
4. [ ] Iterations — Working / Proposed / approve / discard
5. [ ] Auto-renew batch / schedulable / Contract action
6. [ ] Recurring Price Increase modal onto MP
7. [ ] Modify-contract + terminate actions

## Setup

```bash
# From this repo root
sf org create scratch -f config/project-scratch-def.json -a cloudial-packages -d
# Deploy (source format)
sf project deploy start --source-dir force-app --target-org cloudial-packages
# Or deploy via package.xml
sf project deploy start --manifest package.xml --target-org cloudial-packages
```

No demo/seed data: create Account, Opportunity, Products, and Access Types manually after deploy.

## Agent tooling

`.agents/skills` and `.cursor/rules` are part of this repo. Never modify rooms-devops.
