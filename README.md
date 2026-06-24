# Project Work Part II – Runnable Cloud Application

**Cloud:** Microsoft Azure
**Language:** Python 3.12 / FastAPI
**IaC:** Terraform (azurerm provider)
**CI/CD:** Azure DevOps Pipelines (YAML provided; local deployment also supported)
**Course:** Hochschule Aalen
**Hand-In Date:** 1st of July, 2026

The application stores user-uploaded images (and other small files) in an
Azure Blob Storage container, reads its sensitive configuration from Azure
Key Vault, and authenticates against both using a system-assigned managed
identity. No connection strings or account keys are ever read by the running
process.

This Part II builds on the infrastructure that was provisioned in Part I —
the Resource Group, Storage Account, Key Vault, App Service Plan and Linux
Web App are all reused. Terraform recognises them by name and only adds
what is new (the application startup command, a second Key Vault secret,
and additional app settings).

---

## Repository Layout

```
.
├── README.md
├── requirements.txt
├── azure-pipelines.yml            # Azure DevOps build & deploy pipeline
├── app/                           # FastAPI application
│   ├── __init__.py
│   ├── main.py                    # routes + Azure clients
│   ├── templates/
│   │   ├── list.html              # Web Page 1
│   │   └── upload.html            # Web Page 2
│   └── static/style.css
├── terraform/                     # Same as Part I, with FastAPI startup
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── .gitignore
├── scripts/
│   ├── deploy.sh                  # Manual zip-deploy script (bash / Git Bash)
│   └── deploy.ps1                 # Manual zip-deploy script (Windows PowerShell)
└── docs/
    └── Description.docx           # Written deliverable
```

## Web Pages

| Path        | Purpose                                                                                                  |
|-------------|----------------------------------------------------------------------------------------------------------|
| `/`         | **Web Page 1** – lists every blob in the `images` container, with size, modification date and a Download button. Includes a link to `/upload`. |
| `/upload`   | **Web Page 2** – HTML form (`<input type="file">`) to upload a new image or file.                       |
| `/download/{name}` | Generates a 15-minute user-delegation SAS URL for the requested blob and redirects the browser to it. |
| `/healthz`  | JSON liveness probe used by the pipeline and deploy script.                                              |
| `/docs`     | Auto-generated OpenAPI documentation (FastAPI).                                                          |

---

## Quick Start (Windows PowerShell)

The fastest path from a fresh clone to a running deployment, reusing the
Part I infrastructure:

```powershell
# 0. Clone the repo (if not already done) and switch to the part2 branch
cd C:\cristina\erasmus\devops
git clone https://github.com/cristinafiloti/aalen-devops-part1.git part2_repo
cd part2_repo
git checkout part2

# 1. Log in to Azure (device code flow because MFA is enforced)
az login --use-device-code
az account set --subscription "Azure for Students"

# 2. Apply Terraform on top of the existing Part I resources
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
# (the example file already contains the right values for the Part I deployment)

terraform init
terraform plan -out plan.tfplan
terraform apply plan.tfplan

# 3. Deploy the application
cd ..
.\scripts\deploy.ps1
```

When the deploy script finishes successfully it prints the public URL:
`https://cristinaer-app-suv4.azurewebsites.net` — open it in a browser to
see Web Page 1.

> **Note**: the first `terraform plan` after Part I will report
> a small number of changes — typically the new `AppSecret`, the gunicorn
> startup command on the Web App, and additional app settings. The existing
> resources are matched by name and updated in place.

---

## Local Development (against the deployed Azure resources)

If you want to run the FastAPI app on your laptop while still hitting the
real Key Vault and Storage Account:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Tell the local process where the Azure resources live
$env:KEY_VAULT_NAME       = "cristinaer-kv-suv4"
$env:STORAGE_ACCOUNT_NAME = "cristinaerstsuv4"
$env:IMAGES_CONTAINER_NAME = "images"

