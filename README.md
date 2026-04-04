# Arcane — scaling benchmark

**Arcane** is a multiplayer backend for authoritative world simulation, designed to scale horizontally while keeping replicated game state consistent. Paired with **SpacetimeDB** for persistence, it handles sustained player load and periodic world snapshots. This repository holds a **fixed synthetic workload** and the automation to run it on AWS (or locally), so anyone can verify the same ceilings under the same rules.

---

## Load profile

| Parameter | Value |
|-----------|--------|
| Position updates | 10 Hz per player |
| Actions | 2/s per player |
| Steady duration | 30 s |
| Movement | `spread` |
| Visibility | full mesh (every player sees every entity) |
| NPCs | none (players only) |
| SpacetimeDB-only baseline | physics and logic in-module |
| Arcane + SpacetimeDB | 5 Hz reads per player, 1 Hz batch persist, no persist batch cap, replication on when multiple server processes run |

**Pass:** client error rate **&lt; 1%**, average latency **&lt; 200 ms**. **Ceiling:** highest player count that passes.

Error rate is computed from explicit categories emitted by `arcane-swarm` in `FINAL` lines:
- `timeout`: request timed out before completion.
- `not_delivered`: write/connect failed before payload delivery.
- `http_status`: backend returned non-2xx.
- `transport`: non-timeout network/IO failure.
- `connection_drop`: established stream closed unexpectedly.

Deterministic burst mode is enabled by default for worst-case reproducible runs:
- periodic action burst: every `--burst-period-secs`, a deterministic cohort (`--burst-cohort-percent`) emits `--burst-actions-per-player` actions inside `--burst-window-ms`.
- periodic zone event: every `--zone-event-period-secs`, all players steer toward map center for `--zone-event-window-ms`.

---

## Reference run — AWS (`SingleInstance`)

| | |
|--|--|
| Hardware | `c7i.2xlarge`, 100 GiB gp3, Ubuntu 22.04, single host (Redis, SpacetimeDB in Docker, Arcane, load generator) |
| Run | `20260329_014433` |

| Configuration | Concurrent players (ceiling) |
|---------------|------------------------------|
| SpacetimeDB only | **250** |
| Arcane + SpacetimeDB, single server | **3,750** |
| Arcane + SpacetimeDB, 2–10 servers | **6,000** |

On this run, the SpacetimeDB-only line failed at the next step (500 players) on errors, not average latency alone. Raw outputs: `results/runs/SingleInstance/20260329_014433/`.

---

## Reproduce on AWS

```powershell
cd scripts/cloud
$env:ARCANE_BENCHMARK_GITHUB_TOKEN = (gh auth token).Trim()
.\Run-Benchmark-Aws.ps1 -ArtifactBucket <bucket> -IamInstanceProfileName <profile> -Region us-east-1 -TerminateOnExit
```

For **Redis and SpacetimeDB on separate instances** (driver on a third machine, private VPC networking between them), use **`-Environment DistributedComponents`** and see [scripts/cloud/environments/DistributedComponents/README.md](scripts/cloud/environments/DistributedComponents/README.md).

You can also drive local benchmark parameters from a JSON config file instead of passing many flags:

```powershell
.\scripts\Run-Benchmark.ps1 -ConfigFile .\benchmark.config.json
```

Example `benchmark.config.json`:

```json
{
  "DurationSeconds": 30,
  "FindArcaneCeiling": true,
  "ArcaneClusterCounts": [1, 2, 3, 4, 5, 10],
  "MaxErrRate": 0.01,
  "MaxLatencyMs": 200,
  "BurstEnabled": true,
  "BurstPeriodSecs": 30,
  "BurstCohortPercent": 20,
  "BurstActionsPerPlayer": 10,
  "BurstWindowMs": 500,
  "ZoneEventPeriodSecs": 30,
  "ZoneEventWindowMs": 500
}
```

Pull artifacts for an existing run:

```powershell
.\Sync-AwsBenchmarkResultsFromS3.ps1 -ArtifactBucket <bucket> -RunId 20260329_014433 -Region us-east-1
```

AWS options and IAM expectations: [scripts/cloud/README.md](scripts/cloud/README.md). Local parity run: [REPRODUCIBILITY.md](REPRODUCIBILITY.md). Full parameter list: [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md).

## Tests (PowerShell)

CI runs **Pester** on `tests/*.Tests.ps1` (Windows). Locally:

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path ./tests -CI
```

These are **unit / layout** checks (no AWS, Redis, or Spacetime required).
