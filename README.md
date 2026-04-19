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

- [REPRODUCIBILITY.md](REPRODUCIBILITY.md) — Full local and cloud setup
- [docs/WORKLOAD_PARITY.md](docs/WORKLOAD_PARITY.md) — Side-by-side analysis of what each mode computes per tick, proving both do equivalent work
- [docs/BENCHMARK_SCOPE_AND_PHYSICS.md](docs/BENCHMARK_SCOPE_AND_PHYSICS.md) — What's measured and what's not
- [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md) — Fixed workload parameters
- [docs/MODULE_INTERACTIONS.md](docs/MODULE_INTERACTIONS.md) — Script and module dependencies

## License

arcane-scaling-benchmarks is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0). See [LICENSE](LICENSE) for the full text. The Arcane engine and swarm driver this repository benchmarks are under the same license; see the [arcane](https://github.com/brainy-bots/arcane) and [arcane_swarm](https://github.com/brainy-bots/arcane_swarm) repositories.

If you want to ship proprietary/closed-source software that links any of these, contact the copyright holder for a commercial license.

For licensing inquiries: martin.mba@gmail.com
