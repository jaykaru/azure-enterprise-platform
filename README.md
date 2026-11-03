# Azure Enterprise Platform

Infrastructure as Code (Terraform) for Azure, deployed by an Azure DevOps pipeline from a GitHub repository.

> **Status:** work in progress. Today the platform creates one resource group (`francecentral`). It is a foundation to grow, not a finished landing zone. This README is updated as the project grows.

---

## 1. The big picture

```
 You (laptop)                    GitHub repo                 Azure DevOps pipeline
 ------------                    -----------                 ---------------------
 write code  ───── git push ───▶ stores code  ───trigger───▶ runs terraform plan/apply
      │                                                              │
      │ terraform (az login)                                         │ terraform (service connection, OIDC)
      ▼                                                              ▼
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                               AZURE                                        │
 │                                                                            │
 │  rg-aep-tfstate-frc-001  (created ONCE by bootstrap/)                      │
 │   └─ Storage account  staeptfstatefrc001                                   │
 │        └─ Blob container  tfstate                                          │
 │             ├─ dev.tfstate   ◀── shared "memory" for the dev environment   │
 │             └─ prod.tfstate  ◀── (later) memory for prod                   │
 │                                                                            │
 │  rg-aep-dev-frc-001      (created by terraform/ with environments/dev)     │
 │   └─ (future resources: network, AKS, Key Vault ...)                       │
 └────────────────────────────────────────────────────────────────────────────┘
```

Key idea: **your laptop and the pipeline read and write the same state file in Azure Storage**, so they always agree on what exists.

---

## 2. Folder structure

```
azure-enterprise-platform/
├── bootstrap/                 # Run ONCE. Creates the storage that holds Terraform state
│   └── main.tf
├── terraform/                 # The platform code (what we deploy)
│   ├── providers.tf           # Terraform version, backend, provider setup
│   ├── main.tf                # The resources
│   ├── variables.tf           # Inputs the code accepts
│   ├── outputs.tf             # Values printed after deployment
│   └── environments/
│       └── dev.tfvars         # Values for the dev environment (add prod.tfvars later)
├── pipelines/
│   └── azure-pipelines.yml    # Azure DevOps pipeline
├── .gitignore                 # Keeps state, plans and local files out of Git
└── README.md
```

---

## 3. Beginner glossary

| Term | Simple meaning |
|---|---|
| **Terraform** | A tool that creates Azure resources from code files. |
| **Provider** | A plugin that lets Terraform talk to a platform (here: Azure, called `azurerm`). |
| **Resource** | One thing Terraform manages, e.g. a resource group. |
| **State file** | Terraform's memory: a record of what it created. |
| **Backend** | *Where* the state file is stored (local disk, or Azure Storage). |
| **Variable** | An input to the code, so values are not hardcoded. |
| **tfvars file** | A file that supplies values for the variables. |
| **Environment** | A separate copy of the platform, e.g. dev or prod. |

---

## 4. The `bootstrap/` folder

**Purpose:** create the Azure Storage account that will hold the Terraform state for everything else.

It creates:
- Resource group `rg-aep-tfstate-frc-001`
- Storage account `staeptfstatefrc001` (private, TLS 1.2, GRS, versioning and 30-day soft delete)
- Blob container `tfstate`

**Why it is separate:** Terraform needs the storage to exist *before* it can store state there. Something has to build it first, outside the main code. Keeping it separate also means the main code can never accidentally destroy the place where its own state lives. All three resources have `prevent_destroy` for the same reason.

**How often does it change?** Almost never. You run it once. It only changes for a deliberate reason, e.g. changing replication or retention, adding network rules, or creating a state account for another environment or subscription.

**Its own state file is local.** The bootstrap cannot store its state in a storage account that does not exist yet, so its state lives in `bootstrap/terraform.tfstate` on your machine.

- It is excluded from Git (it can contain sensitive values such as storage keys).
- **Back it up** somewhere private (e.g. a private OneDrive folder or password manager). Never commit or share it.
- It is only updated when you run Terraform *inside* `bootstrap/`. Deploying `terraform/` never touches it.
- If you lose it, nothing in Azure breaks. Terraform just forgets it built those three resources, so a new `plan` would try to create them again and Azure would refuse ("already exists"). To fix this, run `terraform import` once per resource.
- Optional later step: after the storage exists, move this state into it with `terraform init -migrate-state`.

