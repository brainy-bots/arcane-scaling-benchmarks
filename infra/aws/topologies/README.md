# AWS benchmark topologies

Each subdirectory is one **topology** (`Environment` in PowerShell, `topology` in Terraform). Provisioning and teardown are owned by Terraform (see [`../../terraform/aws_benchmark`](../../terraform/aws_benchmark/)). The **pre-built benchmark image** (see the [Dockerfile](../../../Dockerfile)) carries every binary, WASM module, and orchestration script — cloud nodes only `docker pull && docker run`.

## Layout per topology

| File | Role |
|------|------|
| `RemoteBenchmark.ps1` | Dot-sourced. Defines `Invoke-<Topology>RemoteBenchmark` — the SSM steps that docker-run each role container and upload results to S3. |

Shared helpers live in [`../lib/AwsHelpers.ps1`](../lib/AwsHelpers.ps1). Routing (which `Invoke-*` to call for a given `Environment` in state) is centralized in [`../lib/AwsBenchmarkEnvironmentRegistry.ps1`](../lib/AwsBenchmarkEnvironmentRegistry.ps1).

## Current topologies

| Name | Description |
|------|-------------|
| `AwsSpacetimeOnly` | Two EC2 instances: SpacetimeDB + driver. SpacetimeDB runs the benchmark image as `spacetime start`, then publishes the `Full` benchmark module into itself via `benchmark-publish-module`. Driver runs the image as `run-benchmark` with a SpacetimeDB-only config. Security group allows TCP 3000 within the group. |
| `AwsArcanePerHost` | Redis + SpacetimeDB + arcane-manager + N × benchmark-cluster + driver, each on its own EC2. Redis uses the stock `redis:7-alpine` image; every other node runs the benchmark image with a role command (`spacetime start`, `arcane-manager`, `benchmark-cluster`, `run-benchmark`). Stable cluster UUIDs and instance layout are produced by Terraform and read by `Run-Benchmark-Aws.ps1`. Repeat runs with `ArcaneClusterCount ≤ MaxArcaneClusters` without reprovisioning. |

## Adding a topology

1. Add a subdirectory here with `RemoteBenchmark.ps1` defining `Invoke-<Topology>RemoteBenchmark` — each step is a `docker pull && docker run <image>:<tag> <role>` sequence.
2. Append the folder name to `$script:AwsBenchmarkKnownEnvironments` in [`../lib/Import-AwsBenchmarkEnvironment.ps1`](../lib/Import-AwsBenchmarkEnvironment.ps1).
3. Register the `Invoke-*` function for your topology in [`../lib/AwsBenchmarkEnvironmentRegistry.ps1`](../lib/AwsBenchmarkEnvironmentRegistry.ps1).
4. Update the Terraform module to accept the new topology (`variable "topology"` validation), create matching EC2 / security-group resources, and emit any new instance IDs in `output "benchmark_state"` so `RemoteBenchmark.ps1` can consume them.
5. If a new role is needed in the image, add the binary or script to the Dockerfile so the topology scripts can invoke it by command.
