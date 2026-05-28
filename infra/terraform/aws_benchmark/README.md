# AWS benchmark stack (Terraform)

Single source of truth for provisioning and tearing down AWS benchmark environments. `terraform apply` creates every resource the run needs (EC2 fleet, security group, S3 artifact bucket, IAM role + instance profile). `terraform destroy` removes all of them.

**You should not need to run Terraform directly.** The single-command scripts handle it:

```powershell
# Provision + run + cleanup (all-in-one)
pwsh ./infra/aws/Run-Repro-Aws-Controller.ps1 -PlanFile ./plans/headline-13500.toml -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:v0.3.0

# Cleanup only (if needed separately)
pwsh ./infra/aws/Cleanup-Benchmark-Aws.ps1
```

Override the fleet topology with `-Tfvars <name>`. Available `.tfvars` files are in this directory.

## Validate (no AWS resources touched)

From `infra/terraform/aws_benchmark`:

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

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
