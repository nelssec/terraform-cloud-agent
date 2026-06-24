terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    # aws = {
    #   source  = "hashicorp/aws"
    #   version = "~> 5.0"
    # }
    # azurerm = {
    #   source  = "hashicorp/azurerm"
    #   version = "~> 3.0"
    # }
    # oci = {
    #   source  = "oracle/oci"
    #   version = "~> 5.0"
    # }
    # alicloud = {
    #   source  = "aliyun/alicloud"
    #   version = "~> 1.200"
    # }
  }

  # backend "gcs" {
  #   bucket = "your-terraform-state-bucket"
  #   prefix = "qualys-agent"
  # }
}

provider "google" {
  project = var.gcp_config.project_id
  region  = var.gcp_config.region
}

locals {
  common_labels = merge(
    var.tags,
    {
      managed_by    = "terraform"
      qualys_agent  = "true"
      environment   = var.environment
      deployment_id = var.deployment_id
    }
  )
}

# -----------------------------------------------------------------------------
# GCP
# -----------------------------------------------------------------------------

module "gcp_qualys" {
  source = "./modules/gcp"
  count  = var.deploy_to_gcp ? 1 : 0

  project_id           = var.gcp_config.project_id
  zones                = var.gcp_config.zones
  qualys_activation_id = var.qualys_activation_id
  qualys_customer_id   = var.qualys_customer_id
  qualys_server_uri    = var.qualys_server_uri
  qualys_packages      = var.qualys_packages

  target_all_vms   = var.gcp_config.target_all_vms
  inclusion_labels = var.gcp_config.inclusion_labels
  exclusion_labels = var.gcp_config.exclusion_labels
  rollout_percent  = var.gcp_config.rollout_percent

  labels = local.common_labels
}

# -----------------------------------------------------------------------------
# AWS — uncomment provider above and below to enable
# -----------------------------------------------------------------------------

# module "aws_qualys" {
#   source = "./modules/aws"
#   count  = var.deploy_to_aws ? 1 : 0
#
#   qualys_activation_id = var.qualys_activation_id
#   qualys_customer_id   = var.qualys_customer_id
#   qualys_server_uri    = var.qualys_server_uri
#   qualys_packages      = var.qualys_packages
#   region               = var.aws_config.region
#   target_tags          = var.aws_config.target_tags
#   tags                 = local.common_labels
# }

# -----------------------------------------------------------------------------
# Azure — uncomment provider above and below to enable
# -----------------------------------------------------------------------------

# module "azure_qualys" {
#   source = "./modules/azure"
#   count  = var.deploy_to_azure ? 1 : 0
#
#   qualys_activation_id = var.qualys_activation_id
#   qualys_customer_id   = var.qualys_customer_id
#   qualys_server_uri    = var.qualys_server_uri
#   qualys_packages      = var.qualys_packages
#   resource_group_name  = var.azure_config.resource_group_name
#   location             = var.azure_config.location
#   vm_principal_ids     = var.azure_config.vm_principal_ids
#   tags                 = local.common_labels
# }

# -----------------------------------------------------------------------------
# OCI — uncomment provider above and below to enable
# -----------------------------------------------------------------------------

# module "oci_qualys" {
#   source = "./modules/oci"
#   count  = var.deploy_to_oci ? 1 : 0
#
#   qualys_activation_id = var.qualys_activation_id
#   qualys_customer_id   = var.qualys_customer_id
#   qualys_server_uri    = var.qualys_server_uri
#   qualys_packages      = var.qualys_packages
#   compartment_id       = var.oci_config.compartment_id
#   freeform_tags        = local.common_labels
# }

# -----------------------------------------------------------------------------
# Alibaba Cloud — uncomment provider above and below to enable
# -----------------------------------------------------------------------------

# module "alicloud_qualys" {
#   source = "./modules/alicloud"
#   count  = var.deploy_to_alicloud ? 1 : 0
#
#   qualys_activation_id = var.qualys_activation_id
#   qualys_customer_id   = var.qualys_customer_id
#   qualys_server_uri    = var.qualys_server_uri
#   qualys_packages      = var.qualys_packages
#   region               = var.alicloud_config.region
#   tags                 = local.common_labels
# }
