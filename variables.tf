# -----------------------------------------------------------------------------
# Qualys credentials
# -----------------------------------------------------------------------------

variable "qualys_activation_id" {
  description = "Qualys Cloud Agent Activation ID"
  type        = string
  sensitive   = true
}

variable "qualys_customer_id" {
  description = "Qualys Customer ID"
  type        = string
  sensitive   = true
}

variable "qualys_server_uri" {
  description = "Qualys Cloud Agent server URI — where the agent phones home (e.g., https://qagpublic.qg2.apps.qualys.com/CloudAgent/)"
  type        = string

  validation {
    condition     = can(regex("^https://", var.qualys_server_uri))
    error_message = "ServerUri must start with https://"
  }
}

variable "qualys_packages" {
  description = <<-DESC
    URLs to the pre-staged Qualys Cloud Agent installer packages. You host these
    (e.g., a bucket or internal mirror) and target instances pull them directly,
    so no Qualys API credentials are distributed to the fleet. Provide only the
    entries matching your target operating systems; leave the rest empty.
  DESC
  type = object({
    deb     = optional(string, "") # Debian / Ubuntu .deb
    rpm     = optional(string, "") # RHEL / CentOS / Rocky / Amazon Linux / SUSE .rpm
    windows = optional(string, "") # Windows .exe
  })
  default = {}
}

# -----------------------------------------------------------------------------
# Common settings
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "deployment_id" {
  description = "Unique deployment identifier"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common labels/tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Cloud selection
# -----------------------------------------------------------------------------

variable "deploy_to_gcp" {
  type    = bool
  default = false
}

variable "deploy_to_aws" {
  type    = bool
  default = false
}

variable "deploy_to_azure" {
  type    = bool
  default = false
}

variable "deploy_to_oci" {
  type    = bool
  default = false
}

variable "deploy_to_alicloud" {
  type    = bool
  default = false
}

# -----------------------------------------------------------------------------
# GCP configuration
# -----------------------------------------------------------------------------

variable "gcp_config" {
  description = "GCP deployment configuration"
  type = object({
    project_id       = string
    region           = string
    zones            = list(string)
    target_all_vms   = optional(bool, false)
    inclusion_labels = optional(map(string), { "qualys-agent" = "true" })
    exclusion_labels = optional(map(string), {})
    rollout_percent  = optional(number, 10)
  })
  default = {
    project_id = ""
    region     = "us-central1"
    zones      = []
  }
}

# -----------------------------------------------------------------------------
# AWS configuration (uncomment module in main.tf to use)
# -----------------------------------------------------------------------------

# variable "aws_config" {
#   type = object({
#     region      = string
#     target_tags = optional(map(string), { "qualys-agent" = "true" })
#   })
#   default = {
#     region = "us-east-1"
#   }
# }

# -----------------------------------------------------------------------------
# Azure configuration (uncomment module in main.tf to use)
# -----------------------------------------------------------------------------

# variable "azure_config" {
#   type = object({
#     resource_group_name = string
#     location            = string
#     vm_principal_ids    = optional(list(string), [])
#   })
#   default = {
#     resource_group_name = "qualys-agents-rg"
#     location            = "East US"
#   }
# }

# -----------------------------------------------------------------------------
# OCI configuration (uncomment module in main.tf to use)
# -----------------------------------------------------------------------------

# variable "oci_config" {
#   type = object({
#     compartment_id = string
#   })
#   default = {
#     compartment_id = ""
#   }
# }

# -----------------------------------------------------------------------------
# Alibaba Cloud configuration (uncomment module in main.tf to use)
# -----------------------------------------------------------------------------

# variable "alicloud_config" {
#   type = object({
#     region = string
#   })
#   default = {
#     region = "us-west-1"
#   }
# }
