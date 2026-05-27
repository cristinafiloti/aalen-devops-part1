output "resource_group_name" {
  description = "Name of the resource group that holds all resources."
  value       = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  description = "Globally unique storage account name."
  value       = azurerm_storage_account.sa.name
}

output "images_container_name" {
  description = "Name of the blob container that will host the image uploads."
  value       = azurerm_storage_container.images.name
}

output "key_vault_name" {
  description = "Name of the key vault."
  value       = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  description = "DNS URI of the key vault. Used by the application via DefaultAzureCredential."
  value       = azurerm_key_vault.kv.vault_uri
}

output "app_service_name" {
  description = "Name of the Linux Web App."
  value       = azurerm_linux_web_app.app.name
}

output "app_service_default_hostname" {
  description = "Default *.azurewebsites.net hostname of the Web App."
  value       = azurerm_linux_web_app.app.default_hostname
}

output "app_service_principal_id" {
  description = "Object ID of the system-assigned managed identity of the Web App."
  value       = azurerm_linux_web_app.app.identity[0].principal_id
}
