# Qualys Cloud Agent — Multi-Cloud Terraform

Terraform modules to deploy the Qualys Cloud Agent to **existing infrastructure** across AWS, Azure, GCP, OCI, and Alibaba Cloud.

No VMs are created. Each module stores your Qualys enrollment IDs (Activation ID + Customer ID) in the cloud's native secret manager, grants your existing instances least-privilege read access, and installs the agent from an installer **you pre-stage**. No Qualys API credentials are ever placed on your instances — you host the agent installer (a bucket or internal mirror) and instances pull it directly.

## How It Works

| Cloud | Secret Storage | Install Mechanism | Targeting |
|-------|---------------|-------------------|-----------|
| GCP | Secret Manager | OS Config Policy (VM Manager) — runs automatically | Labels per zone |
| AWS | Secrets Manager | SSM Document + Association — runs automatically | Instance tags |
| Azure | Key Vault | Install-script output, you run via `az vm run-command` | Per-VM |
| OCI | OCI Vault | Install-script output, you run via OCI Run Command | Defined tag |
| Alibaba | KMS Secrets | Cloud Assistant Command, you invoke | Instance selection |

Each module:
1. Stores your Activation ID and Customer ID in the cloud's secret manager
2. Grants existing instances least-privilege access to read those secrets
3. Installs the agent from your pre-staged installer — GCP and AWS run automatically; Azure, OCI, and Alibaba emit a command/script you invoke against your instances

The install scripts are idempotent — if the agent is already running, they exit cleanly.

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

### Required: Qualys enrollment IDs

Get the Activation ID and Customer ID from the Qualys Console under Cloud Agent > Agents. These are the only Qualys secrets stored — no API credentials are needed or distributed.

```hcl
qualys_activation_id = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
qualys_customer_id   = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"

# Where the installed agent phones home
qualys_server_uri = "https://qagpublic.qg2.apps.qualys.com/CloudAgent/"
```

