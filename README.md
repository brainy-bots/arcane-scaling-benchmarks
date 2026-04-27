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
| Cluster simulation tick rate | 30 Hz at the headline standard (env-tunable; 20 Hz incumbent-band reference also published) |
| World bounds | 200 – 4800 (clamped) |
| Collision radius | 50 units |
| Collision damage | 10 HP per collision |
| Speed potion buff | 2× speed for 10 seconds wall-clock (tick count derived from cluster tick rate) |

## Load profile

| Parameter | Value |
|-----------|-------|
| Position updates | derived from cluster tick rate (30 Hz at headline; matches cluster so server isn't input-starved) |
| Game actions | 2/s per player (pickup_item, use_item, interact) |
| Per-entity replicated state | ~150 B realistic (UserDataBytes=100 in JSON-envelope) / ~50 B lean baseline |
| Steady duration | 30 s per step |
| Movement | `spread` (deterministic wander) |
| Visibility | full mesh (every player sees every entity) |
| Broadcast strategy | velocity-based dead reckoning (entities skipped when velocity unchanged within wire quantization step; periodic resync sweep) |

**Pass:** error rate < 1%, average latency < 100 ms (headline standard) or < 200 ms (incumbent-band reference). **Ceiling:** highest player count that passes.

**Latency** is measured as *client-perceived latency*: the wall-clock gap between a player's outbound write and the moment the same player's own entity state is reflected back by the server (via Arcane's broadcast frame or SpacetimeDB's `on_update` subscription). Not reducer round-trip time. Not enqueue time. See [REPRODUCIBILITY.md → "What the benchmark actually measures"](REPRODUCIBILITY.md#what-the-benchmark-actually-measures) for why this quantity specifically.

## Current results

Headline measurements: `results/runs/AwsArcanePerHost/20260426_125527/` (Run A, 20 Hz / 200 ms baseline), `20260427_004902/` (Run F, 30 Hz / 100 ms realistic — the publishing standard), and `20260427_003453/` (Run D', 30 Hz / 100 ms lean). Full artifacts (manifest, per-tier `cluster_stats`, per-node diag logs) under each path. Reproduce with the commands in the [Reproduce on AWS](#reproduce-on-aws) section. Full experimental chain in [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md).

### Headline number

**4,750 concurrent players at 30 Hz cluster tick / 100 ms latency gate, with realistic per-entity payload and full-mesh replication, on 4 × c7i.2xlarge cluster nodes**, supporting fleet on c7i.2xlarge (Redis, SpacetimeDB persistence node, Arcane manager, swarm driver). 84 ms client-perceived latency at the ceiling tier; the next tier (5,000 players) fails at 101 ms. All tiers up to 4,750 had `swarm_pass = true` and zero errors.

This is the **MMO-class workload measurement at the new Arcane headline standard** (30 Hz / 100 ms). Incumbent MMOs publish 5–20 Hz tick rates with 200 ms playability gates (EVE 1 Hz with time dilation; WoW/FFXIV/Albion in the 5–20 Hz band). Arcane sustains **30 Hz** on commodity AWS — strictly above the incumbent band — and at a **100 ms** gate that is tighter than the incumbent 200 ms. Both the tick rate and the latency gate are stricter than what incumbents publish against; the 4,750 player count is achieved against those tighter constraints.

This is the **no-server-physics measurement.** Cluster simulation is kinematic motion + radius-based collision detection. The right comparison set is MMO / sandbox / persistent-world games whose servers run light per-entity simulation. AAA shooters (Counter-Strike, Battlefield, Apex) are a *different* workload class — their servers run real physics for hit registration. A separate **shooter-class measurement** with server-side physics enabled will follow once [arcane#51](https://github.com/brainy-bots/arcane/issues/51) (pluggable PhysicsBackend trait, default Rapier) and [arcane#52](https://github.com/brainy-bots/arcane/issues/52) (Rapier-at-scale capability benchmark) deliver.

### Headline matrix

The system was measured at multiple gate / tick / payload combinations during the 2026-04-26 + 2026-04-27 sessions. The full matrix is the honest publication — single-number headlines hide the tradeoffs.

| Configuration | Cluster tick | Latency gate | Per-entity payload | Ceiling | Run id |
|---|---|---|---|---|---|
| **Headline (publishing standard)** | **30 Hz** | **100 ms** | **realistic (~150 B)** | **4,750** | Run F (`20260427_004902`) |
| Lean baseline at the headline standard | 30 Hz | 100 ms | lean (~50 B) | 5,500 | Run D' (`20260427_003453`) |
| Relaxed latency, lean | 30 Hz | 200 ms | lean | 8,250 | Run D (`20260426_190419`) |
| Incumbent-tick-band reference | 20 Hz | 200 ms | lean | 9,000 | Run A (`20260426_125527`) |

Per-tier latency at the headline run (Run F):

| Players | lat_avg_ms | wire_avg_ms | drain_avg_ms | swarm_pass |
|---|---|---|---|---|
| 3,750 | 32.6 | 1.6 | 0.00 | ✅ |
| 4,000 | 43.7 | 1.0 | 0.01 | ✅ |
| 4,250 | 56.1 | 0.6 | 0.01 | ✅ |
| 4,500 | 65.4 | 0.2 | 0.01 | ✅ |
| **4,750** | **84.6** | **0.1** | **0.05** | **✅** |
| 5,000 | 101.5 | 0.2 | 0.08 | ❌ |

`lat_avg_ms` is client-perceived round-trip latency (player's outbound write → same player's own entity reflected back via the cluster's broadcast). `wire_avg_ms` is the swarm-send → cluster-stamp portion (network + cluster ingest). `drain_avg_ms` is the on-driver portion (frame arrival → decode → match). The remaining `lat_avg_ms − wire_avg_ms − drain_avg_ms` is the cluster fan-out + cluster→subscriber transit gap.

### What we measured (every dimension that matters)

Headline = Run F (30 Hz cluster tick / 100 ms gate / realistic per-entity payload). The dimensions below describe that run.

| Dimension | This run | Notes |
|---|---|---|
| Player count | 4,750 (ceiling) | Highest tier where `swarm_pass = true` and `lat_avg_ms < 100`. Lean baseline at the same gate: 5,500. |
| Per-entity broadcast state | ~150 bytes (realistic) | `entity_id` (16) + `cluster_id` (16) + `position` Vec3Q (i16 ≈ 6) + `velocity` Vec3Q (i16 ≈ 6) + `user_data` (~100 B JSON envelope). Lean variant has empty `user_data` ≈ 50 B. Vec3Q i16 quantization landed via [arcane#45](https://github.com/brainy-bots/arcane/issues/45). |
| Server tick rate | 30 Hz | Cluster simulation + broadcast at 30 Hz. Swarm client-movement-send rate is **derived** from `ClusterTickRateHz` so the rates can't drift out of sync ([arcane-scaling-benchmarks#56](https://github.com/brainy-bots/arcane-scaling-benchmarks/pull/56)). |
| Latency gate | 100 ms | The Arcane publishing standard. Tighter than the 200 ms incumbents publish against. Tier passes if `lat_avg_ms < 100` and error rate < 1%. |
| Visibility model | Full mesh | Every connected player receives every world entity each broadcast — no area-of-interest filtering, no spatial culling, no relevance system. The architectural escape hatch (affinity-based AOI / [arcane#69](https://github.com/brainy-bots/arcane/issues/69)) is the next major track. |
| Transport | WebSocket over TCP | Game-state replication uses TCP under the hood. Pluggable transport (QUIC, UDP) tracked in [arcane#43](https://github.com/brainy-bots/arcane/issues/43). Per-message-deflate compression ([arcane#44](https://github.com/brainy-bots/arcane/issues/44)) is library-blocked; standby. |
| Time dilation | None | Tick rate is a constant 30 Hz regardless of load — no game-time stretching as load rises. |
| Dead reckoning | Enabled | Cluster broadcasts an entity only when its velocity changes since last broadcast (within wire quantization step), with a periodic resync sweep ([arcane#46](https://github.com/brainy-bots/arcane/issues/46)). Bytes-out per cluster stayed roughly flat across the sweep despite serving ~31% more players. |
| Cluster hardware | 4 × c7i.2xlarge (8 vCPU, 16 GiB) | Sustained NIC ≈ 3 Gbps per instance. |
| Support hardware | t3.large each for Redis, SpacetimeDB persistence, Arcane manager; c7i.2xlarge for swarm driver | Commodity AWS, single-region. Data plane on t3.large because under the Arcane+Spacetime workload these roles do almost nothing (Redis is pub/sub plumbing, SpacetimeDB is 1 Hz persist, manager is HTTP /join). |
| Cluster CPU at ceiling | `last_tick_us` ≈ 6 ms / 33 ms tick budget = ~18% utilized | Cluster simulation has substantial CPU headroom — the wall isn't compute. |
| NIC at ceiling | ~0.6 GB/s sustained out per cluster vs ~0.375 GB/s c7i.2xlarge sustained capacity | Close to capacity but not multi-x oversubscribed. Dead reckoning + quantization meaningfully cut per-tick bytes. |
| Bottleneck | Cluster broadcast pipeline (channel cap + cluster-to-subscriber queueing) | Latency decomposition: `wire_avg_ms ≈ 0.14`, `drain_avg_ms ≈ 0.05` — both ~zero. The remaining ~84 ms is cluster fan-out + cluster→subscriber TCP queueing. Tunable broadcast channel cap ([arcane#51](https://github.com/brainy-bots/arcane/pull/51)) measured at 2048 *regressed* the ceiling — the empirically-correct default for the 100 ms gate is 256. The architectural answer to push higher is affinity-based AOI; tuning within full mesh is at its limit. |
| Per-entity state size: realistic? | Yes | UserDataBytes=100 in the realistic config produces ~150 B/entity payloads — within the 80–200 B range community-estimated for AAA shooters. Lean baseline (50 B) is the underlying-no-app-state floor. |
| Tick rate: realistic? | Above incumbent MMO band; matches lower shooter band | 30 Hz is above the 5–20 Hz incumbent MMOs publish at, and matches Apex Legends / lower-end Battlefield. Competitive shooters run 60+ Hz. |

### Where today's number sits relative to publicly-known industry data

The two variables that most directly drive replication load — **per-entity state size on the wire** and **server tick rate** — are the right axes to compare on. Tick rate is publicly disclosed by most studios. **Per-entity state size is not generally publicly disclosed** for shipped commercial games; community reverse-engineering work suggests MMO entities sit in the 150–400 B range when fully populated, and AAA shooter entities in the 80–200 B range. Those are not primary-source numbers and we don't cite them as such here.

#### MMO / sandbox / persistent-world (the right comparison class for today's number)

These are the games whose servers run light per-entity simulation — same workload shape as our benchmark. Arcane's 7,250-player, no-AOI, no-time-dilation, full-mesh ceiling sits naturally alongside this class.

| Game | Player density per shard | Server tick rate | Per-entity replication state | Server-side physics | Visibility | Architectural escape valve | Source |
|---|---|---|---|---|---|---|---|
| EVE Online | up to ~7,548 unique pilots in one battle (B-R5RB, 2014) | nominal ~1 Hz simulation tick within a system | not publicly disclosed | minimal — orbital mechanics + module-resolution, not real-time rigid-body physics | no AOI within a system | single-threaded per system; **time dilation** when load exceeds capacity | [CCP dev blog on TiDi](https://www.eveonline.com/news/view/the-bloodbath-of-b-r5rb), [Eurogamer / Polygon coverage](https://www.eurogamer.net/largest-online-multiplayer-battle-history-eve-online) |
| World of Warcraft (one realm) | thousands of concurrent players per realm; modern raids / cities use [layering](https://worldofwarcraft.blizzard.com/en-us/news/22939231/welcome-to-layering-system) to subdivide high-density zones | not publicly disclosed | not publicly disclosed | minimal — server enforces position, ability cast checks; no rigid-body dynamics | aggressive AOI (nearby players + raid group) | realm = sharded mega-server with **layering** | [Blizzard layering announcement](https://worldofwarcraft.blizzard.com/en-us/news/22939231/welcome-to-layering-system) |
| Foxhole | up to 150+ players per hex (advertised), persistent world | not publicly disclosed | not publicly disclosed | minimal — vehicles use simple kinematics, no rigid-body simulation in heavy fights (community-observed) | spatial / hex-bound | hex sharding | [Siege Camp community AMAs and dev posts](https://store.steampowered.com/app/505460/Foxhole/) |
| Star Citizen | ~100 / server (current target) | game tick ~30 Hz | not publicly disclosed; entity model unusually heavy (multi-subsystem ships, persistent inventory) | yes — heavy multi-subsystem ship + character physics on server (atypical for the class) | full visibility within shard | working toward "server meshing" (functionally similar to Arcane clustering) | [CIG roadmap and dev updates, 2024–2025](https://robertsspaceindustries.com/roadmap) |
| **Arcane (headline, MMO-class)** | **4,750 / 4-cluster setup at 30 Hz / 100 ms with realistic ~150 B per-entity payload; 5,500 lean at the same gate; 8,250 lean at 30 Hz / 200 ms; 9,000 lean at 20 Hz / 200 ms** | **30 Hz publishing standard (above incumbent band)** | **~150 B realistic / ~50 B lean (Vec3Q i16 quantized + opaque user_data)** | **No real physics — kinematic motion + radius-based collision only** | **Full mesh, no AOI, no time dilation** | **horizontal clustering across commodity AWS** | this repo, runs `20260427_004902` (headline), `20260427_003453`, `20260426_190419`, `20260426_125527` |

Architectural commitments in this class: EVE buys density via single-thread-per-system + **time dilation** (game time slows under load). WoW buys density via aggressive AOI + silent **layering** (subdivides dense zones). Foxhole shards by hex. Star Citizen aspires to **server meshing** but currently caps near 100/shard. Arcane's 4,750 (realistic-state) / 9,000 (lean, 20 Hz / 200 ms) is full mesh, no AOI, no time dilation, no zoning — the architectural commitments are the strictest in this class and the player-count number tracks that. The architectural escape from O(P²) full-mesh is **affinity-based AOI** ([arcane#69](https://github.com/brainy-bots/arcane/issues/69)), Arcane's stated core premise; the current measurements are pre-AOI.

#### AAA shooters (different workload class — context only)

These titles run real physics for hit registration on the server, which our benchmark doesn't yet do. **Comparison with these numbers becomes apples-to-apples after** the planned shooter-class benchmark with [arcane#51](https://github.com/brainy-bots/arcane/issues/51) / [arcane#52](https://github.com/brainy-bots/arcane/issues/52). Listed here only so a reader sees the shape of those numbers, not as a like-for-like comparison.

| Game | Player cap per match | Server tick rate | Server-side physics | Visibility | Source |
|---|---|---|---|---|---|
| Counter-Strike (Valve official) | 10 (5v5) typical | 64 Hz | yes — hit reg + weapon physics | match-bound, no AOI | [Valve Source SDK docs](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking) |
| Counter-Strike (FACEIT / tournaments) | 10 | 128 Hz | yes (same) | same | [FACEIT support](https://support.faceit.com/) |
| Apex Legends | 60 | 20 Hz | yes — server-authoritative hit detection | AOI / relevance | [Respawn community responses + Battle(non)sense analysis](https://www.youtube.com/c/Battlenonsense) |
| Battlefield 2042 | 128 | 30–60 Hz (platform-dependent) | yes — vehicle dynamics, hit reg, ragdoll | spatial relevance | [DICE platform specs](https://www.ea.com/games/battlefield/battlefield-2042) |
| PlanetSide 2 | up to 2,000 / continent (advertised) | ~25–30 Hz (community-measured) | yes — vehicle + hit reg server-authoritative | aggressive AOI; player only sees ~nearest N | [SOE / Daybreak marketing](https://www.planetside2.com/) |

**On the two replication variables:**

- **Tick rate (frequency):** the load on every link in the pipeline scales linearly. Going from 20 Hz to 30 Hz means 1.5× the broadcasts per second, 1.5× the cluster encode CPU, 1.5× the NIC bandwidth. We sit at the low end of the live-shooter range; a 30 Hz sweep is on the roadmap and is expected to lower the player-count ceiling proportionally.
- **Per-entity state size:** broadcast bandwidth scales linearly with bytes-per-entity. Going from our 56 B to a more realistic ~140 B (rotation + health + equipment + animation flags packed into `user_data`) is 2.5× the cluster outbound bandwidth, which matters because that's the binding bottleneck today. We expect the realistic-state ceiling to be lower than 7,250 by roughly the bandwidth ratio. That measurement is on the roadmap as a sibling-config experiment.

**On server-side physics — the comparison class for today's number:**

This benchmark runs **kinematic motion** (`position += velocity × dt`) plus **radius-based pairwise collision detection** on the cluster. No rigid-body dynamics, no joint constraints, no raycast hit detection, no vehicle physics, no ragdolls. The cluster's per-tick CPU cost is dominated by entity replication, not by simulation.

That puts the right comparison class for the 7,250-player number at workloads in the **MMORPG / sandbox / persistent-world** family (WoW, EVE Online, Foxhole) — games whose server-side per-entity simulation is also light, where the ceiling is driven by replication and broadcast cost, not by per-frame physics integration. Direct comparison to **AAA shooter** ceilings (Counter-Strike, Battlefield, Apex) is *not* apples-to-apples: those servers run real physics for hit registration and gameplay-critical effects, which adds per-tick CPU cost the benchmark doesn't pay.

Adding real server-side physics is tracked as future work in [arcane#51](https://github.com/brainy-bots/arcane/issues/51) (pluggable PhysicsBackend trait, default Rapier) and [arcane#52](https://github.com/brainy-bots/arcane/issues/52) (Rapier-at-scale capability benchmark). Once those land, a follow-up benchmark sweep against **shooter-class workloads with server physics enabled** will be measured and published in this section. The comparison set will include AAA shooter-class engines (Source / Frostbite / Unreal-Dedicated-class server workloads) where Arcane runs the same physics workload they do — so the resulting numbers are apples-to-apples against the live-shooter player counts at the top of the table. The current 7,250 figure is the **no-physics baseline**; the with-physics measurement will be a separate, lower number meant for direct comparison to shooter-class production servers.

### Cost per concurrent player

Hardware-cost-per-CCU is the metric that keeps numbers comparable as we move across instance classes (`c7i.2xlarge` today, network-optimized `c6in` or `c5n` later, Graviton `c7gn` for ARM-friendly workloads, etc.). What changes across hardware is the absolute ceiling; what *stays* is the dollars-per-CCU-per-hour, which is the production-relevant figure for any studio sizing a deployment.

**Headline run (Run F, 4,750 realistic CCU at 30 Hz / 100 ms), AWS on-demand pricing (us-east-1, 2026-04 rates):**

| Role | Instance | Count | $/hr each | Subtotal |
|---|---|---|---|---|
| Cluster nodes | c7i.2xlarge | 4 | ~$0.357 | ~$1.43 |
| SpacetimeDB persistence | t3.large | 1 | ~$0.083 | ~$0.08 |
| Redis | t3.large | 1 | ~$0.083 | ~$0.08 |
| Arcane manager | t3.large | 1 | ~$0.083 | ~$0.08 |
| **Production-fleet total** | | **7** | | **~$1.67/hr** |
| Swarm driver (test only — not in production fleet) | c7i.2xlarge | 1 | ~$0.357 | excluded |

At 4,750 concurrent realistic-state players: **~$0.000352 per CCU per hour** ≈ **~$0.35 per 1,000 CCU per hour** ≈ **~$2.81 per 1,000 CCU per session-day** (8 hr).

At the lean baseline (5,500 CCU, same fleet): **~$0.000304 per CCU per hour**. At the 30 Hz / 200 ms relaxed-latency point (8,250 CCU, same fleet): **~$0.000202 per CCU per hour**.

Translating into industry-relevant units (using the 4,750 realistic headline):

- A 60-day average lifetime player playing 1 hr/day costs **~$0.02 in cluster infrastructure** at this density.
- A persistent shard hosting 4,750 concurrent players continuously, 24/7/365, costs **~$14,600/year** at on-demand pricing. With AWS Reserved Instance or Savings Plan discounts (20–50% for 1–3 year commitments), or Spot pricing for non-critical roles (60–90% off), real production cost lands in the **$3,500–$10,000/year** range for a single 4,750-realistic-CCU shard.

**Why this matters for cross-hardware comparison.** When we move to `c6in.2xlarge` or larger network-optimized instances to push the absolute ceiling higher, the per-instance hourly cost goes up but so does the achievable CCU. The right metric to track is whether $/CCU/hr stays roughly flat (good — we're scaling efficiently) or improves (we're getting more density per dollar). Future benchmark runs will report the same `$/CCU/hr` figure alongside the absolute ceiling so the comparison across hardware tiers is honest — a 20,000-player ceiling on $10/hr hardware is a worse $/CCU than today's 7,250 on $2.50/hr if the per-player cost goes up.

This figure also makes Arcane's number directly comparable to shipped games' published infrastructure economics, since per-CCU-per-hour is what studios actually budget against — independent of whether the underlying instance is a c7i, a Hetzner bare-metal box, or a Kubernetes pod.

**Industry context (estimates, not primary sources).** Per-CCU server costs for shipping commercial games are not generally disclosed by studios in primary sources. Industry analyst estimates and back-calculations from publicly-disclosed CCU peaks and aggregate server-spend figures typically land AAA-shooter dedicated-server costs in the **$0.001–0.005 per CCU per hour** range, with MMO-style architectures often higher due to specialized hardware and persistence overhead (EVE Online's per-CCU has been estimated at ~$0.005–0.010/CCU/hr from CCP's published infra-spend dev blogs over the years). These are *estimates*. We list the range only so a reader has some anchor; the comparison should not be taken as a claim against any specific competitor's cost. With that caveat, our $0.000352/CCU/hr (realistic-state headline, full Arcane fleet, AWS on-demand) lands roughly 3–15× below the estimated AAA range. We expect the gap to narrow once we add real server-side physics ([arcane#51](https://github.com/brainy-bots/arcane/issues/51) / [#52](https://github.com/brainy-bots/arcane/issues/52)).

The comparison Arcane fits into:

- **Player count, full mesh, no AOI, no time dilation, on commodity AWS, 30 Hz / 100 ms / realistic per-entity payload**: 4,750 in the headline run is — to our knowledge — in the range that ships only with explicit AOI tricks, time dilation, or zone sharding in production multiplayer games at this tick rate / latency tier.
- **Tick rate**: 30 Hz is **above** the incumbent MMO band (5–20 Hz) and matches Apex Legends' lower-end shooter tick. Competitive shooters (Counter-Strike at 64–128 Hz, Battlefield at 30–60 Hz) run higher; pushing tick rate above 30 Hz is on the roadmap once server-side physics lands so the comparison stays apples-to-apples.
- **State size**: 4,750 is the realistic-state number (~150 B per-entity payload). The lean number (~50 B) at the same gate is 5,500 (+16%). The realistic measurement is the publishing standard because it matches what real games carry.

### Why the ceiling is where it is

At the headline (Run F, 4,750 realistic CCU @ 30 Hz / 100 ms), the cluster has substantial CPU headroom (`last_tick_us ≈ 6 ms` vs the 33 ms tick budget — ~18% utilized) and NIC is at ~80% of c7i.2xlarge sustained capacity (close, but not multi-x oversubscribed). The full Phase 1 stack (Vec3Q i16 quantization, dead reckoning, per-tick velocity-change skipping) successfully moved the bottleneck *off* of NIC bandwidth. The remaining wall is the **cluster broadcast pipeline** — specifically the gap between cluster timestamp (T2) and swarm-driver receipt (T_arrival).

Latency decomposition at the failure tier confirms it: `wire_avg_ms ≈ 0.14`, `drain_avg_ms ≈ 0.05` — both essentially zero. The remaining ~84 ms of total latency is in cluster fan-out scheduling + cluster→subscriber TCP queueing.

We tested raising the tokio broadcast channel cap from 256 → 2048 ([arcane#51](https://github.com/brainy-bots/arcane/pull/51)) on the hypothesis that the cap was the binding limit. **It regressed the ceiling** (4,750 → 4,250 realistic, 5,500 → 4,250 lean). Mechanism: a smaller cap forces aggressive `Lagged` dropping for slow subscribers, which keeps the broadcast pipeline fresh for fast subscribers and protects total wall-clock latency. The 256 default was already empirically correct for the tight 100 ms gate. The env-var tunability stays for relaxed-latency operators, but the *default* is back at 256. See [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md) Run G + H for the data.

This is the **full-mesh replication wall on the current hardware class.** It is not a fundamental ceiling for Arcane — the candidate moves to push past it:

- **Affinity-based AOI** ([arcane#69](https://github.com/brainy-bots/arcane/issues/69)) — partial-mesh fan-out by predicted interaction probability instead of full mesh. The architectural answer; lifts the O(P²) wall fundamentally rather than pushing it. **This is the product premise and the next major track.**
- **Network-optimized instances** (`c6in.2xlarge`, `c5n.2xlarge`, `c7gn.*`) — same vCPU/RAM, ~5× the sustained NIC. Worth measuring as a separate cost-per-CCU experiment.
- **Per-message-deflate compression on WebSocket** ([arcane#44](https://github.com/brainy-bots/arcane/issues/44)) — library-blocked today; standby. Would compose additively with what's already landed.
- **Pluggable transport** — moving the broadcast wire from TCP to QUIC or raw UDP eliminates head-of-line blocking and gives meaningfully better tail latency under loss ([arcane#43](https://github.com/brainy-bots/arcane/issues/43)).

### What this number is *not*

- **Not a measurement with real server-side physics.** Cluster simulation is kinematic + radius-collision. Comparable to MMORPG / sandbox / persistent-world workloads, not to AAA shooters that run server-side rigid-body physics for hit registration. Real physics (Rapier as default; pluggable to Chaos / PhysX / Bullet) is on the roadmap; adding it will lower the ceiling. Cluster CPU has headroom to absorb the cost (we run at ~18% tick utilization), so the lean ceiling shouldn't drop dramatically — the published number will become a fair "with-physics" claim once the work lands.
- **Not yet measured at competitive-shooter tick rate.** 30 Hz is above incumbent MMOs and matches Apex Legends, but competitive shooters (Counter-Strike at 64–128 Hz, top-tier Battlefield) run higher. Pushing tick above 30 Hz is on the roadmap once physics lands so the comparison stays apples-to-apples.
- **Not a measurement against AOI / interest-managed visibility.** This is full mesh — every player sees every entity. Most large-player-count shipping games cull aggressively. Comparing Arcane's full-mesh ceiling to PlanetSide 2's 2,000-player AOI-managed continent isn't apples-to-apples; the workloads differ by 10×–100× in per-cluster fan-out.
- **Not validated on cluster counts other than 4 with this hardware.** The 2-cluster and 6-cluster numbers from earlier (in the journal) are historical and pre-Phase-1. Re-measurement at the new code path is on the roadmap.

### Predecessor results (historical)

Earlier runs on `t3.large` cluster nodes (smaller hardware) with the swarm driver that bottlenecked on broadcast decode at high player counts. Those numbers and the architectural changes that superseded them (latency decomposition, per-frame decode cache, Vec3Q quantization, dead reckoning, JSON-envelope user_data, env-tunable broadcast cap) are documented chronologically in [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md). Tonight's headline is the post-Phase-1 measurement on the c7i.2xlarge cluster fleet at the locked publishing standard.

### Next benchmarks on the roadmap

- **Server-side physics integration.** Pluggable PhysicsBackend ([arcane#51](https://github.com/brainy-bots/arcane/issues/51)) + Rapier-at-scale capability benchmark ([arcane#52](https://github.com/brainy-bots/arcane/issues/52)). Expected: small drop in headline ceiling (we have ~5× CPU headroom to spend), gives apples-to-apples shooter-class comparison.
- **Affinity-based AOI** ([arcane#69](https://github.com/brainy-bots/arcane/issues/69)). The architectural answer to escape the O(P²) full-mesh wall. Major project — likely 10×+ lift to player-count ceiling.
- **Network-optimized cluster hardware** (`c6in.2xlarge` / `c5n.2xlarge` / `c7gn.*`) — separate cost-per-CCU comparison point.
- **Cluster-count sweep** — re-measure 2c / 6c / 8c on the post-Phase-1 stack to validate the scaling shape on the new code.

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
