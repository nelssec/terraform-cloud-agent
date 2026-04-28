# modules/oci/main.tf
# Stores Qualys credentials in OCI Vault for agent deployment to existing instances.
# No instances are created.

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
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

variable "compartment_id" {
  type = string
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# Vault & Secrets
# -----------------------------------------------------------------------------

resource "oci_kms_vault" "qualys" {
  compartment_id = var.compartment_id
  display_name   = "qualys-agent-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "qualys" {
  compartment_id      = var.compartment_id
  display_name        = "qualys-agent-key"
  management_endpoint = oci_kms_vault.qualys.management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = var.freeform_tags
}

resource "oci_vault_secret" "activation_id" {
  compartment_id = var.compartment_id
  secret_name    = "qualys-activation-id"
  vault_id       = oci_kms_vault.qualys.id
  key_id         = oci_kms_key.qualys.id
  description    = "Qualys Cloud Agent Activation ID"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.qualys_activation_id)
  }

  freeform_tags = var.freeform_tags
}

resource "oci_vault_secret" "customer_id" {
  compartment_id = var.compartment_id
  secret_name    = "qualys-customer-id"
  vault_id       = oci_kms_vault.qualys.id
  key_id         = oci_kms_key.qualys.id
  description    = "Qualys Cloud Agent Customer ID"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.qualys_customer_id)
  }

  freeform_tags = var.freeform_tags
}

resource "oci_vault_secret" "api_credentials" {
  compartment_id = var.compartment_id
  secret_name    = "qualys-api-credentials"
  vault_id       = oci_kms_vault.qualys.id
  key_id         = oci_kms_key.qualys.id
  description    = "Qualys API credentials and URIs"

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      api_username = var.qualys_api_username
      api_password = var.qualys_api_password
      server_uri   = var.qualys_server_uri
      base_url     = var.qualys_base_url
    }))
  }

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# IAM — dynamic group + policy for existing instances
# -----------------------------------------------------------------------------

resource "oci_identity_dynamic_group" "qualys_instances" {
  compartment_id = var.compartment_id
  name           = "qualys-agent-instances"
  description    = "Instances allowed to read Qualys credentials"
  matching_rule  = "All {instance.compartment.id = '${var.compartment_id}', tag.qualys-agent.value = 'true'}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "qualys_secret_read" {
  compartment_id = var.compartment_id
  name           = "qualys-agent-secret-read"
  description    = "Allow Qualys instances to read agent credentials"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.qualys_instances.name} to read secret-family in compartment id ${var.compartment_id} where target.secret.id in ('${oci_vault_secret.activation_id.id}', '${oci_vault_secret.customer_id.id}', '${oci_vault_secret.api_credentials.id}')",
  ]

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vault_id" {
  value = oci_kms_vault.qualys.id
}

output "activation_secret_id" {
  value = oci_vault_secret.activation_id.id
}

output "customer_secret_id" {
  value = oci_vault_secret.customer_id.id
}

output "dynamic_group_name" {
  value = oci_identity_dynamic_group.qualys_instances.name
}