Match `qualys_server_uri` to your platform (find yours at <https://www.qualys.com/platform-identification>):

| Platform | `qualys_server_uri` |
|----------|---------------------|
| US Platform 1 | `https://qagpublic.qg1.apps.qualys.com/CloudAgent/` |
| US Platform 2 | `https://qagpublic.qg2.apps.qualys.com/CloudAgent/` |
| US Platform 3 | `https://qagpublic.qg3.apps.qualys.com/CloudAgent/` |
| EU Platform 1 | `https://qagpublic.qg1.apps.qualys.eu/CloudAgent/` |
| India | `https://qagpublic.qg1.apps.qualys.in/CloudAgent/` |

### Required: pre-staged installer packages

Download the agent installers once from the Qualys Console (Cloud Agent > Agent Installation) and host them somewhere your instances can reach (a cloud bucket, internal mirror, etc.). Instances pull these directly, so **no Qualys API credentials touch the fleet**. Provide only the entries matching your target OSes:

```hcl
qualys_packages = {
  deb     = "https://my-mirror.example.com/qualys/QualysCloudAgent.deb"  # Debian/Ubuntu
  rpm     = "https://my-mirror.example.com/qualys/QualysCloudAgent.rpm"  # RHEL/CentOS/Rocky/Amazon/SUSE
  windows = "https://my-mirror.example.com/qualys/QualysCloudAgent.exe"  # Windows
}
```

Make sure the hosting location is reachable from your instances and, if private, that their existing instance roles/identities can read it.

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
- Automatically detect the OS (Debian/Ubuntu, RHEL/CentOS, SUSE) and install the matching `qualys_packages` entry
- Re-check compliance periodically and reinstall if the agent is removed
- Roll out gradually based on `rollout_percent`

**Prerequisites**: the VM Manager (OS Config) agent must be enabled on your VMs, and the module grants secret access to the project's **default compute service account**. If your VMs run as a custom service account, grant it `roles/secretmanager.secretAccessor` on the two secrets yourself.

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
- Two Secrets Manager secrets (`qualys-activation-id`, `qualys-customer-id`)
- SSM documents for Linux and Windows that pull the pre-staged installer
- SSM associations that auto-run daily against tagged instances

**Prerequisites**: Your instances need the SSM agent running and an instance profile carrying both `AmazonSSMManagedInstanceCore` (for SSM itself) and the module's output `iam_policy_arn` (to read the two secrets).

### Azure Config

```hcl
deploy_to_azure = true

azure_config = {
  resource_group_name = "qualys-agents-rg"
  location            = "East US"
}
```

Creates a Key Vault holding the two enrollment IDs and grants `Get` access to the VM managed identities you pass in `azure_config.vm_principal_ids`. The module outputs ready-to-run `install_script_linux` / `install_script_windows` — the VM's managed identity reads the secrets and pulls the installer. Run a script against a VM with:

```bash
az vm run-command invoke -g qualys-agents-rg -n my-vm \
  --command-id RunShellScript --scripts @<(echo "$INSTALL_SCRIPT_LINUX")
```

where `$INSTALL_SCRIPT_LINUX` is the module's `install_script_linux` output. Azure has no tag-targeted fleet install primitive, so you invoke the script per VM (or wrap it in your own loop). Each VM also needs the Azure CLI and a managed identity included in `vm_principal_ids`.

### OCI Config

```hcl
deploy_to_oci = true

oci_config = {
  compartment_id = "ocid1.compartment.oc1..aaaaaaaa..."
}
```

Creates a Vault with the two enrollment IDs, a **defined tag** (`qualys.agent`, created by the module), a dynamic group that matches instances carrying that tag, and a policy granting them secret read. Apply the defined tag `qualys.agent = "true"` to the instances you want enrolled (freeform tags do **not** work in OCI dynamic-group rules). The module outputs an `install_script` to run via OCI Run Command — the instance principal reads the secrets and pulls the installer.

### Alibaba Cloud Config

```hcl
deploy_to_alicloud = true

alicloud_config = {
  region = "us-west-1"
}
```

Creates KMS secrets and a Cloud Assistant command that pulls the pre-staged installer. Invoke the command (output `command_id`) against your ECS instances to install.

## Enabling Multiple Clouds

1. Uncomment the `required_providers` block for each cloud in `main.tf`
2. Uncomment the corresponding `module` block
3. Uncomment the variable and output blocks
4. Set `deploy_to_<cloud> = true` in your tfvars

## Security

- **No API credentials on the fleet**: instances only ever read the Activation ID + Customer ID and pull a pre-staged installer. Qualys API credentials are never stored in the modules, in state, or on your instances.
- **Least privilege**: Each module grants read access only to the two specific secrets, not project/account-wide
- **No VMs created**: This module doesn't create compute resources or open network ports
- **Secrets in native stores**: Enrollment IDs live in each cloud's secret manager, never in Terraform state as plaintext (marked `sensitive`)
- **Idempotent installs**: Scripts check if the agent is running before attempting installation
- **Gradual rollout**: GCP/AWS deployments roll out incrementally, not all-at-once

### Operational note: secret recovery windows

AWS secrets keep a 7-day recovery window and the Azure Key Vault has soft-delete + purge protection enabled. Because the names are deterministic, a `destroy` followed by a fresh `apply` within the retention window can fail on a name collision. In dev, either wait out the window or purge the soft-deleted secret/vault before re-applying.

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
    ├── aws/main.tf          # AWS: Secrets Manager + SSM documents + associations
    ├── azure/main.tf        # Azure: Key Vault + VM access policy + install scripts
    ├── oci/main.tf          # OCI: Vault + defined tag + dynamic group + install script
    └── alicloud/main.tf     # Alibaba: KMS + Cloud Assistant command
```

## Network Requirements

The Qualys agent needs outbound HTTPS (TCP 443) to your Qualys platform. This module does not create firewall rules — ensure your existing network allows this traffic.
