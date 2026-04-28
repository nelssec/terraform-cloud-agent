# modules/azure/main.tf
# Stores Qualys credentials in Azure Key Vault for agent deployment to existing VMs.
# No VMs are created.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "qualys_activation_id" {
  type      = string
  sensitive = true
}

variable "qualys_customer_id" {
  type      = string
  sensitive = true
}

variable "qualys_server_uri" {
  type = string
}

variable "qualys_base_url" {
  type = string
}

variable "qualys_api_username" {
  type      = string
  sensitive = true
}

variable "qualys_api_password" {
  type      = string
  sensitive = true
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "qualys" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# Key Vault — store all Qualys credentials
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "qualys" {
  name                = "qualys-kv-${substr(md5(var.resource_group_name), 0, 8)}"
  location            = azurerm_resource_group.qualys.location
  resource_group_name = azurerm_resource_group.qualys.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  tags = var.tags
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.qualys.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

resource "azurerm_key_vault_secret" "activation_id" {
  name         = "qualys-activation-id"
  value        = var.qualys_activation_id
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "customer_id" {
  name         = "qualys-customer-id"
  value        = var.qualys_customer_id
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "server_uri" {
  name         = "qualys-server-uri"
  value        = var.qualys_server_uri
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "base_url" {
  name         = "qualys-base-url"
  value        = var.qualys_base_url
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "api_username" {
  name         = "qualys-api-username"
  value        = var.qualys_api_username
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "api_password" {
  name         = "qualys-api-password"
  value        = var.qualys_api_password
  key_vault_id = azurerm_key_vault.qualys.id
  depends_on   = [azurerm_key_vault_access_policy.terraform]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "key_vault_id" {
  value = azurerm_key_vault.qualys.id
}

output "key_vault_name" {
  value = azurerm_key_vault.qualys.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.qualys.vault_uri
}
