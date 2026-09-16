# Managed-package integration harness

This directory is outside the `force-app` package directory and is not included
in package versions. It proves that a no-namespace subscriber LWC can compile
against the installed managed component.

Prerequisites:

- Lightning Web Security is enabled in the target org.
- A `Cloudial Date Input` managed package version is installed.

Deploy the harness with:

```powershell
sf project deploy start --source-dir test-support/main/default/lwc/cloudialDateInputConsumer --target-org TARGET_ORG
```
