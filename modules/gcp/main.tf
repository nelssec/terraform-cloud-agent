# modules/gcp/main.tf
# Deploys Qualys Cloud Agent to existing GCP VMs via OS Config policies.
# No VMs are created — this targets your existing infrastructure.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "project_id" {
  type = string
}

variable "zones" {
  description = "Zones to deploy the OS policy to. One policy assignment per zone."
  type        = list(string)
}

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

variable "target_all_vms" {
  description = "If true, target all VMs in each zone. If false, only target VMs with inclusion_labels."
  type        = bool
  default     = false
}

variable "inclusion_labels" {
  description = "Only target VMs with these labels (ignored if target_all_vms = true)"
  type        = map(string)
  default     = { "qualys-agent" = "true" }
}

variable "exclusion_labels" {
  description = "Exclude VMs with these labels"
  type        = map(string)
  default     = {}
}

variable "rollout_percent" {
  description = "Percentage of VMs to update simultaneously per zone"
  type        = number
  default     = 10
}

variable "rollout_min_wait" {
  description = "Minimum wait between rollout batches"
  type        = string
  default     = "120s"
}

variable "labels" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# APIs
# -----------------------------------------------------------------------------

resource "google_project_service" "required_apis" {
  for_each = toset([
    "secretmanager.googleapis.com",
    "osconfig.googleapis.com",
  ])

  project                    = var.project_id
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
}

# -----------------------------------------------------------------------------
# Secret Manager — store all Qualys credentials
# -----------------------------------------------------------------------------

