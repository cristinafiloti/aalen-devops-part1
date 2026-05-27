# Project Work Part I – Scripted Infrastructure-as-Code Definition

**Cloud:** Microsoft Azure
**IaC Tool:** Terraform (HashiCorp)
**Course:** Hochschule Aalen
**Hand-In Date:** 3rd of June, 2026

---

## Repository Content

```
.
├── README.md                       # this file
├── docs/
│   └── Description.docx            # written deliverable (Approach, Connections, Auth)
└── terraform/
    ├── providers.tf                # provider + backend configuration
    ├── variables.tf                # input variables
    ├── main.tf                     # resource definitions
    ├── outputs.tf                  # exported values
    ├── terraform.tfvars.example    # sample values (rename to .tfvars)
    └── .gitignore                  # ignores state, .tfvars, .terraform/
```

## Prerequisites

- Terraform >= 1.6
- Azure CLI (`az login` performed)
- An Azure subscription with permission to create resources
- A globally unique prefix for naming (storage accounts must be unique worldwide)

## How to Run

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars and set your own prefix and location

terraform init
terraform plan -out plan.tfplan
terraform apply plan.tfplan
```

## How to Destroy

```bash
terraform destroy
```

## Architecture Overview

The infrastructure provisions an Azure landing zone for a future image-storing web
application. The App Service is created in Part I as the future hosting target;
application code follows in Part II.

```
┌─────────────────────────────────────────────────────────────┐
│                    Resource Group                            │
│                                                              │
│   ┌──────────────┐    Managed     ┌────────────────────┐    │
│   │  App Service │───Identity────►│     Key Vault      │    │
│   │   (Linux,    │                │  (RBAC enabled)    │    │
│   │   Python)    │                └────────────────────┘    │
│   │              │                                           │
│   │              │                ┌────────────────────┐    │
│   │              │───Identity────►│  Storage Account   │    │
│   │              │                │  (Blob container)  │    │
│   └──────────────┘                └────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

See `docs/Description.docx` for the full written description.
