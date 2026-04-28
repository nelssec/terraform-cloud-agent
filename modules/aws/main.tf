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

variable "qualys_base_url" {
  description = "Qualys API base URL (e.g., https://qualysguard.qg2.apps.qualys.com)"
  type        = string
}

variable "qualys_api_username" {
  type      = string
  sensitive = true
}

variable "qualys_api_password" {
  type      = string
  sensitive = true
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
# Secrets Manager — store all Qualys credentials
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "qualys_credentials" {
  name                    = "qualys-agent-credentials"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "qualys_credentials" {
  secret_id = aws_secretsmanager_secret.qualys_credentials.id
  secret_string = jsonencode({
    activation_id = var.qualys_activation_id
    customer_id   = var.qualys_customer_id
    server_uri    = var.qualys_server_uri
    base_url      = var.qualys_base_url
    api_username  = var.qualys_api_username
    api_password  = var.qualys_api_password
  })
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
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.qualys_credentials.arn
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
            "SECRET=$(aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_credentials.arn}' --region '${var.region}' --query SecretString --output text)",
            "ACTIVATION_ID=$(echo \"$SECRET\" | jq -r '.activation_id')",
            "CUSTOMER_ID=$(echo \"$SECRET\" | jq -r '.customer_id')",
            "SERVER_URI=$(echo \"$SECRET\" | jq -r '.server_uri')",
            "BASE_URL=$(echo \"$SECRET\" | jq -r '.base_url')",
            "API_USER=$(echo \"$SECRET\" | jq -r '.api_username')",
            "API_PASS=$(echo \"$SECRET\" | jq -r '.api_password')",
            "if command -v apt-get >/dev/null 2>&1; then",
            "  PLATFORM=LINUX_UBUNTU",
            "  AGENT_FILE=/tmp/qualys-agent.deb",
            "else",
            "  PLATFORM=LINUX",
            "  AGENT_FILE=/tmp/qualys-agent.rpm",
            "fi",
            "curl -u \"$API_USER:$API_PASS\" -X POST -H 'Content-Type: text/xml' -H 'X-Requested-With: curl' -d \"<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><ServiceRequest><data><DownloadBinary><platform>$PLATFORM</platform><architecture>X_86_64</architecture></DownloadBinary></data></ServiceRequest>\" \"$BASE_URL/qps/rest/1.0/download/ca/downloadbinary/\" -o \"$AGENT_FILE\"",
            "if command -v apt-get >/dev/null 2>&1; then",
            "  dpkg -i $AGENT_FILE || apt-get install -f -y",
            "else",
            "  rpm -ivh $AGENT_FILE || yum install -y $AGENT_FILE || dnf install -y $AGENT_FILE",
            "fi",
            "/usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId=\"$ACTIVATION_ID\" CustomerId=\"$CUSTOMER_ID\" ServerUri=\"$SERVER_URI\"",
            "systemctl enable qualys-cloud-agent && systemctl restart qualys-cloud-agent",
            "rm -f $AGENT_FILE",
            "unset ACTIVATION_ID CUSTOMER_ID SERVER_URI API_USER API_PASS SECRET",
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
            "$Secret = (aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.qualys_credentials.arn}' --region '${var.region}' --query SecretString --output text) | ConvertFrom-Json",
            "$Cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(\"$($Secret.api_username):$($Secret.api_password)\"))",
            "$Body = '<?xml version=\"1.0\" encoding=\"UTF-8\"?><ServiceRequest><data><DownloadBinary><platform>WINDOWS</platform><architecture>X_86_64</architecture></DownloadBinary></data></ServiceRequest>'",
            "$Headers = @{ Authorization = \"Basic $Cred\"; 'Content-Type' = 'text/xml'; 'X-Requested-With' = 'PowerShell' }",
            "Invoke-WebRequest -Uri \"$($Secret.base_url)/qps/rest/1.0/download/ca/downloadbinary/\" -Method Post -Headers $Headers -Body $Body -OutFile \"$env:TEMP\\QualysAgent.exe\"",
            "Start-Process -FilePath \"$env:TEMP\\QualysAgent.exe\" -ArgumentList @('/install', '/quiet', '/norestart', \"CustomerId={$($Secret.customer_id)}\", \"ActivationId={$($Secret.activation_id)}\", \"ServerUri=$($Secret.server_uri)\") -Wait -PassThru",
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

output "secret_arn" {
  value = aws_secretsmanager_secret.qualys_credentials.arn
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