resource "google_secret_manager_secret" "qualys_activation_id" {
  secret_id = "qualys-activation-id"
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "qualys_activation_id" {
  secret      = google_secret_manager_secret.qualys_activation_id.id
  secret_data = var.qualys_activation_id
}

resource "google_secret_manager_secret" "qualys_customer_id" {
  secret_id = "qualys-customer-id"
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "qualys_customer_id" {
  secret      = google_secret_manager_secret.qualys_customer_id.id
  secret_data = var.qualys_customer_id
}

# -----------------------------------------------------------------------------
# IAM — let the default compute SA read the secrets
# Scoped to these specific secrets only, not project-wide.
# -----------------------------------------------------------------------------

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

locals {
  secret_ids = [
    google_secret_manager_secret.qualys_activation_id.id,
    google_secret_manager_secret.qualys_customer_id.id,
  ]
}

resource "google_secret_manager_secret_iam_member" "compute_sa_access" {
  for_each  = toset(local.secret_ids)
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

# -----------------------------------------------------------------------------
# OS Config Policy — install Qualys agent on existing VMs
# One assignment per zone (OS Config requires zone-level targeting).
#
# The installer is pulled from a pre-staged URL (var.qualys_packages); only the
# ActivationId/CustomerId secrets are read on the instance — no Qualys API
# credentials. Activation passes ServerUri so the agent phones home correctly.
# -----------------------------------------------------------------------------

resource "google_os_config_os_policy_assignment" "qualys_agent" {
  for_each = toset(var.zones)

  name     = "qualys-agent-install-${each.key}"
  location = each.key
  project  = var.project_id

  instance_filter {
    all = var.target_all_vms

    dynamic "inclusion_labels" {
      for_each = var.target_all_vms ? [] : [var.inclusion_labels]
      content {
        labels = inclusion_labels.value
      }
    }

    dynamic "exclusion_labels" {
      for_each = length(var.exclusion_labels) > 0 ? [var.exclusion_labels] : []
      content {
        labels = exclusion_labels.value
      }
    }
  }

  os_policies {
    id   = "install-qualys-cloud-agent"
    mode = "ENFORCEMENT"

    resource_groups {
      # Debian/Ubuntu
      inventory_filters {
        os_short_name = "debian"
      }

      resources {
        id = "install-qualys-deb"
        exec {
          validate {
            interpreter = "SHELL"
            # OS Config validate convention: exit 100 = in desired state (compliant),
            # exit 101 = not in desired state (run enforce). Any other code = error.
            script = "if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then exit 100; else exit 101; fi"
          }
          enforce {
            interpreter = "SHELL"
            script      = <<-SCRIPT
              #!/bin/bash
              set -e
              PROJECT="${var.project_id}"
              ACTIVATION_ID=$(gcloud secrets versions access latest --secret="qualys-activation-id" --project="$PROJECT")
              CUSTOMER_ID=$(gcloud secrets versions access latest --secret="qualys-customer-id" --project="$PROJECT")
              export DEBIAN_FRONTEND=noninteractive
              apt-get update -y && apt-get install -y curl
              curl -fSL "${var.qualys_packages.deb}" -o /tmp/qualys-agent.deb
              dpkg -i /tmp/qualys-agent.deb || apt-get install -f -y
              /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh \
                ActivationId="$ACTIVATION_ID" \
                CustomerId="$CUSTOMER_ID" \
                ServerUri="${var.qualys_server_uri}"
              systemctl enable qualys-cloud-agent
              systemctl restart qualys-cloud-agent
              rm -f /tmp/qualys-agent.deb
              unset ACTIVATION_ID CUSTOMER_ID
              exit 100
            SCRIPT
          }
        }
      }
    }

    resource_groups {
      # RHEL/CentOS/Rocky/Amazon Linux
      inventory_filters {
        os_short_name = "rhel"
      }

      resources {
        id = "install-qualys-rpm"
        exec {
          validate {
            interpreter = "SHELL"
            # OS Config validate convention: exit 100 = in desired state (compliant),
            # exit 101 = not in desired state (run enforce). Any other code = error.
            script = "if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then exit 100; else exit 101; fi"
          }
          enforce {
            interpreter = "SHELL"
            script      = <<-SCRIPT
              #!/bin/bash
              set -e
              PROJECT="${var.project_id}"
              ACTIVATION_ID=$(gcloud secrets versions access latest --secret="qualys-activation-id" --project="$PROJECT")
              CUSTOMER_ID=$(gcloud secrets versions access latest --secret="qualys-customer-id" --project="$PROJECT")
              curl -fSL "${var.qualys_packages.rpm}" -o /tmp/qualys-agent.rpm
              rpm -ivh /tmp/qualys-agent.rpm || yum install -y /tmp/qualys-agent.rpm || dnf install -y /tmp/qualys-agent.rpm
              /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh \
                ActivationId="$ACTIVATION_ID" \
                CustomerId="$CUSTOMER_ID" \
                ServerUri="${var.qualys_server_uri}"
              systemctl enable qualys-cloud-agent
              systemctl restart qualys-cloud-agent
              rm -f /tmp/qualys-agent.rpm
              unset ACTIVATION_ID CUSTOMER_ID
              exit 100
            SCRIPT
          }
        }
      }
    }

    resource_groups {
      # SUSE
      inventory_filters {
        os_short_name = "sles"
      }

      resources {
        id = "install-qualys-sles"
        exec {
          validate {
            interpreter = "SHELL"
            # OS Config validate convention: exit 100 = in desired state (compliant),
            # exit 101 = not in desired state (run enforce). Any other code = error.
            script = "if systemctl is-active --quiet qualys-cloud-agent 2>/dev/null; then exit 100; else exit 101; fi"
          }
          enforce {
            interpreter = "SHELL"
            script      = <<-SCRIPT
              #!/bin/bash
              set -e
              PROJECT="${var.project_id}"
              ACTIVATION_ID=$(gcloud secrets versions access latest --secret="qualys-activation-id" --project="$PROJECT")
              CUSTOMER_ID=$(gcloud secrets versions access latest --secret="qualys-customer-id" --project="$PROJECT")
              curl -fSL "${var.qualys_packages.rpm}" -o /tmp/qualys-agent.rpm
              zypper install -y /tmp/qualys-agent.rpm
              /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh \
                ActivationId="$ACTIVATION_ID" \
                CustomerId="$CUSTOMER_ID" \
                ServerUri="${var.qualys_server_uri}"
              systemctl enable qualys-cloud-agent
              systemctl restart qualys-cloud-agent
              rm -f /tmp/qualys-agent.rpm
              unset ACTIVATION_ID CUSTOMER_ID
              exit 100
            SCRIPT
          }
        }
      }
    }
  }

  rollout {
    disruption_budget {
      percent = var.rollout_percent
    }
    min_wait_duration = var.rollout_min_wait
  }

  depends_on = [
    google_project_service.required_apis,
    google_secret_manager_secret_version.qualys_activation_id,
    google_secret_manager_secret_version.qualys_customer_id,
    google_secret_manager_secret_iam_member.compute_sa_access,
  ]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "secret_activation_id" {
  value = google_secret_manager_secret.qualys_activation_id.id
}

output "secret_customer_id" {
  value = google_secret_manager_secret.qualys_customer_id.id
}

output "os_policy_ids" {
  value = { for zone, policy in google_os_config_os_policy_assignment.qualys_agent : zone => policy.id }
}

output "targeted_zones" {
  value = var.zones
}
