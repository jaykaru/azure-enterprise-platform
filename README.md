# Azure Enterprise Platform

![Terraform](https://img.shields.io/badge/Terraform-1.13.x-7B42BC?logo=terraform&logoColor=white)
![AzureRM](https://img.shields.io/badge/azurerm-4.x-0078D4?logo=microsoftazure&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/CI%2FCD-Azure%20DevOps-0078D7?logo=azuredevops&logoColor=white)
![Region](https://img.shields.io/badge/region-France%20Central-2E7D32)
![Status](https://img.shields.io/badge/status-work%20in%20progress-F9A825)

Infrastructure as Code (Terraform) for Azure, deployed by an Azure DevOps pipeline from a GitHub repository.

> [!NOTE]
> **Status:** work in progress. Today the platform creates one resource group (`francecentral`). It is a foundation to grow, not a finished landing zone. This README is updated as the project grows.

## 📑 Contents

1. [The big picture](#big-picture)
2. [Folder structure](#folder-structure)
3. [Beginner glossary](#glossary)
4. [The `bootstrap/` folder](#bootstrap)
5. [The state file (explained)](#state-file)
6. [The files in `terraform/`](#terraform-files)
7. [Variable files and secrets](#secrets)
8. [Day-to-day commands (laptop)](#commands)
9. [One-time setup before the first pipeline run](#setup)
10. [The pipeline](#pipeline)
11. [Troubleshooting](#troubleshooting)
12. [Roadmap](#roadmap)

---

<a id="big-picture"></a>

## 🧭 1. The big picture

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

> [!TIP]
> Key idea: **your laptop and the pipeline read and write the same state file in Azure Storage**, so they always agree on what exists.

---

<a id="folder-structure"></a>

## 📁 2. Folder structure

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

<a id="glossary"></a>

## 📖 3. Beginner glossary

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

<a id="bootstrap"></a>

## 🏗️ 4. The `bootstrap/` folder

**Purpose:** create the Azure Storage account that will hold the Terraform state for everything else.

It creates:
- Resource group `rg-aep-tfstate-frc-001`
- Storage account `staeptfstatefrc001` (private, TLS 1.2, GRS, versioning and 30-day soft delete)
- Blob container `tfstate`

**Why it is separate:** Terraform needs the storage to exist *before* it can store state there. Something has to build it first, outside the main code. Keeping it separate also means the main code can never accidentally destroy the place where its own state lives. All three resources have `prevent_destroy` for the same reason.

**How often does it change?** Almost never. You run it once. It only changes for a deliberate reason, e.g. changing replication or retention, adding network rules, or creating a state account for another environment or subscription.

**Its own state file is local.** The bootstrap cannot store its state in a storage account that does not exist yet, so its state lives in `bootstrap/terraform.tfstate` on your machine.

> [!WARNING]
> `bootstrap/terraform.tfstate` is excluded from Git because it can contain sensitive values such as storage keys. **Back it up** somewhere private (e.g. a private OneDrive folder or password manager). Never commit or share it.

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

<a id="state-file"></a>

## 💾 5. The state file (explained)

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

> [!CAUTION]
> Never edit a state file by hand, and never commit it to Git. It can contain secrets.

Remote state also gives **locking**, so two people (or a person and the pipeline) cannot apply at the same time.

---

<a id="terraform-files"></a>

## 🔧 6. The files in `terraform/`

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

Your laptop is Windows and the pipeline agent is Linux, so record hashes for both platforms. Otherwise the pipeline log says Terraform "has made some changes to the provider dependency selections":

```powershell
terraform providers lock -platform=windows_amd64 -platform=linux_amd64
```

Re-run it whenever you upgrade a provider.

---

<a id="secrets"></a>

## 🔐 7. Variable files and secrets

> [!CAUTION]
> **Never put secrets in any `.tfvars` file.** The files in `terraform/environments/` are committed to Git.

- `.gitignore` ignores `*.tfvars` by default as a safety net, and un-ignores only `terraform/environments/*.tfvars`, because the pipeline needs those files.
- Secrets belong in Azure Key Vault or in Azure DevOps secret variables (passed as `TF_VAR_<name>` environment variables), and the Terraform variable should be marked `sensitive = true`.
- Best of all: use **OIDC / workload identity federation** so the pipeline has no password to store or expire.
- Turn on **GitHub secret scanning and push protection** (repo Settings > Code security) as a final safety net.
- If a secret is ever committed, treat it as compromised and **rotate it**. Deleting it from Git is not enough because history keeps it.

---

<a id="commands"></a>

## 💻 8. Day-to-day commands (laptop)

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

> [!TIP]
> **PowerShell:** put arguments that contain a dot in quotes, e.g. `"-var-file=environments/dev.tfvars"` or `"-out=bootstrap.tfplan"`. Without quotes, Windows PowerShell can split the argument at the dot, and Terraform fails with `Too many command line arguments`.

`use_azuread_auth=true` means you sign in with your Azure identity rather than storage keys. Your identity needs the **Storage Blob Data Contributor** role on the state storage account (being Owner is not enough for blob data).

Switching environment? Change both the `key` (e.g. `prod.tfstate`) and the `-var-file`, and re-run `init -reconfigure`.

---

<a id="setup"></a>

## 🚀 9. One-time setup before the first pipeline run

Do these once, in order. Replace the `<...>` placeholders with your own values.

### 💾 Step 1: Create the state storage (`bootstrap/`)
See section 4. Check it with:

```powershell
az storage account show -n staeptfstatefrc001 -g rg-aep-tfstate-frc-001 -o table
```

### 🆔 Step 2: Create the Azure DevOps service connection
Azure DevOps > Project settings > Service connections > New service connection > **Azure Resource Manager**.

- Identity type: **App registration (automatic)**
- Credential: **Workload identity federation** (no secret, so nothing expires)
- Scope level: **Subscription**, then pick the subscription
- Service connection name: `sc-aep-dev` (the pipeline uses this exact name; the `serviceConnection` variable in the YAML must match)
- Leave "Grant access permission to all pipelines" **off** and authorize the pipeline on its first run instead

This creates an app registration (a service principal) named like `<org>-<project>-<subscription-id>`. The pipeline signs in as this identity.

> [!IMPORTANT]
> **Two IDs, don't mix them up.** The *Application (client) ID* is what the service connection signs in with. The *Object ID* is what role assignments use in the CLI (`--assignee-object-id`). The portal and `--assignee` accept the client ID.

### 🔑 Step 3: Give that identity the roles it needs
An identity can only do what its roles allow. The pipeline needs two, and they are different:

| Role | Scope | Why |
|---|---|---|
| **Contributor** | Subscription | Create and change Azure resources (the wizard in step 2 normally adds this for you) |
| **Storage Blob Data Contributor** | The state storage account | Read and write the state file. **Contributor does not include blob data access**, and neither does Owner |

Check what already exists before adding anything:

```powershell
az role assignment list --scope /subscriptions/<subscription-id> --include-inherited `
  --query "[?principalType=='ServicePrincipal'].{id:principalName,role:roleDefinitionName}" -o table
```

#### 🧑‍💼 How to add a role assignment in the Azure portal
The same steps work for any role (Contributor, Storage Blob Data Contributor, and so on). Only the **scope** (where you start) and the **role** change.

1. Open the **scope** you want to grant access on:
   - Contributor on the whole subscription: Portal > **Subscriptions** > select your subscription.
   - Blob access on the state storage only: Portal > **Storage accounts** > `staeptfstatefrc001`.
2. In the left menu, click **Access control (IAM)**.
3. Click **+ Add** > **Add role assignment**.
4. **Role** tab: search for the role (for example `Contributor` or `Storage Blob Data Contributor`), select it, then click **Next**.
   - Contributor is listed under *Privileged administrator roles*. Storage Blob Data Contributor is under *Job function roles*.
5. **Members** tab:
   - *Assign access to*: **User, group, or service principal**
   - Click **+ Select members**, search for the identity (the app registration created by the service connection, e.g. `jaykaru-Azure-Enterprise-Platform-...`, or your own user), select it, then **Select**.
6. Click **Review + assign** (twice).
7. Check it: on the same **Access control (IAM)** page open the **Role assignments** tab and look for the identity with the role. It can take a few minutes to start working.

If the identity does not show up in the search, search by its Application (client) ID instead of its name.

Or do the blob role with the **CLI**:

```powershell
$sa = az storage account show -n staeptfstatefrc001 -g rg-aep-tfstate-frc-001 --query id -o tsv
az role assignment create `
  --assignee <application-client-id> `
  --role "Storage Blob Data Contributor" `
  --scope $sa
```

Role changes can take a few minutes to start working.

Good to know:
- Assign the blob role on the **storage account**, not the whole subscription. A subscription-level assignment works but gives the identity blob access to every storage account.
- If you also run Terraform from your laptop with `use_azuread_auth=true`, give **your own user** the same blob role.
- In larger companies, role assignments are usually written as code (`azurerm_role_assignment`) or handled by a platform team. Doing it by hand is fine for learning.
- Contributor cannot create role assignments. If a later deployment must assign roles (for example AKS or Key Vault access), it needs a role such as *Role Based Access Control Administrator*, at the smallest scope possible.

### 🛡️ Step 4: Create the Azure DevOps environment and approval
An *environment* in Azure DevOps is a named target (here: dev). It is where you attach approvals, so a person has to click **Approve** before the Apply stage runs.

1. Azure DevOps > your project > **Pipelines** > **Environments**.
2. Click **New environment** (or **Create environment** the first time).
3. Name: `azure-platform-dev` (it must match `environment:` in the YAML). Description is optional. Resource: **None**. Click **Create**.
4. Open the new environment, click **...** (top right) > **Approvals and checks**.
5. Click **+** > **Approvals** > **Next**.
6. In **Approvers**, add yourself (and teammates later). Leave *Instructions to approvers* optional. You can untick "Allow approvers to approve their own runs" in a team setup, but keep it on while you are the only person.
7. Click **Create**.

The Apply stage targets this environment, so it pauses for approval after the plan is shown. You will get an email and a banner on the run.

If you skip this step the pipeline still works: Azure DevOps creates the environment on first use, but with no approval, and Apply would run straight after Plan.

### 🔗 Step 5: Connect GitHub and create the pipeline
1. Azure DevOps > **Pipelines** > **Pipelines** > **New pipeline** (or **Create pipeline**).
2. **Where is your code?** Click the **GitHub** row (YAML). Ignore *More options*, which lists GitHub Enterprise Cloud and Server.
3. The first time, Azure DevOps sends you to GitHub to authorize **Azure Pipelines**. Two ways it can connect:
   - **OAuth** (the "Authorize Azure Pipelines (OAuth)" page): asks for access to all your public and private repositories and admin on repository webhooks. Fine for a personal learning project, and you can revoke it later in GitHub > Settings > Applications.
   - **Azure Pipelines GitHub App**: tighter, because you choose **Only select repositories** and pick only this repo. Prefer it where you can.
4. **Select**: choose `jaykaru/azure-enterprise-platform`. Use the filter box if it is not visible.
5. **Configure**: choose **Existing Azure Pipelines YAML file**.
6. Branch `main`, path `/pipelines/azure-pipelines.yml`, click **Continue**.
7. **Review**: click **Run**. (You can rename the pipeline later from its **...** menu.)
8. If the run shows a yellow banner **"This pipeline needs permission to access a resource before this run can continue"**, click **View** > **Permit** > **Permit**. This authorizes the pipeline to use the service connection `sc-aep-dev` (and later the environment).

About agents: the pipeline runs on a Microsoft-hosted Ubuntu machine (`pool: vmImage: ubuntu-latest`) from the **Azure Pipelines** pool. You do not select an agent. A new VM is started for each job and deleted after. The **Default** pool is only for self-hosted agents. If your organization has no free hosted parallelism you will see "No hosted parallelism has been purchased or granted"; see the troubleshooting table.

### ✅ Step 6: Check the first run
- **Plan** stage: the log should say `Plan: 1 to add, 0 to change, 0 to destroy` (the resource group `rg-aep-dev-frc-001`). If it shows more, stop and investigate before approving.
- **Apply** stage: waits for your approval, then creates the resource group and writes `dev.tfstate` to the `tfstate` container.
- Check the portal for the resource group and the state file blob.

### 🗑️ Step 7: Clean up the old identity
When the pipeline works, remove the unused `terraform-sp` service principal's Contributor role (or delete the app). An identity you no longer use, with an expired secret, should not keep access to the subscription. Also remove the old `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET` and `ARM_TENANT_ID` environment variables from Windows if they are still set.

---

<a id="pipeline"></a>

## 🔄 10. The pipeline (`pipelines/azure-pipelines.yml`)

Flow:

```
push to main ──▶ Stage 1: PLAN ──▶ (approval) ──▶ Stage 2: APPLY
                 init, fmt, validate,               applies the exact plan
                 plan, publish plan                 that was reviewed
```

- Uses an **Azure DevOps service connection** (`sc-aep-dev`) with workload identity federation, so there is no secret to expire.
- The `environmentName` variable (`dev`) selects `environments/dev.tfvars` and the `dev.tfstate` state file.
- Terraform is installed at a pinned version (`terraformVersion`, currently 1.13.3) in both stages. It must satisfy `required_version` in `providers.tf`. Update both together.
- The Plan stage publishes the plan file. The Apply stage applies **that exact plan**, so what you approved is what runs.
- The Apply stage targets the Azure DevOps environment `azure-platform-dev`, where the approval check lives.
- The pipeline triggers on changes to `terraform/` and `pipelines/` on `main`.
- Complete section 9 before the first run.

---

<a id="troubleshooting"></a>

## 🐞 11. Troubleshooting

> [!TIP]
> Click a section below to expand it. Start with the quick debug steps at the bottom if you are not sure where to look.

<details>
<summary><strong>🔎 Common errors (laptop and general)</strong></summary>

| Error | Meaning | Fix |
|---|---|---|
| `AADSTS7000222 ... client secrets are expired` | Terraform is using a service principal whose secret has expired (often from `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` environment variables) | Clear those variables to use `az login`, or create a new secret, or move to OIDC. If they are stored in Windows (User scope), remove them permanently: `[Environment]::SetEnvironmentVariable("ARM_CLIENT_SECRET", $null, "User")` and do the same for `ARM_CLIENT_ID` and `ARM_TENANT_ID` |
| `Backend initialization required` | `init` has not been run, or backend settings changed | Run `terraform init` with the `-backend-config` values (add `-reconfigure` if they changed) |
| `storage account name already taken` | Names are globally unique | Pick a different `state_storage_account_name` |
| `403 ... AuthorizationPermissionMismatch` on state | Missing blob data role | Assign **Storage Blob Data Contributor** on the state storage account |
| `Too many command line arguments` (in PowerShell) | PowerShell split an argument like `-out=x.tfplan` at the dot | Quote it: `terraform plan "-out=x.tfplan"` |
| Plan wants to create things that already exist | State file missing or wrong key | Check the `key`; import the resources if the state was lost |
| Pipeline: service connection not found or "needs permission" | The name differs, or the pipeline is not authorized | Use the exact name `sc-aep-dev`, then click **Permit** on the run |
| Pipeline: `Environment azure-platform-dev not found` | Environment not created | Create it (section 9, step 4) |
| Pipeline: `required_version` error | Pinned Terraform version does not match `providers.tf` | Change `terraformVersion` in the pipeline or `required_version` in `providers.tf` so they agree |
| Role assignment seems missing in the CLI | Mixing the Object ID and Client ID, or it has not propagated yet | List by scope (section 9, step 3) and wait a few minutes |

</details>

<details>
<summary><strong>🛠️ Pipeline issues we hit while building this (12 real problems)</strong></summary>

These are the real problems met during the first deployment, in the order they happened. Use the **Where to look** column to find the evidence quickly.
| # | What you see | Why it happens | How to fix it | Where to look |
|---|---|---|---|---|
| 1 | `AADSTS7000222 ... client secrets are expired` when running Terraform on the laptop | `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` environment variables were set. The azurerm provider prefers them over `az login`, and the old `terraform-sp` secret had expired | Remove the three variables permanently (Windows stores them at *User* scope, so clearing one terminal is not enough). Then open a new terminal and use `az login` | PowerShell: `Get-ChildItem Env: \| Where-Object Name -like 'ARM_*'`. Portal: Entra ID > App registrations > the app > Certificates & secrets (shows *Expired*) |
| 2 | `Too many command line arguments` on `terraform plan -out=bootstrap.tfplan` | PowerShell split the argument at the dot | Quote it: `terraform plan "-out=bootstrap.tfplan"` | The terminal. Same quoting applies to `"-var-file=environments/dev.tfvars"` |
| 3 | Pipeline will not start: *"service connection sc-azure-enterprise-platform could not be found"* | The service connection name in the YAML (`serviceConnection` variable) did not match the real name `sc-aep-dev`. Note the identity name shown in Entra ID (`jaykaru-Azure-Enterprise-Platform-...`) is **not** the service connection name | Set `serviceConnection` in `pipelines/azure-pipelines.yml` to the exact name, commit and push | Azure DevOps > Project settings > Service connections (the name column). The error banner on the run |
| 4 | Yellow banner *"This pipeline needs permission to access a resource before this run can continue"* | New pipelines are not allowed to use a service connection (or environment) until someone permits it. This is a safeguard | Click **View** > **Permit** > **Permit**. To pre-authorize: Service connections > the connection > **...** > **Security** > add the pipeline | The run page. Service connection > Security / Pipeline permissions |
| 5 | Run sits at *Plan information* with the `plan` job showing a clock icon | Not stuck: Azure DevOps is waiting for a hosted agent to start (usually under 2 minutes) or the run was waiting on the permission in #4 | Click the **plan** job (not the stage summary) to see the real status. If it says *No hosted parallelism has been purchased or granted*, request the free grant (see #6) | Run > click the **plan** job. Project settings > Parallel jobs |
| 6 | *"No hosted parallelism has been purchased or granted"* | New Azure DevOps organizations get no free Microsoft-hosted agents by default | Request the grant at https://aka.ms/azpipelines-parallelism-request (about 2-3 business days), or use a self-hosted agent in the **Default** pool | Project settings > Parallel jobs (Microsoft-hosted should not be 0). Project settings > Agent pools > Azure Pipelines > Agents |
| 7 | Confusion about which agent to pick in *Agent pools* | The YAML already chooses one: `pool: vmImage: ubuntu-latest` uses the **Azure Pipelines** (Microsoft-hosted) pool. *Default* is for self-hosted agents and is empty | Nothing to do. Leave the pool as it is | Project settings > Agent pools |
| 8 | `Terraform has made some changes to the provider dependency selections recorded in the .terraform.lock.hcl file` in the log | The lock file was created on Windows but the pipeline agent is Linux, so Linux hashes were missing | Run `terraform providers lock -platform=windows_amd64 -platform=linux_amd64` in `terraform/`, commit and push `.terraform.lock.hcl` | The `terraform init` step in the run log |
| 9 | `az storage blob list --auth-mode login` fails with *You do not have the required permissions* | Your own user is Owner but has no **blob data** role. Owner and Contributor manage the account, not the data | Add **Storage Blob Data Contributor** for your user on the storage account (section 9, step 3). Or browse in the portal using the access key view | Storage account > Access control (IAM) > Role assignments |
| 10 | Role looks missing when listing by identity in the CLI, but the portal shows it | Object ID and Client (App) ID were mixed up, or the assignment had not propagated | List by scope instead: `az role assignment list --scope /subscriptions/<id> --include-inherited`. Use the Client ID with `--assignee` | Portal: Subscription > Access control (IAM) > Role assignments |
| 11 | Plan wants to change or create more than expected | Wrong `key` (state file) or wrong `-var-file` | Stop, do not approve. Check `environmentName` in the YAML and that `key` is `<env>.tfstate` | The Plan stage log, line `Plan: X to add, Y to change, Z to destroy` |
| 12 | `AuthorizationPermissionMismatch` (403) at `terraform init` in the pipeline | The pipeline identity lacks **Storage Blob Data Contributor** on the state storage account, or the role has not propagated | Add the role (section 9, step 3), wait a few minutes, re-run | The `terraform init` step in the log. Storage account > Access control (IAM) |

</details>

<details open>
<summary><strong>✅ A quick way to debug any pipeline failure</strong></summary>

1. Open the failed run and click the **failed job**, not the stage summary.
2. Expand the step with the red cross and read the **first** error line. Later errors are often side effects.
3. Match it to the table above. If it is new, add a row here so the next person finds it.
4. Re-run only after fixing the cause. A re-run does not change anything by itself.

</details>

---

<a id="roadmap"></a>

## 🎯 12. Roadmap

- [x] Project scaffold and a first resource group
- [x] Bootstrap for remote state storage (applied)
- [x] Environment-based variable files
- [x] Remote backend configured in `terraform/`
- [x] Azure DevOps service connection using workload identity federation
- [x] Contributor and Storage Blob Data Contributor roles for the pipeline identity
- [x] Azure DevOps environment `azure-platform-dev` with an approval
- [x] First pipeline run: deployed `rg-aep-dev-frc-001` (Plan and Apply succeeded)
- [ ] Remove the old `terraform-sp` access
- [ ] Narrow the blob role to the storage account scope
- [ ] Add a `prod` environment
- [ ] Networking, Key Vault, monitoring and policy
