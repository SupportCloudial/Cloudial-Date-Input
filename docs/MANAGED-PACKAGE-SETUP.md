# Managed 2GP setup and release

The source can be developed and deployed before packaging. Perform these steps
only when a Cloudial Partner Business Org administrator is available.

## Permanent ownership

Use the Cloudial Partner Business Org (PBO) as the permanent Dev Hub and owner
of the managed second-generation package. Scratch orgs are disposable test
environments; they do not own the package. Do not create the released package
under a personal Developer Edition Dev Hub.

## One-time administrator setup

1. In the PBO, enable **Dev Hub** and **Second-Generation Managed Packaging**.
2. Give the package developer permission to create package versions and promote
   versions.
3. Register a permanent namespace in a separate namespace Developer Edition
   org. Choose carefully: a registered namespace cannot be changed or reused.
4. Link that namespace to the PBO from **Namespace Registries**.
5. Authorize the PBO locally:

   ```powershell
   sf org login web --alias CloudialPBO --set-default-dev-hub
   ```

6. Verify access before continuing:

   ```powershell
   sf package list --target-dev-hub CloudialPBO
   ```

Stop if package or namespace objects are unavailable; an administrator must fix
the PBO settings or user permissions.

## Configure and create the package

1. Put the linked namespace in `sfdx-project.json`.
2. Create the managed package:

   ```powershell
   sf package create --name "Cloudial Date Input" --package-type Managed --path force-app --target-dev-hub CloudialPBO
   ```

3. Keep the returned package alias/`0Ho` ID in `sfdx-project.json`.

## Beta validation

Create the version without an installation key:

```powershell
sf package version create --package "Cloudial Date Input" --installation-key-bypass --code-coverage --wait 30 --target-dev-hub CloudialPBO
```

Beta versions can be installed only in scratch orgs and sandboxes. Create a
disposable scratch org and install the returned `04t` version:

```powershell
sf org create scratch --definition-file config/project-scratch-def.json --alias CloudialDateInputBeta --duration-days 7 --target-dev-hub CloudialPBO
sf package install --package 04tVERSION --target-org CloudialDateInputBeta --wait 30 --publish-wait 30 --no-prompt
```

Run the full UI/API test matrix against the installed beta. A beta installation
cannot be upgraded, so do not use a long-lived UAT org for this check.

## Release 1.0

Promotion is irreversible. Promote only the exact tested beta:

```powershell
sf package version promote --package 04tVERSION --target-dev-hub CloudialPBO --no-prompt
```

Install the released version in `DevEditionPersonal`, verify it, then update
`package.identity.json`:

- `packageType`: `managed`
- `status`: `released`
- `version`: `1.0.0`
- `installUrl`: installation URL containing the released `04t` ID

The identity file is then ready to be collected into the shared agent package
index.

## Official references

- [Know Your Orgs for Managed 2GP](https://developer.salesforce.com/docs/atlas.en-us.pkg2_dev.meta/pkg2_dev/sfdx_dev_dev2gp_before_know_orgs.htm)
- [Link a Namespace to a Dev Hub](https://developer.salesforce.com/docs/atlas.en-us.pkg2_dev.meta/pkg2_dev/sfdx_dev_reg_namespace.htm)
- [Release a Managed 2GP Version](https://developer.salesforce.com/docs/atlas.en-us.pkg2_dev.meta/pkg2_dev/sfdx_dev_dev2gp_create_pkg_ver_promote.htm)
- [Install with a URL](https://developer.salesforce.com/docs/atlas.en-us.pkg2_dev.meta/pkg2_dev/sfdx_dev_dev2gp_install_pkg_ui.htm)
