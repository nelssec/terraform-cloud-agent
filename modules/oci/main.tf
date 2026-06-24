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

variable "qualys_packages" {
  description = "Pre-staged installer URLs the instances pull from (deb/rpm/windows). No Qualys API creds reach the fleet."
  type = object({
    deb     = optional(string, "")
    rpm     = optional(string, "")
    windows = optional(string, "")
  })
  default = {}
}

variable "compartment_id" {
  type = string
}

variable "freeform_tags" {
  type    = map(string)
  default = {}
}

# OCI dynamic-group matching rules can only reference DEFINED tags, not freeform
# tags. The module creates the namespace + key below so the rule actually matches.
variable "agent_tag_namespace" {
  description = "Defined-tag namespace used to select instances for enrollment."
  type        = string
  default     = "qualys"
}

variable "agent_tag_key" {
  description = "Defined-tag key whose value marks an instance for enrollment."
  type        = string
  default     = "agent"
}

variable "agent_tag_value" {
  description = "Defined-tag value that marks an instance for enrollment."
  type        = string
  default     = "true"
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

# -----------------------------------------------------------------------------
# Defined tag — required for dynamic-group matching (freeform tags don't match)
# Apply ${var.agent_tag_namespace}.${var.agent_tag_key} = "${var.agent_tag_value}"
# to the instances you want enrolled.
# -----------------------------------------------------------------------------

resource "oci_identity_tag_namespace" "qualys" {
  compartment_id = var.compartment_id
  name           = var.agent_tag_namespace
  description    = "Qualys Cloud Agent instance-selection tags"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_tag" "agent" {
  tag_namespace_id = oci_identity_tag_namespace.qualys.id
  name             = var.agent_tag_key
  description      = "Set to '${var.agent_tag_value}' to enroll the instance for Qualys agent secret access"
}

# -----------------------------------------------------------------------------
# IAM — dynamic group + policy for existing instances
# -----------------------------------------------------------------------------

resource "oci_identity_dynamic_group" "qualys_instances" {
  compartment_id = var.compartment_id
  name           = "qualys-agent-instances"
  description    = "Instances allowed to read Qualys credentials"
  matching_rule  = "All {instance.compartment.id = '${var.compartment_id}', tag.${var.agent_tag_namespace}.${var.agent_tag_key}.value = '${var.agent_tag_value}'}"
  freeform_tags  = var.freeform_tags

  depends_on = [oci_identity_tag.agent]
}

resource "oci_identity_policy" "qualys_secret_read" {
  compartment_id = var.compartment_id
  name           = "qualys-agent-secret-read"
  description    = "Allow Qualys instances to read agent credentials"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.qualys_instances.name} to read secret-family in compartment id ${var.compartment_id} where target.secret.id in ('${oci_vault_secret.activation_id.id}', '${oci_vault_secret.customer_id.id}')",
  ]

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Install script — run against your instances via OCI Run Command. It uses the
# instance principal to read the two secrets, pulls the pre-staged installer,
# and activates against ServerUri. No Qualys API credentials on the fleet.
# -----------------------------------------------------------------------------

locals {
  install_script = <<-SCRIPT
    #!/bin/bash
    set -e
    if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then echo "Agent already running"; exit 0; fi
    ACTIVATION_ID=$(oci secrets secret-bundle get --auth instance_principal --secret-id ${oci_vault_secret.activation_id.id} --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
    CUSTOMER_ID=$(oci secrets secret-bundle get --auth instance_principal --secret-id ${oci_vault_secret.customer_id.id} --query 'data."secret-bundle-content".content' --raw-output | base64 -d)
    curl -fSL "${var.qualys_packages.rpm}" -o /tmp/qualys-agent.rpm
    rpm -ivh /tmp/qualys-agent.rpm || yum install -y /tmp/qualys-agent.rpm || dnf install -y /tmp/qualys-agent.rpm
    /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId="$ACTIVATION_ID" CustomerId="$CUSTOMER_ID" ServerUri="${var.qualys_server_uri}"
    systemctl enable qualys-cloud-agent && systemctl restart qualys-cloud-agent
    rm -f /tmp/qualys-agent.rpm
    unset ACTIVATION_ID CUSTOMER_ID
  SCRIPT
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vault_id" {
  value = oci_kms_vault.qualys.id
}

output "install_script" {
  description = "Run against your instances via OCI Run Command (instance principal reads the secrets)."
  value       = local.install_script
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
