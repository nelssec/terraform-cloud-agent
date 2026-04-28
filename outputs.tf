output "gcp_deployment" {
  description = "GCP deployment details"
  value = var.deploy_to_gcp ? {
    secret_activation_id = module.gcp_qualys[0].secret_activation_id
    secret_customer_id   = module.gcp_qualys[0].secret_customer_id
    os_policy_ids        = module.gcp_qualys[0].os_policy_ids
    targeted_zones       = module.gcp_qualys[0].targeted_zones
    project_id           = var.gcp_config.project_id
  } : null
}

# Uncomment when enabling other clouds:

# output "aws_deployment" {
#   value = var.deploy_to_aws ? {
#     secret_arn          = module.aws_qualys[0].secret_arn
#     iam_policy_arn      = module.aws_qualys[0].iam_policy_arn
#     ssm_document_linux  = module.aws_qualys[0].ssm_document_linux
#     ssm_document_windows = module.aws_qualys[0].ssm_document_windows
#   } : null
# }

# output "azure_deployment" {
#   value = var.deploy_to_azure ? {
#     key_vault_name = module.azure_qualys[0].key_vault_name
#     key_vault_uri  = module.azure_qualys[0].key_vault_uri
#   } : null
# }

# output "oci_deployment" {
#   value = var.deploy_to_oci ? {
#     vault_id           = module.oci_qualys[0].vault_id
#     dynamic_group_name = module.oci_qualys[0].dynamic_group_name
#   } : null
# }

# output "alicloud_deployment" {
#   value = var.deploy_to_alicloud ? {
#     command_id      = module.alicloud_qualys[0].command_id
#     iam_policy_name = module.alicloud_qualys[0].iam_policy_name
#   } : null
# }

output "deployment_summary" {
  value = {
    qualys_base_url = var.qualys_base_url
    qualys_server_uri = var.qualys_server_uri
    environment     = var.environment
    deployment_id   = var.deployment_id
    deployed_clouds = compact([
      var.deploy_to_gcp ? "GCP" : "",
      var.deploy_to_aws ? "AWS" : "",
      var.deploy_to_azure ? "Azure" : "",
      var.deploy_to_oci ? "OCI" : "",
      var.deploy_to_alicloud ? "Alibaba" : "",
    ])
  }
}
