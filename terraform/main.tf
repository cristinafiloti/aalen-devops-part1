###############################################################################
# main.tf
# Resource definitions for Project Work Part I.
#
# Resources created:
#   1. Resource Group              – logical container for everything below
#   2. Storage Account + Container – holds the image blobs (Part II uploads here)
#   3. Key Vault                   – holds the storage connection string secret
#   4. Key Vault Secret            – the secret itself (storage primary connection)
#   5. App Service Plan (Linux)    – compute plan
#   6. Linux Web App               – the future application host, with system
#                                    assigned managed identity
#   7. Role assignments            – grant the App Service MI permission to read
#                                    secrets from Key Vault and to read/write
#                                    blobs in the storage account
###############################################################################

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Random 4-char suffix to keep the storage-account name globally unique.
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
  numeric = true
}

# Information about the caller (so the deploying user also gets KV access).
data "azurerm_client_config" "current" {}

locals {
  # Storage account names: lowercase, alphanumeric only, 3-24 chars.
  storage_account_name = lower("${var.prefix}st${random_string.suffix.result}")

  # Key vault names: 3-24 chars, alphanumeric + dashes, must start with a letter.
  key_vault_name = "${var.prefix}-kv-${random_string.suffix.result}"

  common_tags = {
    project     = "AalenProjectWork"
    part        = "I"
    environment = var.environment
    owner       = var.owner
    managed_by  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# 1. Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# -----------------------------------------------------------------------------
# 2. Storage Account + Blob Container
# -----------------------------------------------------------------------------

resource "azurerm_storage_account" "sa" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Security baseline
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true # required so the App Service can reach it without VNet integration in Part I

  blob_properties {
    versioning_enabled = false
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "images" {
  name                  = "images"
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

# -----------------------------------------------------------------------------
# 3. Key Vault (RBAC mode)
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "kv" {
  name                = local.key_vault_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Use RBAC instead of the legacy access-policy model.
  rbac_authorization_enabled = true

  purge_protection_enabled   = false # disabled for the lab so we can clean up
  soft_delete_retention_days = 7

  public_network_access_enabled = true

  tags = local.common_tags
}

# The deploying principal needs the "Key Vault Administrator" role so it can
# create secrets right after the vault is provisioned.
resource "azurerm_role_assignment" "kv_admin_for_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# -----------------------------------------------------------------------------
# 4. Key Vault Secret – storage account connection string
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "storage_connection_string" {
  name         = "StorageConnectionString"
  value        = azurerm_storage_account.sa.primary_connection_string
  key_vault_id = azurerm_key_vault.kv.id

  # Wait until the role assignment is effective before writing the secret.
  depends_on = [azurerm_role_assignment.kv_admin_for_deployer]
}

# -----------------------------------------------------------------------------
# 5. App Service Plan (Linux)
# -----------------------------------------------------------------------------

resource "azurerm_service_plan" "plan" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 6. Linux Web App (Python) with System-Assigned Managed Identity
# -----------------------------------------------------------------------------

resource "azurerm_linux_web_app" "app" {
  name                = "${var.prefix}-app-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.plan.location
  service_plan_id     = azurerm_service_plan.plan.id

  https_only = true

  site_config {
    always_on = false # B1 plan does not require always_on for the lab

    application_stack {
      python_version = var.python_version
    }
  }

  # System-assigned managed identity – this is the principal that the App
  # Service will use to authenticate against Key Vault and Storage.
  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    # Tell the application where the key vault lives. The actual secret is
    # fetched at runtime by the application code (Part II) using DefaultAzureCredential.
    "KEY_VAULT_NAME"            = azurerm_key_vault.kv.name
    "STORAGE_ACCOUNT_NAME"      = azurerm_storage_account.sa.name
    "IMAGES_CONTAINER_NAME"     = azurerm_storage_container.images.name
    "WEBSITES_PORT"             = "8000"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 7. Role assignments – grant the App Service MI least-privilege access
# -----------------------------------------------------------------------------

# (a) Read secrets from the key vault.
resource "azurerm_role_assignment" "app_kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.app.identity[0].principal_id
}

# (b) Read & write blobs in the storage account.
resource "azurerm_role_assignment" "app_blob_data_contributor" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_web_app.app.identity[0].principal_id
}
