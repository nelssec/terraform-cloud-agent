# Qualys Cloud Agent — Multi-Cloud Terraform

Terraform modules to deploy the Qualys Cloud Agent to **existing infrastructure** across AWS, Azure, GCP, OCI, and Alibaba Cloud.

No VMs are created. Each module stores your Qualys credentials in the cloud's native secret manager and uses the cloud's native remote execution mechanism to install the agent on your existing instances.

## How It Works

| Cloud | Secret Storage | Deployment Mechanism | Targeting |
|-------|---------------|---------------------|-----------|
| GCP | Secret Manager | OS Config Policy (VM Manager) | Labels per zone |
| AWS | Secrets Manager | SSM Document + Association | Instance tags |
| Azure | Key Vault | Run Command / VM Extension | Manual or per-VM |
| OCI | OCI Vault | Dynamic group + Run Command | Freeform tags |
| Alibaba | KMS Secrets | Cloud Assistant Command | Instance selection |

Each module:
1. Stores your Activation ID and Customer ID in the cloud's secret manager
2. Grants existing instances least-privilege access to read those secrets
3. Provides a deployment mechanism to install the agent

The agent install scripts are idempotent — if the agent is already running, they exit cleanly.

## Quick Start (GCP)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Qualys credentials and GCP project
terraform init
terraform plan
terraform apply
```

### Label your VMs

By default, only VMs with the label `qualys-agent=true` get the agent:

```bash
gcloud compute instances update my-vm --zone=us-central1-a \
  --update-labels=qualys-agent=true
```

Or set `target_all_vms = true` in your config to deploy to every VM.

## Configuration

### Required: Qualys Credentials

Get these from the Qualys Console under Assets > Agents:

```hcl
qualys_activation_id = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
qualys_customer_id   = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
qualys_platform      = "qualysguard.qualys.com"
```

Common platform URLs:
- US Platform 1: `qualysguard.qualys.com`
- US Platform 2: `qualysguard.qg2.apps.qualys.com`
- EU: `qualysguard.qualys.eu`
- India: `qualysguard.qg1.apps.qualys.in`

### GCP Config

```hcl
deploy_to_gcp = true

gcp_config = {
  project_id = "my-project"
  region     = "us-central1"
  zones      = ["us-central1-a", "us-central1-b"]

  target_all_vms   = false                              # true = all VMs in each zone
  inclusion_labels = { "qualys-agent" = "true" }        # opt-in label
  exclusion_labels = { "qualys-exclude" = "true" }      # skip these
  rollout_percent  = 10                                  # % of VMs updated at once
}
```

The GCP module uses [OS Config policies](https://cloud.google.com/compute/vm-manager/docs/os-policies/create-os-policy-assignment) which:
- Run per-zone (one policy assignment per zone you list)
- Automatically detect the OS (Debian/Ubuntu, RHEL/CentOS, SUSE) and install the right package
- Re-check compliance periodically and reinstall if the agent is removed
- Roll out gradually based on `rollout_percent`

### AWS Config

Uncomment the AWS provider and module in `main.tf`, then:

```hcl
deploy_to_aws = true

aws_config = {
  region      = "us-east-1"
  target_tags = { "qualys-agent" = "true" }
}
```

The AWS module creates:
- A Secrets Manager secret with your credentials
- SSM documents for Linux and Windows
- SSM associations that auto-run daily against tagged instances

**Prerequisites**: Your instances need the SSM agent running and an IAM role with the output `iam_policy_arn` attached.

### Azure Config

```hcl
deploy_to_azure = true

azure_config = {
  resource_group_name = "qualys-agents-rg"
  location            = "East US"
}
```

Creates a Key Vault with your credentials. Use the vault with VM extensions or Run Command to install on your VMs.

### OCI Config

```hcl
deploy_to_oci = true

oci_config = {
  compartment_id = "ocid1.compartment.oc1..aaaaaaaa..."
}
```

Creates a Vault with secrets and a dynamic group policy. Tag your instances with `qualys-agent=true` to grant them secret access.

### Alibaba Cloud Config

```hcl
deploy_to_alicloud = true

alicloud_config = {
  region = "us-west-1"
}
```

Creates KMS secrets and a Cloud Assistant command. Invoke the command against your ECS instances to install.

## Enabling Multiple Clouds

1. Uncomment the `required_providers` block for each cloud in `main.tf`
2. Uncomment the corresponding `module` block
3. Uncomment the variable and output blocks
4. Set `deploy_to_<cloud> = true` in your tfvars

## Security

- **Least privilege**: Each module grants read access only to the specific secrets needed, not project/account-wide
- **No VMs created**: This module doesn't create compute resources or open network ports
- **Secrets in native stores**: Credentials are stored in each cloud's secret manager, never in Terraform state as plaintext (marked `sensitive`)
- **Idempotent installs**: Scripts check if the agent is running before attempting installation
- **Gradual rollout**: GCP/AWS deployments roll out incrementally, not all-at-once

## Verifying Installation

After deployment, check an instance:

```bash
# Linux
sudo systemctl status qualys-cloud-agent
sudo tail -f /var/log/qualys/qualys-cloud-agent.log

# Windows
Get-Service QualysAgent
Get-Content "C:\ProgramData\Qualys\QualysAgent\Log\QualysAgent.log" -Tail 50
```

The agent should appear in your Qualys Console within 5-10 minutes.

## File Structure

```
.
├── main.tf                  # Root module — cloud selection and provider config
├── variables.tf             # Input variables
├── outputs.tf               # Deployment outputs
├── terraform.tfvars.example # Example configuration
└── modules/
    ├── gcp/main.tf          # GCP: Secret Manager + OS Config policies
    ├── aws/main.tf          # AWS: Secrets Manager + SSM documents
    ├── azure/main.tf        # Azure: Key Vault
    ├── oci/main.tf          # OCI: Vault + dynamic group
    └── alicloud/main.tf     # Alibaba: KMS + Cloud Assistant command
```

## Network Requirements

The Qualys agent needs outbound HTTPS (TCP 443) to your Qualys platform. This module does not create firewall rules — ensure your existing network allows this traffic.
