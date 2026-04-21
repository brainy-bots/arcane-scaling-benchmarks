# Arcane — scaling benchmark

Measures how many concurrent players [Arcane Engine](https://github.com/brainy-bots/arcane) can support compared to SpacetimeDB alone, under a fixed synthetic workload with equivalent game logic in both modes.

## What this benchmark measures

Two modes run the **same game logic** (physics, collision detection, buffs, inventory, interactions) — the only difference is the architecture:

| | SpacetimeDB-only | Arcane + SpacetimeDB |
|---|---|---|
| **Physics simulation** | `physics_tick` reducer in WASM module, single machine | `BenchmarkSimulation` in Rust cluster binary, distributed |
| **Collision detection** | O(n^2) in `physics_tick`, single machine | O(n^2) in cluster `on_tick`, distributed across clusters |
| **Buff system** | `use_item` reducer writes buff, `physics_tick` reads it | Client → Cluster → `use_item` reducer, cluster applies locally |
| **Position persistence** | Built-in (Entity table is authoritative) | Cluster → SpacetimeDB at 1 Hz (`set_entities`) |
| **Movement input** | Client → SpacetimeDB HTTP reducer | Client → Cluster WebSocket |
| **Game actions** | Client → SpacetimeDB HTTP reducer | Client → Cluster WebSocket → SpacetimeDB |
| **Entity replication** | SpacetimeDB subscriptions | Redis pub/sub between clusters |

> **Note:** This is a synthetic workload with a kinematic integrator, not a production physics engine. See [docs/BENCHMARK_SCOPE_AND_PHYSICS.md](docs/BENCHMARK_SCOPE_AND_PHYSICS.md) for scope details.

## Physics constants (both modes identical)

| Parameter | Value |
|-----------|-------|
| World size | 5000 x 5000 |
| Movement speed | 600 units/sec |
| Tick rate | 20 Hz (dt = 0.05s) |
| World bounds | 200 – 4800 (clamped) |
| Collision radius | 50 units |
| Collision damage | 10 HP per collision |
| Speed potion buff | 2x speed for 200 ticks (10 seconds) |

## Load profile

| Parameter | Value |
|-----------|-------|
| Position updates | 10 Hz per player |
| Game actions | 2/s per player (pickup_item, use_item, interact) |
| Steady duration | 30 s per step |
| Movement | `spread` (deterministic wander) |
| Visibility | full mesh (every player sees every entity) |

**Pass:** error rate < 1%, average latency < 200 ms. **Ceiling:** highest player count that passes.

**Latency** is measured as *client-perceived latency*: the wall-clock gap between a player's outbound write and the moment the same player's own entity state is reflected back by the server (via Arcane's broadcast frame or SpacetimeDB's `on_update` subscription). Not reducer round-trip time. Not enqueue time. See [REPRODUCIBILITY.md → "What the benchmark actually measures"](REPRODUCIBILITY.md#what-the-benchmark-actually-measures) for why this quantity specifically.

## Current results

Runs on AWS, identical per-node hardware for both backends: all server-side roles (SpacetimeDB, Arcane cluster nodes, Redis, manager) on `t3.large` (2 vCPU burstable, 8 GiB); only the swarm driver on `c7i.2xlarge` (8 vCPU, 16 GiB). This is intentional: the comparison measures architecture, not hardware — both backends get the same per-node budget. The driver is oversized so it doesn't cap the test. Full artifacts (manifests, CSV, per-node diag logs) under `results/runs/AwsArcanePerHost/` and `results/runs/AwsSpacetimeOnly/`. Reproduce with the commands in the [Reproduce on AWS](#reproduce-on-aws) section.

| Scenario | Ceiling (200 ms gate) | Latency at ceiling | Latency at 500 players | Failure mode at next tier |
|---|---|---|---|---|
| **SpacetimeDB-only** (1 node) | 1750 players | 51 ms | 50 ms (flat) | server unreachable at 2000 |
| **Arcane — 2 clusters** | 3500 players | 50 ms | 50 ms (flat) | cluster container OOM at 3750 |
| **Arcane — 4 clusters** | 6000 players | 126 ms | 51 ms (climbing) | latency gate at 6250 (276 ms) |
| **Arcane — 6 clusters** | 6750 players | 196 ms | 51 ms (climbing faster) | latency gate at 7000 (488 ms) |

The ~50 ms latency floor is structural to the 10 Hz tick rate (roughly half the tick period on average) — it's what a real game client experiences, not a backend-specific number. Both backends floor at the same value.

### What these numbers say

- **Identical per-node hardware** — every server-side role (SpacetimeDB, Arcane cluster, Redis, manager) is the same `t3.large`. The comparison isolates architecture from hardware: given one 2 vCPU / 8 GiB box, SpacetimeDB caps at ~1750 players; given four of the same box, Arcane scales to ~6000. Arcane isn't winning by running on beefier hardware; it's winning by *being able to use more boxes at all*.
- **Arcane scales horizontally past SpacetimeDB's architectural ceiling.** SpacetimeDB's single-node design caps it where one node can handle; adding servers doesn't help. Arcane's cluster design keeps adding capacity as clusters are added — up to the current full-mesh replication wall.
- **Diminishing returns past ~4 clusters** under today's full-mesh workload. Per-cluster per-tick CPU is O(P) in total world entity count regardless of N, because every cluster still replicates with every other cluster. 2c → 4c nearly doubles ceiling; 4c → 6c adds only 12%. This is the empirical argument for the affinity-clustering and parallel-pre-encoding work on the roadmap — both lift the O(P) wall by different means.
- **At a 100 ms latency gate** (more characteristic of competitive game-playability than the published 200 ms bar), the ordering shifts: 2c = 3500, 4c = 5750, **6c = 4000** — past the sweet spot, adding clusters *actively hurts* under the current workload. Latency climbs with cluster count because the full-mesh replication tax grows faster than the local-client workload shrinks. Fixed by affinity clustering (partial-mesh by interaction probability) and parallel pre-encoding (distributes the O(P) encode work across cluster cores).

### Next benchmarks on the roadmap

- Rerun 4c and 6c with **parallel pre-encoding** (arcane task #67). Expected: ceilings move up, latency-climb shape flattens.
- **Bigger-instance benchmark** (c7i.4xlarge × 4): validates vertical-scale of cluster capability slots per `clustering-system-requirements.md`.
- **SpacetimeDB on bigger instance** (c7i.4xlarge, c7i.8xlarge): establishes SpacetimeDB's true vertical-scale ceiling for the "where SpacetimeDB's architectural wall actually sits" comparison.

## Project structure

```
crates/
  benchmark-spacetimedb-full/    SpacetimeDB WASM module (SpacetimeDB-only mode)
  benchmark-spacetimedb-persist/ SpacetimeDB WASM module (Arcane mode — persistence only)
  benchmark-cluster/             Arcane cluster binary with BenchmarkSimulation
configs/                         Benchmark run configurations (JSON)
scripts/
  Run-Benchmark.ps1              Main benchmark driver (scenario selected by -ConfigFile)
  Start-BenchmarkDeps.ps1        Start Redis + SpacetimeDB in Docker
arcane/                          Arcane Engine (git submodule, v0.1.0)
arcane_swarm/                    Load generator (git submodule)
```

## Quick start (local)

### Prerequisites
- Docker (for Redis + SpacetimeDB)
- Rust 1.93+ (for building binaries)
- SpacetimeDB CLI (`spacetime`)
- PowerShell 7+ (for benchmark script)

### 1. Start dependencies
```bash
./scripts/start-benchmark-deps.sh
```

### 2. Build binaries
```bash
# Swarm (load generator)
cd arcane_swarm && cargo build --release && cd ..

# SpacetimeDB-only mode: publish the full module
cd crates/benchmark-spacetimedb-full
spacetime publish arcane --yes
cd ../..

# Arcane mode: build cluster binary + manager + publish persist module
cd crates/benchmark-cluster && cargo build --release && cd ../..
cd arcane && cargo build --release --bin arcane-manager --features manager && cd ..
cd crates/benchmark-spacetimedb-persist
spacetime publish arcane --yes
cd ../..
```

### 3. Run benchmark
```powershell
# SpacetimeDB-only ceiling
./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/spacetimedb_only.json

# Arcane + SpacetimeDB (2 clusters) — config carries BenchmarkMode=ArcanePlusSpacetime + ArcaneClusterCount
./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/arcane_plus_spacetimedb.clusters_2.json
```

### Docker Compose (Arcane mode)
```bash
docker compose up -d redis spacetimedb
spacetime publish arcane --yes
docker compose up -d manager cluster1
# Then run swarm against http://127.0.0.1:8081
```

## Reproduce on AWS

See [REPRODUCIBILITY.md](REPRODUCIBILITY.md) for full setup instructions.

```powershell
./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/spacetimedb_only.json -Environment SingleInstance
```

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path ./tests -CI
```

## Documentation

- [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md) — Dated log of every benchmark experiment: hypothesis, setup, result, interpretation, next. Read this to understand how the current numbers came to be, or to avoid re-running dead ends.
- [REPRODUCIBILITY.md](REPRODUCIBILITY.md) — Full local and cloud setup
- [docs/WORKLOAD_PARITY.md](docs/WORKLOAD_PARITY.md) — Side-by-side analysis of what each mode computes per tick, proving both do equivalent work
- [docs/BENCHMARK_SCOPE_AND_PHYSICS.md](docs/BENCHMARK_SCOPE_AND_PHYSICS.md) — What's measured and what's not
- [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md) — Fixed workload parameters
- [docs/MODULE_INTERACTIONS.md](docs/MODULE_INTERACTIONS.md) — Script and module dependencies

## License

arcane-scaling-benchmarks is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0). See [LICENSE](LICENSE) for the full text. The Arcane engine and swarm driver this repository benchmarks are under the same license; see the [arcane](https://github.com/brainy-bots/arcane) and [arcane_swarm](https://github.com/brainy-bots/arcane_swarm) repositories.

If you want to ship proprietary/closed-source software that links any of these, contact the copyright holder for a commercial license.

For licensing inquiries: martin.mba@gmail.com
