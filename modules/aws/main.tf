# modules/aws/main.tf
# Deploys Qualys Cloud Agent to existing AWS instances via SSM.
# No instances are created — this targets your existing infrastructure.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
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
  description = "Qualys Cloud Agent server URI (e.g., https://qagpublic.qg2.apps.qualys.com/CloudAgent/)"
  type        = string
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

variable "target_tags" {
  description = "Tag key/value to target instances. Instances with this tag get the agent."
  type        = map(string)
  default     = { "qualys-agent" = "true" }
}

variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# Secrets Manager — store the Qualys enrollment IDs (one secret each)
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "qualys_activation_id" {
  name                    = "qualys-activation-id"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "qualys_activation_id" {
  secret_id     = aws_secretsmanager_secret.qualys_activation_id.id
  secret_string = var.qualys_activation_id
}

resource "aws_secretsmanager_secret" "qualys_customer_id" {
  name                    = "qualys-customer-id"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "qualys_customer_id" {
  secret_id     = aws_secretsmanager_secret.qualys_customer_id.id
  secret_string = var.qualys_customer_id
}

# -----------------------------------------------------------------------------
# IAM — policy for existing instances to read the secret
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "qualys_secret_read" {
  name        = "qualys-agent-secret-read"
  description = "Allows reading Qualys agent credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.qualys_activation_id.arn,
          aws_secretsmanager_secret.qualys_customer_id.arn,
        ]
      }
    ]
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# SSM Document — install Qualys agent on Linux
# Downloads via Qualys API, activates with ServerUri.
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "install_qualys_linux" {
  name          = "InstallQualysAgent-Linux"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Qualys Cloud Agent on Linux instances"
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "InstallQualysAgent"
        precondition = {
          StringEquals = ["platformType", "Linux"]
        }
        inputs = {
          timeoutSeconds = "600"
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then echo 'Agent already running'; exit 0; fi",
            "ACTIVATION_ID=$(aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_activation_id.arn}' --region '${var.region}' --query SecretString --output text)",
            "CUSTOMER_ID=$(aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_customer_id.arn}' --region '${var.region}' --query SecretString --output text)",
            "if command -v apt-get >/dev/null 2>&1; then",
            "  PKG_URL='${var.qualys_packages.deb}'",
            "  AGENT_FILE=/tmp/qualys-agent.deb",
            "else",
            "  PKG_URL='${var.qualys_packages.rpm}'",
            "  AGENT_FILE=/tmp/qualys-agent.rpm",
            "fi",
            "curl -fSL \"$PKG_URL\" -o \"$AGENT_FILE\"",
            "if command -v apt-get >/dev/null 2>&1; then",
            "  dpkg -i $AGENT_FILE || apt-get install -f -y",
            "else",
            "  rpm -ivh $AGENT_FILE || yum install -y $AGENT_FILE || dnf install -y $AGENT_FILE",
            "fi",
            "/usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId=\"$ACTIVATION_ID\" CustomerId=\"$CUSTOMER_ID\" ServerUri=\"${var.qualys_server_uri}\"",
            "systemctl enable qualys-cloud-agent && systemctl restart qualys-cloud-agent",
            "rm -f $AGENT_FILE",
            "unset ACTIVATION_ID CUSTOMER_ID",
          ]
        }
      }
    ]
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# SSM Document — install Qualys agent on Windows
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "install_qualys_windows" {
  name          = "InstallQualysAgent-Windows"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Qualys Cloud Agent on Windows instances"
    mainSteps = [
      {
        action = "aws:runPowerShellScript"
        name   = "InstallQualysAgent"
        precondition = {
          StringEquals = ["platformType", "Windows"]
        }
        inputs = {
          timeoutSeconds = "600"
          runCommand = [
            "$ErrorActionPreference = 'Stop'",
            "if (Get-Service -Name QualysAgent -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) { Write-Host 'Agent already running'; exit 0 }",
            "$ActivationId = (aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_activation_id.arn}' --region '${var.region}' --query SecretString --output text)",
            "$CustomerId = (aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_customer_id.arn}' --region '${var.region}' --query SecretString --output text)",
            "Invoke-WebRequest -Uri '${var.qualys_packages.windows}' -OutFile \"$env:TEMP\\QualysAgent.exe\"",
            "Start-Process -FilePath \"$env:TEMP\\QualysAgent.exe\" -ArgumentList @('/install', '/quiet', '/norestart', \"CustomerId={$CustomerId}\", \"ActivationId={$ActivationId}\", \"ServerUri=${var.qualys_server_uri}\") -Wait -PassThru",
            "Remove-Item \"$env:TEMP\\QualysAgent.exe\" -Force -ErrorAction SilentlyContinue",
          ]
        }
      }
    ]
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# SSM Association — auto-install on tagged instances
# -----------------------------------------------------------------------------

resource "aws_ssm_association" "qualys_linux" {
  name = aws_ssm_document.install_qualys_linux.name

  targets {
    key    = "tag:${keys(var.target_tags)[0]}"
    values = [values(var.target_tags)[0]]
  }

  compliance_severity = "HIGH"
  schedule_expression = "rate(1 day)"
}

resource "aws_ssm_association" "qualys_windows" {
  name = aws_ssm_document.install_qualys_windows.name

  targets {
    key    = "tag:${keys(var.target_tags)[0]}"
    values = [values(var.target_tags)[0]]
  }

  compliance_severity = "HIGH"
  schedule_expression = "rate(1 day)"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "secret_activation_arn" {
  value = aws_secretsmanager_secret.qualys_activation_id.arn
}

output "secret_customer_arn" {
  value = aws_secretsmanager_secret.qualys_customer_id.arn
}

output "iam_policy_arn" {
  description = "Attach this policy to your existing instance roles"
  value       = aws_iam_policy.qualys_secret_read.arn
}

output "ssm_document_linux" {
  value = aws_ssm_document.install_qualys_linux.name
}

output "ssm_document_windows" {
  value = aws_ssm_document.install_qualys_windows.name
}