Run it (one time):

```powershell
# Use your own az login. Clear any old service principal variables first.
Remove-Item Env:ARM_CLIENT_ID, Env:ARM_CLIENT_SECRET, Env:ARM_TENANT_ID -ErrorAction SilentlyContinue

cd bootstrap
terraform init
terraform plan      # should show 3 resources to create
terraform apply
```

The storage account name must be globally unique. If Azure says it is taken, change `state_storage_account_name` in `bootstrap/main.tf` and use the same name everywhere below.

---

## 5. The state file (explained)

Terraform records what it created in a **state file**. On every `plan` or `apply` it compares:

1. your **code** (what you want),
2. the **state** (what Terraform believes exists),
3. **Azure** (what really exists),

then changes only the difference.

| State file | Tracks | Stored | Updated when |
|---|---|---|---|
| `bootstrap/terraform.tfstate` | The 3 state-storage resources | Local, your machine | Only when you run Terraform in `bootstrap/` |
| `dev.tfstate` | The dev platform | Azure Storage (container `tfstate`) | Every `apply` in `terraform/` for dev, automatically |
| `prod.tfstate` (later) | The prod platform | Azure Storage | Every `apply` for prod |

Each state file only knows about its own folder and environment. One state per environment means a mistake in dev cannot damage prod.

Rules:
- Never edit a state file by hand.
- Never commit it to Git. It can contain secrets.
- Remote state also gives **locking**, so two people (or a person and the pipeline) cannot apply at the same time.

---

## 6. The files in `terraform/`

### `providers.tf`: how Terraform is set up

It has three parts:

```hcl
terraform {                          # 1. Settings for Terraform itself
  required_version = "~> 1.13.0"     #    Only allow Terraform 1.13.x

  backend "azurerm" {}               # 2. WHERE the state is stored (Azure Storage)

  required_providers {               # 3. WHICH provider plugins to download
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.2, < 5.0"
    }
  }
}

provider "azurerm" {                 # HOW to connect to Azure
  features {}
}
```

- **`terraform {}` block:** rules for Terraform itself: version, backend and which providers are needed. Pinning versions makes sure the laptop and the pipeline behave the same.
- **`backend "azurerm" {}` block:** says "store state in Azure Storage". It is **empty on purpose**: Terraform does not allow variables here, so the real values are passed at `terraform init` with `-backend-config`. That lets one code base serve dev and prod, and both the laptop and the pipeline.
- **`provider "azurerm" {}` block:** configures the Azure plugin. `features {}` is required by the provider, even when empty. Login details are *not* written here. Terraform uses your `az login` on a laptop, and the service connection in the pipeline.

### `variables.tf`: the inputs

Declares the values the code accepts: `resource_group_name`, `location`, `environment`, `tags`. This avoids hardcoding and makes the code reusable.

### `main.tf`: the resources

What we actually build. Currently one resource group, `azurerm_resource_group.main`. New resources (network, Key Vault, AKS...) get added here, or in modules later.

### `outputs.tf`: the results

Values printed after `apply` (resource group ID, name, location). Outputs are also how modules and other tools can read values.

### `environments/dev.tfvars`: the values

Supplies the variable values for dev:

```hcl
resource_group_name = "rg-aep-dev-frc-001"
location            = "francecentral"
environment         = "dev"
```

To add prod, create `prod.tfvars` with prod values. The code does not change.

You must pass the file explicitly: `-var-file=environments/dev.tfvars`. Terraform auto-loads only a file named `terraform.tfvars`, so we deliberately avoid that name to prevent the wrong environment being applied silently.

### `.terraform.lock.hcl`: provider version lock (generated)

Created by `terraform init`. It pins the exact provider version. **Commit it** so everyone, including the pipeline, uses the same one.

---

## 7. Variable files and secrets

