resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = var.environment
    project     = "azure-enterprise-platform"
    managed_by  = "terraform"
  }
}
