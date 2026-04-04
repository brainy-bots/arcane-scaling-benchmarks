# AWS benchmark environments (topologies)

Each subdirectory is one **environment**: a way to provision infrastructure and run the benchmark remotely.

## Layout (per environment)

| File | Role |
|------|------|
| `Setup.ps1` | Dot-sourced. Defines `Initialize-<EnvName>AwsBenchmarkEnvironment` (or your naming convention). Returns a **state** object used by the other steps. |
| `RemoteBenchmark.ps1` | Dot-sourced. Defines `Invoke-<EnvName>AwsRemoteBenchmark` — typically SSM or SSH steps that end with `Run-Benchmark.ps1` and artifact upload. |
| `Cleanup.ps1` | Dot-sourced. Defines `Remove-<EnvName>AwsBenchmarkEnvironment` — terminate instances, delete security groups this run created, etc. |

Shared helpers live in **`../Common/AwsHelpers.ps1`**. Environment routing (which `Initialize-*` / `Invoke-*` / `Remove-*` to call) is centralized in **`../Common/AwsBenchmarkEnvironmentRegistry.ps1`** — add a `switch` arm there when you introduce a new topology.

## Registering a new environment

1. Copy `SingleInstance/` to a new folder (e.g. `DistributedComponents/`).
2. Implement setup / remote run / cleanup for that topology.
3. Append the folder name to **`$script:AwsBenchmarkKnownEnvironments`** in [`../Tools/Import-AwsBenchmarkEnvironment.ps1`](../Tools/Import-AwsBenchmarkEnvironment.ps1).
4. Add **`Initialize-*`**, **`Invoke-*`**, and **`Remove-*`** entries for your folder name in [`../Common/AwsBenchmarkEnvironmentRegistry.ps1`](../Common/AwsBenchmarkEnvironmentRegistry.ps1). **`Run-Benchmark-Aws.ps1`** already dot-sources every file under `environments/<Name>/` plus that registry.

The **state object** should always include an **`Environment`** property matching the folder name so cleanup scripts can branch correctly.

## Current environments

| Name | Description |
|------|-------------|
| `SingleInstance` | One EC2 host: Docker (Redis + SpacetimeDB), Rust builds, swarm + Arcane, then `Run-Benchmark.ps1` via SSM. |
| `DistributedComponents` | Three EC2 instances: Redis (Docker), SpacetimeDB (Docker), and a **driver** that builds and runs `Run-Benchmark.ps1` against **private VPC IPs** (real inter-VM networking for deps). See [DistributedComponents/README.md](DistributedComponents/README.md). |
