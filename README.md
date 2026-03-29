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

Pull artifacts for an existing run:

```powershell
.\Sync-AwsBenchmarkResultsFromS3.ps1 -ArtifactBucket <bucket> -RunId 20260329_014433 -Region us-east-1
```

AWS options and IAM expectations: [scripts/cloud/README.md](scripts/cloud/README.md). Local parity run: [REPRODUCIBILITY.md](REPRODUCIBILITY.md). Full parameter list: [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md).
