# modules/alicloud/main.tf
# Stores Qualys credentials in Alibaba Cloud KMS and provides a Cloud Assistant
# command to install the agent on existing ECS instances.
# No instances are created.

terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.200"
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

variable "region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# KMS Secrets
# -----------------------------------------------------------------------------

resource "alicloud_kms_secret" "activation_id" {
  secret_name                   = "qualys-activation-id"
  secret_data                   = var.qualys_activation_id
  version_id                    = "v1"
  description                   = "Qualys Cloud Agent Activation ID"
  force_delete_without_recovery = false
  tags                          = var.tags
}

resource "alicloud_kms_secret" "customer_id" {
  secret_name                   = "qualys-customer-id"
  secret_data                   = var.qualys_customer_id
  version_id                    = "v1"
  description                   = "Qualys Cloud Agent Customer ID"
  force_delete_without_recovery = false
  tags                          = var.tags
}

# -----------------------------------------------------------------------------
# RAM — policy for existing instances to read secrets
# -----------------------------------------------------------------------------

resource "alicloud_ram_policy" "qualys_secret_read" {
  policy_name = "qualys-agent-secret-read"
  description = "Allows reading Qualys agent credentials from KMS"

  policy_document = jsonencode({
    Version = "1"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:GetSecretValue"]
        Resource = ["acs:kms:${var.region}:*:secret/qualys-*"]
      }
    ]
  })

  force = true
}

# -----------------------------------------------------------------------------
# Cloud Assistant Command — install on existing instances
# Uses Qualys download API with basic auth, passes ServerUri on activation.
# -----------------------------------------------------------------------------

resource "alicloud_ecs_command" "install_qualys" {
  name             = "InstallQualysAgent"
  type             = "RunShellScript"
  description      = "Install Qualys Cloud Agent on ECS instances"
  timeout          = 600
  working_dir      = "/tmp"
  enable_parameter = false

  command_content = base64encode(<<-SCRIPT
    #!/bin/bash
    set -e
    if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then echo "Agent already running"; exit 0; fi
    ACTIVATION_ID=$(aliyun kms GetSecretValue --SecretName qualys-activation-id --query SecretData --output text 2>/dev/null)
    CUSTOMER_ID=$(aliyun kms GetSecretValue --SecretName qualys-customer-id --query SecretData --output text 2>/dev/null)
    if [ -z "$ACTIVATION_ID" ] || [ -z "$CUSTOMER_ID" ]; then echo "Failed to get credentials"; exit 1; fi
    curl -fSL "${var.qualys_packages.rpm}" -o /tmp/qualys-agent.rpm
    rpm -ivh /tmp/qualys-agent.rpm || yum install -y /tmp/qualys-agent.rpm || dnf install -y /tmp/qualys-agent.rpm
    /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId="$ACTIVATION_ID" CustomerId="$CUSTOMER_ID" ServerUri="${var.qualys_server_uri}"
    systemctl enable qualys-cloud-agent && systemctl restart qualys-cloud-agent
    rm -f /tmp/qualys-agent.rpm
    unset ACTIVATION_ID CUSTOMER_ID
  SCRIPT
  )
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "activation_secret_name" {
  value = alicloud_kms_secret.activation_id.secret_name
}

output "customer_secret_name" {
  value = alicloud_kms_secret.customer_id.secret_name
}

output "iam_policy_name" {
  description = "Attach this policy to your existing instance RAM roles"
  value       = alicloud_ram_policy.qualys_secret_read.policy_name
}

output "command_id" {
  description = "Cloud Assistant command ID — invoke against your ECS instances"
  value       = alicloud_ecs_command.install_qualys.id
}
