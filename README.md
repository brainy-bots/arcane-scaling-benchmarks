# Arcane scaling benchmarks

This repository is a **benchmark harness**: scripts and submodules to run a fixed synthetic load (many simulated “players”) against **SpacetimeDB** and against **Arcane + SpacetimeDB**, then record the highest player counts that still meet clear latency and error thresholds.

**Arcane** (the stack exercised here—not the `arcane-engine` workspace folder) is the multiplayer simulation backend from the [`arcane`](https://github.com/brainy-bots/arcane) repo: an **Arcane manager** hands out cluster addresses, one or more **`arcane-cluster`** processes run the simulation tick loop, **Redis** carries cross-cluster replication when you run more than one cluster, and each cluster **persists a batch to SpacetimeDB** on a fixed schedule. The headless load generator lives in the [`arcane_swarm`](https://github.com/brainy-bots/arcane_swarm) submodule.

---

## Workload and pass criteria

| Parameter | Value |
|-----------|--------|
| Position updates (tick rate) | 10 Hz per player |
| Actions | 2 per second per player |
| Run duration | 30 s steady state (swarm may add warmup) |
| Movement mode | `spread` |
| Visibility | everyone sees everyone |
| Demo / NPC entities | 0 (players only) |
| SpacetimeDB-only | physics in module (`server_physics=true`) |
| Arcane + SpacetimeDB | world read rate 5 Hz per player; persist to SpacetimeDB **1 Hz**; **no** persist batch cap (single request per window, `batch size 0`); **Redis** on when running more than one cluster |

A step **passes** only if **error rate &lt; 1%** and **average latency &lt; 200 ms** (client-observed). The **ceiling** for a configuration is the largest player count at which a step passed.

Full parameter reference: [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md).

---

## Cloud results (AWS, SingleInstance)

Latest full cloud run synced locally:

| Field | Value |
|--------|--------|
| Run ID | `20260329_014433` |
| Environment | `SingleInstance` (one EC2 host runs Redis, SpacetimeDB in Docker, Arcane, and swarm) |
| Default instance type | `c7i.2xlarge` |
| Root volume | 100 GiB gp3 |
| OS image | Ubuntu 22.04 (see `scripts/cloud/environments/SingleInstance/`) |

**Ceilings (players)**

| Backend | Clusters | Ceiling |
|---------|----------|---------|
| SpacetimeDB only | — | **250** |
| Arcane + SpacetimeDB | 1 | **3,750** |
| Arcane + SpacetimeDB | 2 | **6,000** |
| Arcane + SpacetimeDB | 3 | **6,000** |
| Arcane + SpacetimeDB | 4 | **6,000** |
| Arcane + SpacetimeDB | 5 | **6,000** |
| Arcane + SpacetimeDB | 10 | **6,000** |

Source CSVs under `results/runs/SingleInstance/20260329_014433/` (`spacetimedb_only/` and `arcane_plus_spacetimedb/`). SpacetimeDB-only failed the next step at 500 players on that host (non-zero errors at ~30 ms average latency).

---

## Reproduce the benchmark on AWS

Requirements: **AWS CLI**, an EC2 **instance profile** with SSM + S3 upload, your IAM principal with **S3 read** for sync-down, **PowerShell 7** on your machine to launch the orchestrator. Private submodules need **`ARCANE_BENCHMARK_GITHUB_TOKEN`** (or `-GithubToken`).

From `scripts/cloud/`:

```powershell
$env:ARCANE_BENCHMARK_GITHUB_TOKEN = (gh auth token).Trim()
.\Run-Benchmark-Aws.ps1 `
  -ArtifactBucket your-bucket-name `
  -IamInstanceProfileName your-profile-name `
  -Region us-east-1 `
  -TerminateOnExit
```

Results land under `results/runs/SingleInstance/<RunId>/` by default and are also staged under `s3://<bucket>/benchmark-aws/SingleInstance/<RunId>/`.

More options (provision-only, pull from S3 later, extra script args): [scripts/cloud/README.md](scripts/cloud/README.md).

To **download an existing run** from S3 only:

```powershell
.\Sync-AwsBenchmarkResultsFromS3.ps1 -ArtifactBucket your-bucket-name -RunId 20260329_014433 -Region us-east-1
```

Local runs (no AWS) use the same workload via `scripts/Run-Benchmark.ps1`; see [REPRODUCIBILITY.md](REPRODUCIBILITY.md).
