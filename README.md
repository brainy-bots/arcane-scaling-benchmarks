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

Most recent run: `results/runs/AwsArcanePerHost/20260426_060905/`. Full artifacts (manifest, per-tier `cluster_stats`, per-node diag logs) under that path. Reproduce with the commands in the [Reproduce on AWS](#reproduce-on-aws) section.

### Headline number

**7,250 concurrent players, full-mesh replication, on 4 × c7i.2xlarge cluster nodes**, supporting fleet on c7i.2xlarge (Redis, SpacetimeDB persistence node, Arcane manager, swarm driver). 182 ms client-perceived latency at the ceiling tier; the next tier (7,500 players) fails at 416 ms. All tiers up to and including 7,250 had `swarm_pass = true` and zero errors across 1.2M+ measured operations per tier.

### Per-tier sweep

| Players | lat_avg_ms | drain_avg_ms | cluster lagged_total | swarm_pass |
|---|---|---|---|---|
| 5,750 | 116 | 0.11 | 53,315 | ✅ |
| 6,000 | 105 | 0.24 | 113,920 | ✅ |
| 6,250 | 120 | 0.28 | 170,170 | ✅ |
| 6,500 | 121 | 0.30 | 221,754 | ✅ |
| 6,750 | 135 | 0.34 | 271,026 | ✅ |
| 7,000 | 147 | 0.37 | 318,327 | ✅ |
| **7,250** | **182** | **0.39** | **363,663** | **✅** |
| 7,500 | 416 | 0.52 | 405,510 | ❌ |

`lat_avg_ms` is client-perceived round-trip latency (player's outbound write → same player's own entity reflected back via the cluster's broadcast). `drain_avg_ms` is the on-driver portion (frame arrival → decode → match), measured driver-internally so it carries no clock-sync error. The remaining `lat_avg_ms − drain_avg_ms` is everything between: cluster ingest, tick alignment, server-side processing, network transit, and any kernel-level scheduling.

### What we measured (every dimension that matters)

| Dimension | This run | Notes |
|---|---|---|
| Player count | 7,250 (ceiling) | Highest tier where `swarm_pass = true` and `lat_avg_ms < 200` |
| Per-entity broadcast state | 56 bytes | `entity_id` (16) + `cluster_id` (16) + `position` Vec3<f32> (12) + `velocity` Vec3<f32> (12). `user_data: Vec<u8>` is empty in this benchmark — real games would carry rotation, health/armor, equipment, animation state, etc. inside it |
| Server tick rate | 20 Hz | Cluster broadcasts at 20 Hz; client movement-write at 10 Hz |
| Visibility model | Full mesh | Every connected player receives every world entity each broadcast — no area-of-interest filtering, no spatial culling, no relevance system |
| Transport | WebSocket over TCP | Game-state replication uses TCP under the hood (with all of TCP's head-of-line and retransmit behavior). Pluggable transport (QUIC, UDP) tracked in [arcane#43](https://github.com/brainy-bots/arcane/issues/43) |
| Time dilation | None | Tick rate is a constant 20 Hz regardless of load — no game-time stretching as load rises |
| Cluster hardware | 4 × c7i.2xlarge (8 vCPU, 16 GiB) | Sustained NIC ≈ 3 Gbps per instance under our broadcast workload (well below the c7i.2xlarge 12.5 Gbps burst headline) |
| Support hardware | c7i.2xlarge each for Redis, SpacetimeDB persistence, Arcane manager, swarm driver | Commodity AWS, single-region |
| Cluster CPU at ceiling | `last_tick_us` ≈ 21 ms / 50 ms tick budget = ~58% utilized | Cluster simulation has substantial headroom — the wall isn't compute |
| Bottleneck | Cluster outbound NIC bandwidth | `broadcast_lagged_events` accumulates monotonically with player count; on 7,500 the cluster wants to push ~9 GB/s of fan-out, NIC sustains ~3 Gbps, the gap shows up as lagged broadcasts and TCP send-buffer backpressure |
| Per-entity state size: realistic? | Conservative | We do not yet measure with the heavier per-entity state typical of shipped shooters (rotation, stats, equipment, animation flags) |
| Tick rate: realistic? | Low end | 20 Hz matches Apex Legends' published tick (long criticized as too low for competitive); modern AAA shooters typically run 30–60 Hz; competitive Counter-Strike runs 64 or 128 Hz |

### Where today's number sits relative to publicly-known industry data

The two variables that most directly drive replication load — **per-entity state size on the wire** and **server tick rate** — are the right axes to compare on. Tick rate is publicly disclosed by most studios. **Per-entity state size is not generally publicly disclosed** for shipped commercial games; community reverse-engineering work suggests typical AAA shooter entities sit in the 80–200 byte range on the wire (Source-engine SDK is the most-studied open reference point), but those are not primary-source numbers and we don't cite them as such here.

| Game / engine | Player cap per server / match | Server tick rate | Per-entity replication state | Visibility | Notable architecture | Source |
|---|---|---|---|---|---|---|
| Counter-Strike (Valve official servers) | 10 (5v5) typical | 64 Hz | not publicly disclosed | match-bound, no AOI | dedicated game server | [Valve Source SDK docs — server tickrate](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking) |
| Counter-Strike (FACEIT / tournaments) | 10 | 128 Hz | not publicly disclosed | same | same | [FACEIT support — 128-tick servers](https://support.faceit.com/) |
| Apex Legends | 60 | 20 Hz | not publicly disclosed | AOI / relevance | dedicated per-match | [Respawn community responses + Battle(non)sense analysis, widely cited 2019–2020](https://www.youtube.com/c/Battlenonsense) |
| Battlefield 2042 | 128 | 30–60 Hz (platform-dependent) | not publicly disclosed | spatial relevance | dedicated per-match | [DICE — Battlefield 2042 platform specifications](https://www.ea.com/games/battlefield/battlefield-2042) |
| PlanetSide 2 | up to 2,000 / continent (advertised) | ~25–30 Hz (community-measured) | not publicly disclosed | aggressive AOI; player only sees ~nearest N | continent server cluster | [SOE / Daybreak marketing for continent caps](https://www.planetside2.com/) |
| Star Citizen | ~100 / server (current target) | game tick ~30 Hz | not publicly disclosed; entity model unusually heavy (multi-subsystem ships, persistent inventory, etc.) | full visibility within shard | working toward "server meshing" (functionally similar to Arcane clustering) | [CIG roadmap and dev updates, 2024–2025](https://robertsspaceindustries.com/roadmap) |
| EVE Online | up to ~7,548 unique pilots in one battle (B-R5RB, 2014) | nominal ~1 Hz simulation tick within a system | not publicly disclosed | no AOI within a system | single-threaded per system; **time dilation** when load exceeds capacity | [CCP dev blog on TiDi](https://www.eveonline.com/news/view/the-bloodbath-of-b-r5rb), [Eurogamer / Polygon coverage](https://www.eurogamer.net/largest-online-multiplayer-battle-history-eve-online) |
| **Arcane (this run)** | **7,250 / 4-cluster setup** | **20 Hz** | **56 B (lean — `user_data` empty)** | **Full mesh, no AOI** | **horizontal clustering across commodity AWS** | this repo, run `20260426_060905` |

**On the two replication variables:**

- **Tick rate (frequency):** the load on every link in the pipeline scales linearly. Going from 20 Hz to 30 Hz means 1.5× the broadcasts per second, 1.5× the cluster encode CPU, 1.5× the NIC bandwidth. We sit at the low end of the live-shooter range; a 30 Hz sweep is on the roadmap and is expected to lower the player-count ceiling proportionally.
- **Per-entity state size:** broadcast bandwidth scales linearly with bytes-per-entity. Going from our 56 B to a more realistic ~140 B (rotation + health + equipment + animation flags packed into `user_data`) is 2.5× the cluster outbound bandwidth, which matters because that's the binding bottleneck today. We expect the realistic-state ceiling to be lower than 7,250 by roughly the bandwidth ratio. That measurement is on the roadmap as a sibling-config experiment.

The comparison Arcane fits into:

- **Player count, full mesh, no AOI, no time dilation, on commodity AWS**: 7,250 in this run is, to our knowledge, in the range that ships only with explicit AOI tricks or time dilation in production multiplayer games.
- **Tick rate caveat**: at 20 Hz we match the lower end of the live-shooter range (Apex). To match competitive-shooter expectations (64+ Hz), tick rate has to come up — directly increases per-second broadcast volume, expected to lower the player-count ceiling proportionally.
- **State size caveat**: the per-entity payload in this benchmark is intentionally lean (56 bytes, no `user_data`). Shipping games carry richer per-entity state inside their replication payload; that work is on the roadmap as a sibling-config measurement.

### Why the ceiling is where it is

The cluster has CPU headroom at the ceiling — `last_tick_us ≈ 21 ms` vs the 50 ms tick budget. The wall is the cluster's outbound NIC.

At 7,500 players × 4 clusters with 1,437 subscribers per cluster, each cluster's broadcast pipeline wants to send `1,437 subscribers × ~322 KB per broadcast (5,750 entities × 56 B) × 20 Hz ≈ 9.2 GB/s`. The c7i.2xlarge instance class sustains roughly 3 Gbps of NIC throughput on this workload pattern (its 12.5 Gbps headline is burst, not sustained). The gap shows up as `broadcast_lagged_events` — tokio's broadcast channel emits these when a per-subscriber send queue falls 256+ messages behind, after which 256 broadcasts' worth of bytes get dropped for that subscriber. At 7,500 players, ~67% of the cluster's intended outbound bytes never reach the wire, which is what tips the latency past the gate.

This is the **full-mesh replication wall on the current hardware class.** It is not a fundamental ceiling for Arcane — the candidate moves to push past it are documented:

- **Network-optimized instances** (`c6in.2xlarge`, `c5n.2xlarge`, `c7gn.*`) — same vCPU/RAM as today, ~5× the sustained NIC. Direct lift on the binding bottleneck.
- **More clusters** (`arcaneperhost.clusters_8.tfvars`) — halves per-cluster fan-out demand. Inter-cluster Redis traffic stays in the MB/s range and is not the next wall.
- **Per-message-deflate compression on WebSocket** — typical 30–50% bandwidth reduction on postcard-encoded broadcast payloads; ~once-per-broadcast CPU cost when paired with the cluster's per-broadcast encode cache.
- **Quantize position+velocity** from f32 to fixed-point or f16 — ~30% cut to per-entity bytes, no architectural impact.
- **Delta-only broadcasts** — only changed entities per tick rather than full snapshots ([arcane#30](https://github.com/brainy-bots/arcane/issues/30)).
- **Affinity clustering** — partial-mesh by predicted interaction probability instead of full mesh. The architectural answer; lifts the O(P²) wall fundamentally rather than pushing it. The product premise.
- **Pluggable transport** — moving the broadcast wire from TCP to QUIC or raw UDP eliminates head-of-line blocking and gives meaningfully better tail latency under loss ([arcane#43](https://github.com/brainy-bots/arcane/issues/43)).

### What this number is *not*

- **Not a measurement at AAA-shooter tick rate.** Tick rate is configurable; raising it from 20 Hz toward 30–60 Hz will lower the player-count ceiling. We have not yet run the tick-rate sweep.
- **Not a measurement at AAA-shooter per-entity state.** The 56 B payload is conservative. Adding rotation + health + equipment + animation flags into `user_data` (~80–100 B more) is a planned sibling experiment.
- **Not a measurement against AOI / interest-managed visibility.** This is full mesh — every player sees every entity. Most large-player-count shipping games do not run this way; they cull aggressively. Comparing Arcane's full-mesh ceiling to PlanetSide 2's 2,000-player AOI-managed continent isn't apples-to-apples; the workloads differ by 10×–100× in per-cluster fan-out.
- **Not validated on cluster counts other than 4 with this hardware.** The 2-cluster and 6-cluster numbers from earlier on `t3.large` cluster nodes (in the journal) are historical. They have not been re-run on `c7i.2xlarge` clusters with the current swarm-side measurement fix; comparison across cluster counts requires re-measurement.

### Predecessor results (historical)

Earlier runs on `t3.large` cluster nodes — same fleet roles, smaller hardware — and with a swarm driver that bottlenecked on broadcast decode at high player counts. Those numbers (1,750 SpacetimeDB-only single node; 3,500 / 6,000 / 6,750 for Arcane 2c / 4c / 6c) are preserved in [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md) and the corresponding `results/runs/` artifacts. Tonight's run on `c7i.2xlarge` clusters with the swarm-side decode-cache fix supersedes the 4-cluster number; the others have not yet been re-measured at the new hardware class.

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