# Optional: grant yourself blob access for the local run
$userId = az ad signed-in-user show --query id -o tsv
$saId   = az storage account show -g cristinaer-rg -n cristinaerstsuv4 --query id -o tsv
az role assignment create --assignee $userId --role "Storage Blob Data Contributor" --scope $saId

uvicorn app.main:app --reload
```

Open <http://127.0.0.1:8000>.

---

## Build & Deploy Pipeline (Azure DevOps)

`azure-pipelines.yml` is the deliverable required by the assignment ("Build/
Deployment Pipeline YAML"). It runs in two stages:

1. **Build** — installs Python dependencies on a Microsoft-hosted Ubuntu
   agent, smoke-tests the imports, and produces an `app.zip` artifact.
2. **Deploy** — downloads the artifact, calls `AzureWebApp@1` to publish
   it to the Linux App Service, then polls `/healthz` for up to two
   minutes to confirm the deployment came up healthy.

### How to wire it up in Azure DevOps

If you have access to **dev.azure.com**:

1. **Create an Azure DevOps organisation and project.** Go to
   <https://dev.azure.com>, sign in with the same `cristinafiloti@outlook.com`
   account used for Azure, and create a new organisation (free for up to
   5 users). Create a new project called `aalen-devops-part2` with Git as
   the version control.

2. **Connect to GitHub.** In the project, go to
   *Pipelines → Create Pipeline → GitHub*, authorise Azure Pipelines to read
   your GitHub account, and select the `aalen-devops-part1` repository.
   Choose the `part2` branch and the existing YAML file
   (`azure-pipelines.yml`).

3. **Create a Service Connection to Azure.** Go to
   *Project Settings → Service connections → New → Azure Resource Manager*.
   Use the *Workload identity federation (automatic)* recommended flow.
   Name it exactly `azure-subscription` (this is the name the YAML expects).
   Scope it to the *Azure for Students* subscription.

4. **Create a Variable Group.** Go to *Pipelines → Library → + Variable group*.
   Name it `partII-vars`. Add two variables:
   - `APP_SERVICE_NAME = cristinaer-app-suv4`
   - `RESOURCE_GROUP_NAME = cristinaer-rg`
   Save. Link this variable group from the pipeline (Edit pipeline → Variables → Variable groups → Link).

5. **Run the pipeline.** Push a commit to `part2`, or click *Run pipeline*
   manually. The Build stage takes about a minute; the Deploy stage takes
   another two minutes including the smoke-test.

### If you don't want to use Azure DevOps

Just keep `azure-pipelines.yml` in the repository as the deliverable (it
documents the same build-and-deploy steps that `deploy.ps1` performs
locally) and use `.\scripts\deploy.ps1` for the actual deployment.
The professor will still see the YAML file as the required artifact.

---

## How the Authentication Works (Brief)

- The App Service has a **system-assigned managed identity**, created
  automatically by Terraform.
- The only RBAC roles granted to that identity are:
  - `Key Vault Secrets User` on the vault — read secrets only
  - `Storage Blob Data Contributor` on the storage account — read & write blobs
- The application uses `DefaultAzureCredential` from the Azure SDK to fetch
  tokens. Inside the App Service that hits the IMDS endpoint and gets a
  managed-identity token. On a developer laptop the same code falls
  through to the Azure CLI's cached token, so the app works locally too.
- Downloads use **user-delegation SAS** URLs valid for 15 minutes. The
  application mints the SAS on demand; revoking the role assignment
  immediately kills the ability to mint new ones.
- File uploads enforce a size cap (`MAX_UPLOAD_MB`, default 10 MB) and a
  whitelist of file extensions.

See `docs/Description.docx` for the full discussion of approach,
connections between resources, and the identity context.

---

## Clean Up

```powershell
cd terraform
terraform destroy
```

This removes everything — Resource Group, Storage Account (and the
uploaded blobs), Key Vault (purged because purge protection is off in the
lab profile), App Service Plan, and Linux Web App.
