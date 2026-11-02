# Azure Enterprise Platform

A minimal Terraform starter for Azure. The initial configuration creates one
resource group; it is a foundation to extend, not a complete enterprise landing
zone.

## Prerequisites

- Terraform 1.5 or later
- Azure CLI, signed in to the intended subscription with `az login`
- The AzureRM provider authenticates using the Azure CLI credentials

Select the subscription before running Terraform if needed:

```powershell
az account set --subscription "<subscription-id-or-name>"
```

## Configure and validate

Update the non-secret example values in `terraform/terraform.tfvars`, or create
an ignored `terraform.local.tfvars` file for local overrides. Do not put
credentials or other secrets in either file.

From the `terraform` directory:

```powershell
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Review the plan before applying it:

```powershell
terraform apply
```

The outputs include the resource group's name, location, and ID. `terraform
destroy` removes the resource group and any resources later added inside it;
review the plan carefully before confirming a destroy.

## State and production use

Terraform state can contain sensitive data. This starter uses local state;
configure a secured remote backend with access controls, encryption, and
appropriate state locking before collaborating or using it for production.
State files and backups are excluded from Git.

The `pipelines` directory is reserved for CI/CD definitions. Add pipeline
credentials through your CI system's secure service connections or secret
store, never in Terraform files or committed variable files.
