# These outputs are read by the GitHub Actions pipeline (`terraform output
# -raw ...` in the `terraform` job) and passed to later jobs as job outputs,
# so nothing has to be copied into GitHub by hand.

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.rg.name
}

output "acr_name" {
  description = "Name of the Azure Container Registry"
  value       = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  description = "Login server of the Azure Container Registry"
  value       = azurerm_container_registry.acr.login_server
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "storage_account_name" {
  description = "Name of the Azure Storage Account"
  value       = azurerm_storage_account.storage_account.name
}

output "storage_connection_string" {
  description = "Connection string for Blob Storage (injected into the application-secret Kubernetes secret)"
  value       = azurerm_storage_account.storage_account.primary_connection_string
  sensitive   = true
}
