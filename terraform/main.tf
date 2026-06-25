###############################################################################
# main.tf  –  Project Work Part II
#
# This Terraform definition is designed to be applied ON TOP of the
# infrastructure already provisioned in Part I. The random_string suffix
# from Part I is preserved with lifecycle.ignore_changes so the existing
# resources keep their names.
###############################################################################

# Random suffix inherited from Part I. ignore_changes = all means Terraform
# never regenerates it; the value "suv4" lives in the state file from Part I.
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
  numeric = true

  lifecycle {
    ignore_changes = all
  }
}

data "azurerm_client_config" "current" {}

locals {
  storage_account_name = lower("${var.prefix}st${random_string.suffix.result}")
  key_vault_name       = "${var.prefix}-kv-${random_string.suffix.result}"
  app_name             = "${var.prefix}-app-${random_string.suffix.result}"

  common_tags = {
    project     = "AalenProjectWork"
    part        = "II"
    environment = var.environment
    owner       = var.owner
    managed_by  = "terraform"
  }
}

# ---------- resource group ---------------------------------------------------

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# ---------- storage account + container --------------------------------------

resource "azurerm_storage_account" "sa" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true

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

# ---------- key vault --------------------------------------------------------

resource "azurerm_key_vault" "kv" {
  name                          = local.key_vault_name
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  tags = local.common_tags
}

resource "azurerm_role_assignment" "kv_admin_for_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "storage_connection_string" {
  name         = "StorageConnectionString"
  value        = azurerm_storage_account.sa.primary_connection_string
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.kv_admin_for_deployer]
}

# NEW in Part II: a sensitive application secret kept in Key Vault.
resource "random_password" "app_secret" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "app_secret" {
  name         = "AppSecret"
  value        = random_password.app_secret.result
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.kv_admin_for_deployer]
}

# ---------- app service plan + linux web app --------------------------------

resource "azurerm_service_plan" "plan" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku

  tags = local.common_tags
}

resource "azurerm_linux_web_app" "app" {
  name                = local.app_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.plan.location
  service_plan_id     = azurerm_service_plan.plan.id
  https_only          = true

  site_config {
    always_on = false

    application_stack {
      python_version = var.python_version
    }

    # NEW in Part II: gunicorn + uvicorn worker hosts the FastAPI app.
 app_command_line = "gunicorn -k uvicorn.workers.UvicornWorker -w 2 -b 0.0.0.0:8000 app.main:app"
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    "KEY_VAULT_NAME"                 = azurerm_key_vault.kv.name
    "STORAGE_ACCOUNT_NAME"           = azurerm_storage_account.sa.name
    "IMAGES_CONTAINER_NAME"          = azurerm_storage_container.images.name
    "MAX_UPLOAD_MB"                  = tostring(var.max_upload_mb)
    "WEBSITES_PORT"                  = "8000"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
  }

  tags = local.common_tags
}

# ---------- RBAC: app service MI → key vault & storage ----------------------

resource "azurerm_role_assignment" "app_kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.app.identity[0].principal_id
}

resource "azurerm_role_assignment" "app_blob_data_contributor" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_web_app.app.identity[0].principal_id
}