# AWS benchmark automation (`infra/aws`)

This directory contains the **run and collect** PowerShell for AWS benchmarks. Provisioning and teardown are owned exclusively by Terraform — see **[`../terraform/aws_benchmark`](../terraform/aws_benchmark/README.md)**.

## Split of responsibilities

| Phase | Tool |
|-------|------|
| Provision all AWS resources (EC2, security group, S3, IAM) | **Terraform** (`terraform apply`) |
| Run the benchmark workload on the fleet | PowerShell (this directory) |
| Collect result artifacts from S3 | PowerShell (this directory) |
| Destroy all AWS resources | **Terraform** (`terraform destroy`) |

There is **no PowerShell path** to create or destroy AWS resources. Keeping that invariant means anyone starting from an empty AWS account can reproduce the benchmark with one `terraform apply`.

## Scripts

| Script | Purpose |
|--------|---------|
| **`Run-Benchmark-Aws.ps1`** | Drives a benchmark run over SSM on an already-provisioned fleet. Reads the Terraform-produced state JSON via `-StatePath`. Clones the repo on the driver, builds, runs `Run-Benchmark.ps1`, uploads results to S3, and optionally syncs results locally. |
| **`Collect-AwsBenchmarkResults.ps1`** | Checks drivers for in-flight SSM commands, then pulls every run folder from S3 into `results/runs/<Environment>/<RunId>/`. |
| **`Sync-AwsBenchmarkResultsFromS3.ps1`** | Pulls a single `-RunId` (or `-S3Uri`) from S3 into `results/runs/...`. |

## Topologies

Two topologies are supported, matching the `topology` Terraform variable:

- **`AwsSpacetimeOnly`** — SpacetimeDB (Docker) + driver. Security group allows TCP 3000 in-group. Benchmark runs in `SpacetimeOnly` mode.
- **`AwsArcanePerHost`** — Redis + SpacetimeDB + arcane-manager + N × arcane-cluster + driver, each on its own EC2. Stable cluster UUIDs and instance layout are stored in the Terraform state output. Repeat runs with `ArcaneClusterCount ≤ MaxArcaneClusters` without reprovisioning.

Per-topology run code lives under `topologies/<Topology>/RemoteBenchmark.ps1`.

## End-to-end flow

```bash
# 1. Provision
cd infra/terraform/aws_benchmark
terraform init
terraform apply -var=topology=AwsSpacetimeOnly
#   or: terraform apply -var=topology=AwsArcanePerHost -var=arcane_cluster_count=2
```

```powershell
# 2. Export state JSON (run from benchmark repo root)
terraform -chdir=infra/terraform/aws_benchmark output -json benchmark_state |
  Set-Content -LiteralPath .\.benchmark-aws-terraform.json -Encoding utf8

# 3. Wait for all instances to show Online in SSM (user-data takes several minutes).

# 4. Run the benchmark
pwsh ./infra/aws/Run-Benchmark-Aws.ps1 `
  -StatePath .\.benchmark-aws-terraform.json `
  -ConfigFile .\configs\<your-config>.psd1

# 5. Collect results (optional; Run-Benchmark-Aws.ps1 syncs by default)
pwsh ./infra/aws/Collect-AwsBenchmarkResults.ps1
```

```bash
# 6. Destroy every AWS resource
cd infra/terraform/aws_benchmark
terraform destroy
```

## Prerequisites

- AWS CLI configured so `aws sts get-caller-identity` succeeds.
- Your identity needs `s3:GetObject` (and usually `s3:ListBucket`) on the artifact bucket to download results unless you use `-SkipLocalResultsDownload`.
- Submodules in this repo point at public GitHub URLs; a token is only needed for private forks (`ARCANE_BENCHMARK_GITHUB_TOKEN` or `-GithubToken`).

## Adding a topology

1. Add a subdirectory under `topologies/` (for example `topologies/AwsFoo/`) with a `RemoteBenchmark.ps1` defining `Invoke-AwsFooRemoteBenchmark`.
2. Append the folder name to `$script:AwsBenchmarkKnownEnvironments` in [`lib/Import-AwsBenchmarkEnvironment.ps1`](lib/Import-AwsBenchmarkEnvironment.ps1).
3. Register the `Invoke-*` function in [`lib/AwsBenchmarkEnvironmentRegistry.ps1`](lib/AwsBenchmarkEnvironmentRegistry.ps1).
4. Add matching EC2 / security-group resources to the Terraform module and emit the new instance IDs under `output "benchmark_state"` so `RemoteBenchmark.ps1` can consume them.
