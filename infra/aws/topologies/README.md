# AWS benchmark topologies

Each subdirectory is one **topology** (named `Environment` in PowerShell and `topology` in Terraform). Provisioning is owned by Terraform (see [`../../terraform/aws_benchmark`](../../terraform/aws_benchmark/)); this directory only holds the PowerShell that drives the benchmark workload over SSM after the fleet is up.

## Layout per topology

| File | Role |
|------|------|
| `RemoteBenchmark.ps1` | Dot-sourced. Defines `Invoke-<Topology>RemoteBenchmark` — the SSM steps that end with `Run-Benchmark.ps1` and artifact upload. |

Setup and cleanup live in Terraform, not here. There is no `Setup.ps1` or `Cleanup.ps1`.

Shared helpers live in [`../lib/AwsHelpers.ps1`](../lib/AwsHelpers.ps1). Routing (which `Invoke-*` to call for a given `Environment` in state) is centralized in [`../lib/AwsBenchmarkEnvironmentRegistry.ps1`](../lib/AwsBenchmarkEnvironmentRegistry.ps1).

## Current topologies

| Name | Description |
|------|-------------|
| `AwsSpacetimeOnly` | Two EC2 instances: SpacetimeDB (Docker) + driver. Security group allows TCP 3000 within the group. Remote run uses `SpacetimeOnly` benchmark mode. |
| `AwsArcanePerHost` | Redis + SpacetimeDB + arcane-manager + N × arcane-cluster + driver, each on its own EC2. Stable cluster UUIDs and instance layout are produced by Terraform and read by `Run-Benchmark-Aws.ps1`. Repeat runs with `ArcaneClusterCount ≤ MaxArcaneClusters` without reprovisioning. The instance profile (provisioned by Terraform) grants the driver S3 put and manager/cluster nodes S3 get on `s3://<bucket>/<prefix>/bench-binaries/<setup RunId>/`. |

## Adding a topology

1. Add a subdirectory here with `RemoteBenchmark.ps1` defining `Invoke-<Topology>RemoteBenchmark`.
2. Append the folder name to `$script:AwsBenchmarkKnownEnvironments` in [`../lib/Import-AwsBenchmarkEnvironment.ps1`](../lib/Import-AwsBenchmarkEnvironment.ps1).
3. Register the `Invoke-*` function for your topology in [`../lib/AwsBenchmarkEnvironmentRegistry.ps1`](../lib/AwsBenchmarkEnvironmentRegistry.ps1).
4. Update the Terraform module to accept the new topology (`variable "topology"` validation), create matching EC2 / security-group resources, and emit any new instance IDs in `output "benchmark_state"` so `RemoteBenchmark.ps1` can consume them.
