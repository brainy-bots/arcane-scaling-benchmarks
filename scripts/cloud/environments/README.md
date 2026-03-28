# AWS benchmark environments (topologies)

Each subdirectory is one **environment**: a way to provision infrastructure and run the benchmark remotely.

## Layout (per environment)

| File | Role |
|------|------|
| `Setup.ps1` | Dot-sourced. Defines `Initialize-<EnvName>AwsBenchmarkEnvironment` (or your naming convention). Returns a **state** object used by the other steps. |
| `RemoteBenchmark.ps1` | Dot-sourced. Defines `Invoke-<EnvName>AwsRemoteBenchmark` — typically SSM or SSH steps that end with `Run-Benchmark.ps1` and artifact upload. |
| `Cleanup.ps1` | Dot-sourced. Defines `Remove-<EnvName>AwsBenchmarkEnvironment` — terminate instances, delete security groups this run created, etc. |

Shared helpers live in **`../Common/AwsHelpers.ps1`**.

## Registering a new environment

1. Copy `SingleInstance/` to a new folder (e.g. `DistributedComponents/`).
2. Implement setup / remote run / cleanup for that topology.
3. Append the folder name to **`$script:AwsBenchmarkKnownEnvironments`** in [`../Tools/Import-AwsBenchmarkEnvironment.ps1`](../Tools/Import-AwsBenchmarkEnvironment.ps1).
4. Ensure **`Run-Benchmark-Aws.ps1`** dot-sources your three scripts under `environments/<Name>/` (alongside **`Common/AwsHelpers.ps1`** at script scope). Update **`Setup-AwsBenchmark.ps1`** / **`Cleanup-AwsBenchmark.ps1`** if they need new `switch` arms for `Initialize-*` / `Remove-*`.

The **state object** should always include an **`Environment`** property matching the folder name so cleanup scripts can branch correctly.

## Current environments

| Name | Description |
|------|-------------|
| `SingleInstance` | One EC2 host: Docker (Redis + SpacetimeDB), Rust builds, swarm + Arcane, then `Run-Benchmark.ps1` via SSM. |
