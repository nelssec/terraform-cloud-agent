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

variable "qualys_packages" {
  description = "Pre-staged installer URLs the instances pull from (deb/rpm/windows). No Qualys API creds reach the fleet."
  type = object({
    deb     = optional(string, "")
    rpm     = optional(string, "")
    windows = optional(string, "")
  })
  default = {}
}

variable "vm_principal_ids" {
  description = "Object (principal) IDs of the managed identities on your VMs that should read the agent secrets. Each gets a Key Vault 'Get' access policy. Leave empty to grant access manually later."
  type        = list(string)
  default     = []
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

# -----------------------------------------------------------------------------
# Access for the VMs' managed identities to read the two secrets
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_access_policy" "vm_identities" {
  for_each = toset(var.vm_principal_ids)

  key_vault_id = azurerm_key_vault.qualys.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = each.value

  secret_permissions = ["Get"]
}

# -----------------------------------------------------------------------------
# Install scripts — run these against your VMs via `az vm run-command invoke`.
# They authenticate with the VM's managed identity, read the two secrets, pull
# the pre-staged installer, and activate against ServerUri.
# -----------------------------------------------------------------------------

locals {
  install_script_linux = <<-SCRIPT
    #!/bin/bash
    set -e
    if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then echo "Agent already running"; exit 0; fi
    az login --identity >/dev/null
    ACTIVATION_ID=$(az keyvault secret show --vault-name ${azurerm_key_vault.qualys.name} --name qualys-activation-id --query value -o tsv)
    CUSTOMER_ID=$(az keyvault secret show --vault-name ${azurerm_key_vault.qualys.name} --name qualys-customer-id --query value -o tsv)
    if command -v apt-get >/dev/null 2>&1; then
      curl -fSL "${var.qualys_packages.deb}" -o /tmp/qualys-agent.deb
      dpkg -i /tmp/qualys-agent.deb || apt-get install -f -y
      rm -f /tmp/qualys-agent.deb
    else
      curl -fSL "${var.qualys_packages.rpm}" -o /tmp/qualys-agent.rpm
      rpm -ivh /tmp/qualys-agent.rpm || yum install -y /tmp/qualys-agent.rpm || dnf install -y /tmp/qualys-agent.rpm
      rm -f /tmp/qualys-agent.rpm
    fi
    /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId="$ACTIVATION_ID" CustomerId="$CUSTOMER_ID" ServerUri="${var.qualys_server_uri}"
    systemctl enable qualys-cloud-agent && systemctl restart qualys-cloud-agent
    unset ACTIVATION_ID CUSTOMER_ID
  SCRIPT

  install_script_windows = <<-SCRIPT
    $ErrorActionPreference = 'Stop'
    if (Get-Service -Name QualysAgent -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) { Write-Host 'Agent already running'; exit 0 }
    az login --identity | Out-Null
    $ActivationId = az keyvault secret show --vault-name ${azurerm_key_vault.qualys.name} --name qualys-activation-id --query value -o tsv
    $CustomerId = az keyvault secret show --vault-name ${azurerm_key_vault.qualys.name} --name qualys-customer-id --query value -o tsv
    Invoke-WebRequest -Uri '${var.qualys_packages.windows}' -OutFile "$env:TEMP\QualysAgent.exe"
    Start-Process -FilePath "$env:TEMP\QualysAgent.exe" -ArgumentList @('/install','/quiet','/norestart',"CustomerId={$CustomerId}","ActivationId={$ActivationId}","ServerUri=${var.qualys_server_uri}") -Wait -PassThru
    Remove-Item "$env:TEMP\QualysAgent.exe" -Force -ErrorAction SilentlyContinue
  SCRIPT
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

output "install_script_linux" {
  description = "Run against Linux VMs: az vm run-command invoke --command-id RunShellScript ..."
  value       = local.install_script_linux
}

output "install_script_windows" {
  description = "Run against Windows VMs: az vm run-command invoke --command-id RunPowerShellScript ..."
  value       = local.install_script_windows
}