- `.gitignore` ignores `*.tfvars` by default as a safety net, and un-ignores only `terraform/environments/*.tfvars`, because the pipeline needs those files.
- **Never put secrets in any `.tfvars` file.** Those files are committed to Git.
- Secrets belong in Azure Key Vault or in Azure DevOps secret variables (passed as `TF_VAR_<name>` environment variables), and the Terraform variable should be marked `sensitive = true`.
- Best of all: use **OIDC / workload identity federation** so the pipeline has no password to store or expire.
- Turn on **GitHub secret scanning and push protection** (repo Settings > Code security) as a final safety net.
- If a secret is ever committed, treat it as compromised and **rotate it**. Deleting it from Git is not enough because history keeps it.

---

## 8. Day-to-day commands (laptop)

First time, after `bootstrap/` is applied:

```powershell
cd terraform

terraform init `
  -backend-config="resource_group_name=rg-aep-tfstate-frc-001" `
  -backend-config="storage_account_name=staeptfstatefrc001" `
  -backend-config="container_name=tfstate" `
  -backend-config="key=dev.tfstate" `
  -backend-config="use_azuread_auth=true"
```

Then, every time:

```powershell
terraform fmt -check
terraform validate
terraform plan  "-var-file=environments/dev.tfvars"
terraform apply "-var-file=environments/dev.tfvars"
```

> **PowerShell tip:** put arguments that contain a dot in quotes, e.g. `"-var-file=environments/dev.tfvars"` or `"-out=bootstrap.tfplan"`. Without quotes, Windows PowerShell can split the argument at the dot, and Terraform fails with `Too many command line arguments`.

`use_azuread_auth=true` means you sign in with your Azure identity rather than storage keys. Your identity needs the **Storage Blob Data Contributor** role on the state storage account (being Owner is not enough for blob data).

Switching environment? Change both the `key` (e.g. `prod.tfstate`) and the `-var-file`, and re-run `init -reconfigure`.

---

## 9. The pipeline (`pipelines/azure-pipelines.yml`)

Flow:

```
push to main ──▶ Stage 1: PLAN ──▶ (approval) ──▶ Stage 2: APPLY
                 init, fmt, validate,               applies the exact plan
                 plan, publish plan                 that was reviewed
```

- Uses an **Azure DevOps service connection** to log in to Azure (planned: workload identity federation, no secret).
- The `environmentName` variable (`dev`) selects `environments/dev.tfvars` and the `dev.tfstate` state file.
- The Apply stage targets the Azure DevOps environment `azure-platform-dev`, where you can add an approval check.
- The service connection's identity needs **Contributor** on the subscription and **Storage Blob Data Contributor** on the state storage account.
- Do not run the pipeline until `bootstrap/` has been applied and the service connection exists.

---

## 10. Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| `AADSTS7000222 ... client secrets are expired` | Terraform is using a service principal whose secret has expired (often from `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` environment variables) | Clear those variables to use `az login`, or create a new secret, or move to OIDC |
| `Backend initialization required` | `init` has not been run, or backend settings changed | Run `terraform init` with the `-backend-config` values (add `-reconfigure` if they changed) |
| `storage account name already taken` | Names are globally unique | Pick a different `state_storage_account_name` |
| `403 ... AuthorizationPermissionMismatch` on state | Missing blob data role | Assign **Storage Blob Data Contributor** on the state storage account |
| `Too many command line arguments` (in PowerShell) | PowerShell split an argument like `-out=x.tfplan` at the dot | Quote it: `terraform plan "-out=x.tfplan"` |
| Plan wants to create things that already exist | State file missing or wrong key | Check the `key`; import the resources if the state was lost |

---

## 11. Roadmap

- [x] Project scaffold and a first resource group
- [x] Bootstrap for remote state storage
- [x] Environment-based variable files
- [ ] Apply `bootstrap/` and move `terraform/` to the remote backend
- [ ] Azure DevOps service connection using workload identity federation
- [ ] First pipeline run: deploy `rg-aep-dev-frc-001`
- [ ] Approval gate and a `prod` environment
- [ ] Networking, Key Vault, monitoring and policy
