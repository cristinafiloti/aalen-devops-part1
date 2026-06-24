###############################################################################
# outputs.tf
###############################################################################

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "images_container_name" {
  value = azurerm_storage_container.images.name
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "app_service_name" {
  value = azurerm_linux_web_app.app.name
}

output "app_service_url" {
  description = "Public HTTPS URL of the FastAPI application."
  value       = "https://${azurerm_linux_web_app.app.default_hostname}"
}

output "app_service_principal_id" {
  value = azurerm_linux_web_app.app.identity[0].principal_id
}
