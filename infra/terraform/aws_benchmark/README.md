# AWS benchmark stack (Terraform)

Single source of truth for provisioning and tearing down AWS benchmark environments. `terraform apply` creates every resource the run needs (EC2 fleet, security group, S3 artifact bucket, IAM role + instance profile). `terraform destroy` removes all of them.

The PowerShell scripts under `infra/aws/` (`Run-Benchmark-Aws.ps1`, per-topology `RemoteBenchmark.ps1`, `Collect-AwsBenchmarkResults.ps1`, `Sync-AwsBenchmarkResultsFromS3.ps1`) only *run* the benchmark and *collect* results on the fleet that Terraform provisioned.

## Prerequisites

- Terraform **>= 1.3**
- AWS credentials with permissions for EC2, IAM, S3, SSM
- **`.terraform.lock.hcl`** is committed for reproducible `terraform init`.

## Validate (no AWS resources touched)

From `infra/terraform/aws_benchmark`:

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

## End-to-end flow

```bash
cd infra/terraform/aws_benchmark

# 1. Provision
terraform init
terraform apply -var=topology=AwsSpacetimeOnly
#   or: terraform apply -var=topology=AwsArcanePerHost -var=arcane_cluster_count=2
```

```powershell
# 2. Export the state JSON that Run-Benchmark-Aws.ps1 consumes (run from benchmark repo root)
terraform -chdir=infra/terraform/aws_benchmark output -json benchmark_state |
  Set-Content -LiteralPath .\.benchmark-aws-terraform.json -Encoding utf8

# 3. Wait until every instance shows Online in SSM (user-data takes a few minutes).

# 4. Run the benchmark
pwsh ./infra/aws/Run-Benchmark-Aws.ps1 `
  -StatePath ./.benchmark-aws-terraform.json `
  -ConfigFile ./configs/<your-config>.psd1
```

```bash
# 5. Tear everything down
terraform destroy
```

Use a separate Terraform workspace per topology; do not flip `-var=topology` on the same state.

## Variables

| Name | Default | Notes |
|------|---------|-------|
| `topology` | `AwsSpacetimeOnly` | `AwsArcanePerHost` for Redis + Spacetime + manager + N clusters + driver |
| `arcane_cluster_count` | `2` | AwsArcanePerHost only, 1–32 |
| `instance_type` | `c7i.2xlarge` | Driver node |
| `data_instance_type` | `t3.large` | Spacetime / Redis / manager / cluster nodes |
| `root_volume_gib` | `100` | gp3 root volume per instance |
| `artifact_prefix` | `benchmark-aws` | S3 key prefix for run artifacts |
| `remote_provision_profile` | `Full` | `Full` or `SpacetimeOnly` (AwsArcanePerHost requires `Full`) |
| `subnet_id` | *(auto)* | Default: first subnet of the default VPC |
| `key_name` | *(none)* | Optional EC2 key pair |
| `s3_bucket_force_destroy` | `true` | Keep true so `terraform destroy` succeeds with run artifacts in the bucket |

## Driver discovery

Driver instances carry `ArcaneBenchmarkEnvironment` and `ArcaneBenchmarkRole=driver` tags for `Collect-AwsBenchmarkResults.ps1`.
