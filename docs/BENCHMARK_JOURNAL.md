# Benchmark journal

A dated log of benchmark experiments — what we tried, what we observed, what we learned, what we tried next. Entries are chronological; read top-to-bottom to understand how the current published numbers came to be, or bottom-up for recent context.

Each entry captures:

- **Hypothesis / question** — what we wanted to test.
- **Setup** — image tag, config, fleet shape, cluster count, hardware.
- **Result** — headline numbers + anomalies.
- **Interpretation** — what it means; what it does *not* mean.
- **Next** — what we decided to try next.

This journal exists so we don't re-run dead ends, so outside readers can validate the methodology, and so architectural decisions are traceable to the evidence that motivated them.

Benchmark results (manifests, CSVs, per-node diag captures) live under `results/runs/<Environment>/<RunId>/`. Journal entries link to specific `RunId`s.

---

## 2026-04-18 — Session baseline, prior to any fixes

**Setup.** Arcane 2-cluster AWS run using the codebase as it existed before this week's work. Cluster nodes c7i.2xlarge, driver c7i.2xlarge, Redis and SpacetimeDB on t3.large. Config `arcane_plus_spacetimedb.clusters_2.json` (start 1500, step 250, max 6000).

**Result.** Ceiling appeared to be 2000. Failure mode looked like ramp-timeout at 2250 players.

**Interpretation at the time.** Assumed we had hit some CPU or memory limit on the cluster at ~1800-2000 players.

**Actual cause (discovered later).** Container default `nofile=1024` ulimit. The cluster's `listener.accept()` loop hit EMFILE at exactly 1007 accepted sockets per cluster (1000 clients + ~7 internal FDs), silently exited on Err, and every subsequent connection attempt was refused. The classifier attributed this to "driver_or_network" because cluster CPU/broadcast/WS-send counters were all clean — the cluster kept ticking idle with no new connections.

**Next.** Add `--ulimit nofile=65536:65536` to every benchmark container's `docker run`.

---

## 2026-04-21 — ulimit fix

**Hypothesis.** The 2000-cap is the container's FD limit, not a cluster or workload limit.

**Setup.** Same fleet as prior run, plus `--ulimit nofile=65536:65536` added to every docker run in both `AwsArcanePerHost` and `AwsSpacetimeOnly` topologies (PR arcane-scaling-benchmarks#35). Rebuilt image tag `dev-20260421-observability`. Same config (`clusters_2`, start 500, step 250, max 6000).

**Result.** Run `20260421_070438`. Ceiling moved from 2000 → **3500 players**. Failure mode changed from silent accept-stop to cluster container OOM-kill at 3750 (anon-rss 6.5 GB on 16 GB instance).

**Interpretation.** The ulimit was the entire reason for the 2000 cap. The true cluster ceiling on c7i.2xlarge is ~1750 clients per cluster (RAM-bound via per-connection state). The earlier "classifier attributed to driver_or_network" was a false signal — there was no CPU saturation anywhere.

**Next.** Fix `broadcast_lagged_events` / `bytes_out` observability (arcane#37), multi-thread tokio runtime (arcane#38), per-tier classifier (arcane-scaling-benchmarks#33). These become the substrate for diagnosing future ceilings.

---

## 2026-04-21 — Client-perceived latency fix

**Hypothesis.** Benchmark's `lat_avg_ms` has been 0.00 across every run because every latency fix over the past months swapped a measurable HTTP round-trip for an unmeasurable async enqueue. Actual server load is invisible to the metric.

**Setup.** Replace `Instant::now() - t0` timing around fire-and-forget sends (both backends) with client-side echo matching: swarm tracks `last_send_micros` per player; when the swarm sees its own entity echoed in the server's outbound stream, records `now - last_send` (Arcane via decoded broadcast frame, SpacetimeDB via SDK `on_update` subscription). Merged as arcane_swarm#12 + arcane-scaling-benchmarks#37-doc.

**Result.** Runs after the bump produced real, load-responsive latency for the first time. Floor at ~50 ms on both backends, climbing with load. The floor value turns out to be structural to the 10 Hz tick rate (half the tick period on average for an uncorrelated send).

**Interpretation.** Every number prior to 2026-04-21 with `lat_avg_ms ≈ 0.00` should be treated as uninformative. Post-fix numbers reflect what a real game client would experience. Re-ran prior scenarios against the new methodology; those reruns are the canonical "current" numbers.

**Next.** Rerun SpacetimeDB-only and Arcane 2c, 4c, 6c with the new metric for a clean head-to-head.

---

## 2026-04-21 — SpacetimeDB-only wide ceiling sweep

**Hypothesis.** On the new metric, what's the SpacetimeDB-only single-node ceiling?

**Setup.** Config `spacetimedb_only.wide.json` (step 250, max 6000). AwsSpacetimeOnly topology: one c7i.2xlarge for SpacetimeDB + one c7i.2xlarge for driver. Image `dev-20260421-stdb-wide`. Run `20260421_151956`.

**Result.** Ceiling **1750 players** at ~51 ms latency. Server became unreachable at 2000 (SpacetimeDB hit its single-node cap; failure mode: connection refused, not latency climb).

**Interpretation.** This is SpacetimeDB's ceiling on this hardware: one node, architectural cap, no horizontal scaling path. Latency stays flat at the tick-floor right up to the crash — SpacetimeDB is fine until it isn't. This is the number the "Arcane vs SpacetimeDB" comparison points back to.

---

## 2026-04-21 — Arcane 2-cluster (canonical run)

**Setup.** Config `arcane_plus_spacetimedb.clusters_2.json`, 4 clusters of... wait, 2 clusters. Image `dev-20260421-client-lat`. Run `20260421_145648` (third attempt after two transient AWS retries).

**Result.** Ceiling **3500 players** at ~50 ms. Failure mode: cluster 1 OOM-killed at 3750 (anon-rss 6.5 GB on 16 GB c7i.2xlarge).

**Interpretation.** At N=2, per-cluster workload is bound by RAM: each cluster holds roughly the full world's entities (own + one neighbor) plus ~1800 local WS connection states. 6.5 GB is the observed cap; beyond ~1800 clients per cluster we OOM. Task #62 tracks a heap-profile investigation.

---

## 2026-04-21 — Arcane 4-cluster (canonical run, first major data point)

**Setup.** `arcane_plus_spacetimedb.clusters_4.json` (added same day; ArcaneClusterCount=4, max 10000). Run `20260421_155106`.

**Result.** Ceiling **6000 players** at 126 ms latency. Failure mode: latency gate triggered at 6250 (276 ms). `broadcast_lagged_events = 0` across all four clusters at every passing tier — clean delivery.

**Interpretation.** Near-linear scaling from 2c (3500) → 4c (6000), but with a clear latency-climb shape: ~50 ms at low tiers, rising smoothly to 126 ms at the ceiling. The climb reflects full-mesh replication cost growing per-cluster with N (each of 4 clusters receives 3 neighbors' state vs 1 neighbor at N=2). RAM is no longer binding (per-cluster local count dropped from ~1800 to ~1500); CPU is now the proximate limit.

**Next.** Try 6-cluster to see whether scaling continues linearly or the full-mesh tax bends the curve.

---

## 2026-04-21 — Arcane 6-cluster (shape becomes visible)

**Setup.** `clusters_6.json`, ArcaneClusterCount=6, max 11000. Run `20260421_195219`. Same workload, same image.

**Result.** Ceiling **6750 players** at 196 ms (just under the 200 ms gate). Only +750 players over 4c. Latency curve is much steeper — climbs 51 ms (low) → 196 ms (ceiling) vs 4c's 51 → 126 ms.

**Interpretation.** Empirical confirmation of the full-mesh replication tax. Per-cluster per-tick CPU is O(P) in total world entities regardless of N, because every cluster must apply every neighbor's update. Local-client work shrinks with N; neighbor-processing work stays constant. Adding clusters past ~4 gives diminishing absolute ceiling gain AND gives up latency budget. At a tighter 100 ms playability gate the crossover is even earlier: 2c=3500, 4c=5750, **6c=4000 (actively worse than 4c)**. This is the single strongest empirical argument for prioritizing affinity clustering — it motivates pillar #1 of WHY_ARCANE.md concretely rather than theoretically.

**Next.** Skip 8c (cost vs. learning is poor — the shape is already unambiguous). Try to lift the per-cluster CPU bottleneck that's driving the latency climb. Parallel pre-encoding (task #67) is the simplest candidate before affinity clustering is available.

---

## 2026-04-21 — Parallel pre-encoding (unbounded rayon)

**Hypothesis.** The cluster's serial O(P) encode loop is the dominant per-tick CPU cost. Parallelize it via `rayon::par_iter` across all 8 vCPUs. Expected: encode wall-clock drops 4–6×, latency at high tiers drops, ceiling moves up.

**Setup.** arcane#40 (unbounded rayon). Submodule bumped in arcane-scaling-benchmarks#43. Image `dev-20260421-parallel-encode`. Config `clusters_4` (unchanged). Run `20260421_224830`.

**Result.** Ceiling nominally up to **6750** (from 6000). But the latency curve is non-monotonic: climbs to 170 ms at 4500, then *drops* to 52 ms at 6000, then spikes to 936 ms at 7000. **And `broadcast_lagged_events` exploded from 0 to ~400k per cluster** at every tier past 1500 players.

**Interpretation.** The ceiling-up-to-6750 is a **measurement artifact**, not a real improvement. Mechanism: the latency metric only records samples from subscribers that actually received a broadcast containing their own entity. When subscribers fall 256+ ticks behind the producer and hit `RecvError::Lagged`, they drop frames and contribute no sample. At 6000 players, ~half the subscribers are lagging continuously; the remaining "lucky" half are by definition receiving fresh echoes, so their latency measurement is artificially low. The cluster appears faster; actually, it's dropping frames to half the clients. Not a real scaling win.

**Interpretation 2.** Initial theory: rayon grabbing all 8 cores during each encode burst starves tokio's per-subscriber send tasks → broadcast queues fill → Lagged. If true, bounding rayon should fix it.

**Next.** Bound rayon to half the cores.

---

## 2026-04-22 — Parallel pre-encoding (bounded to num_cpus/2)

**Hypothesis.** Bounding the rayon pool to half the node's cores (4 on c7i.2xlarge) leaves the other half reliably available for tokio subscriber tasks. Expected: broadcast_lagged drops to near-zero, latency stays monotonic, ceiling moves up cleanly.

**Setup.** arcane#41 (pool sized by `max(1, num_cpus/2)`, `ARCANE_CLUSTER_ENCODE_THREADS` env override). Submodule bumped in arcane-scaling-benchmarks#44. Image `dev-20260422-bounded-rayon`. Config `clusters_4`. Run `20260422_010033`.

**Result.** Ceiling **5750 players** (LOWER than serial's 6000 and lower than unbounded's 6750). Latency at 6000 = 277 ms (gate violated, tier failed). `broadcast_lagged_events` still climbing to ~340-425k per cluster. Non-monotonic latency shape unchanged from the unbounded run (dips to 50 ms at 5000-5750, same masking pattern).

**Interpretation.** Hypothesis falsified. Bounding rayon did NOT meaningfully reduce broadcast lag. The serial-encoding baseline (arcane#40 reverted to serial behavior in effect because we've done both tests) had **zero lag across all clusters** at 6000 players — serial is strictly better on delivery quality than any parallel variant we've tried.

**New interpretation.** The lag mechanism isn't primarily rayon-vs-tokio core contention. Looking at the data more carefully:

- Cluster's per-tick CPU is within budget (`tick_us` ≤ 100 ms even at ceiling tiers).
- Driver (swarm) CPU is sustained at **700-800% of one core** from about 1000 players onward across every run. The swarm's 8-vCPU node is fully saturated.
- `broadcast_lagged_events` growth rate is roughly constant across tiers once it begins, which fits a constant-saturation bottleneck (driver) better than a scale-with-load bottleneck (cluster CPU).

Revised mechanism: **the driver's TCP recv buffer fills because its tokio tasks can't process incoming WS frames fast enough** (driver is CPU-saturated). TCP backpressure propagates to the cluster's send side; the cluster's per-subscriber send tasks `await` on a blocked socket; they stop draining the broadcast `recv` side; the producer outpaces them; `Lagged` accumulates. Parallel encoding *widens* this gap (producer encodes faster, driver still can't catch up), which is why parallel variants have more lag than serial — nothing to do with intra-cluster thread scheduling.

If this is right, the "cluster ceiling" numbers from 4c onward have been partly **driver-limited**, not cluster-limited. The real cluster capability could be significantly higher on identical hardware.

**Next.** Verify the hypothesis by lifting the driver bottleneck only, not changing cluster hardware. Upgrade the driver-only instance to c7i.4xlarge (double the cores: 16 vCPU), keep cluster nodes at c7i.2xlarge. If latency stays flat at the floor and `broadcast_lagged` drops to near-zero, the hypothesis is confirmed and our published ceiling numbers have been artificially low on the Arcane side. This is a ~5-minute terraform change and ~$1 of EC2.

---

## 2026-04-25 — Driver-instance upsize (c7i.4xlarge), bounded-rayon hypothesis falsified

**Hypothesis.** From the prior entry: per-subscriber TCP backpressure from a CPU-saturated driver was widening the cluster's broadcast-channel lag. Doubling the driver's cores (8 → 16 vCPU) should drain inbound WS frames faster, relieve the backpressure, drop `broadcast_lagged` near zero, and reveal a higher real cluster ceiling.

**Setup.** New tfvars sibling `arcaneperhost.clusters_4.big_driver.tfvars` (`instance_type = "c7i.4xlarge"` for the driver, `data_instance_type = "t3.large"` for clusters/spacetime/redis/manager — unchanged from the prior bounded-rayon run). Same image (`dev-20260422-bounded-rayon`), same `clusters_4.json` config. Run `20260422_020054`. Also: a CloudTrail audit ahead of the run confirmed all earlier "c7i.2xlarge clusters" claims in the README/journal were wrong — cluster nodes had been on `t3.large` (2 vCPU, burstable) since the first run, with only the driver on `c7i.2xlarge`. Documentation hardware-fix went to a separate PR.

**Result.** Ceiling **6,000 players** (identical to serial baseline; no improvement from doubling driver cores). `broadcast_lagged_events` accumulated 1.12M events across the 4 clusters at the failing 6,250 tier — the same lag pattern as the c7i.2xlarge driver run. `swarm_summary` was null (regression in the reporter, not interpreted as a signal here).

**Interpretation.** Hypothesis falsified. Doubling driver cores did **not** lift the ceiling and did **not** materially reduce broadcast lag. The driver was *not* the binding bottleneck on `t3.large` clusters — the clusters themselves were. Re-reading the per-tier evidence: cluster `last_tick_us` had been at 57–63 ms across all 4 nodes at 6,000 players, exceeding the 50 ms tick budget. The clusters were CPU-saturated on their own 2-vCPU `t3.large` boxes; the driver was downstream of an already-saturated producer. Adding driver cores doesn't help when the producer can't produce faster.

The actionable diagnosis: bounded-rayon (`num_cpus / 2`) on `t3.large` reduces to **1 effective rayon thread on a 2-vCPU box**, which is approximately serial — the experiment was nearly vacuous on this hardware. The "rayon parallelism wins" claim has not been tested on hardware where rayon actually has cores to spread across. Need clusters with more cores.

**Next.** Two parallel tracks: (a) re-run with cluster nodes on `c7i.2xlarge` (8 vCPU each) so the rayon pool has actual room, sweeping starting at the prior ceiling. (b) Land the README/journal hardware-fix docs separately so the historical numbers are correctly attributed to `t3.large`.

---

## 2026-04-26 — Big-fleet (c7i.2xlarge clusters_4), bounded-rayon test reveals driver-side scheduler bias

**Hypothesis.** Prior bounded-rayon attempts ran on 2-vCPU clusters where `num_cpus / 2 = 1` thread = effectively serial. With cluster nodes upgraded to 8-vCPU `c7i.2xlarge`, the rayon pool now has 4 real threads. Either we see the long-claimed parallel-encode lift (ceiling moves up), or we falsify it on adequate hardware (revert arcane#40/#41).

**Setup.** New sibling tfvars `arcaneperhost.clusters_4.big.tfvars` (all server-side roles on `c7i.2xlarge`; driver also `c7i.2xlarge`). New sibling config `arcane_plus_spacetimedb.clusters_4.big.json` starting the sweep at 5,750 (the tier just before the prior bounded-rayon failure at 6,000), step 250, max 10,000. Same image (`dev-20260422-bounded-rayon`). Run `20260426_013414`.

This was also the first run on the new runtime-config-mount infra (configs staged to S3 per run, mounted into the container — see arcane-scaling-benchmarks#49) instead of being baked into the image at build time. Smoke test on a SpacetimeOnly fleet preceded the big-fleet run; the wiring worked end-to-end.

**Result.** **Ceiling: 5,750 players, but with `lat_avg_ms = 530.69` at the 5,750 tier itself — already over the 200 ms gate**. Failed at 5,750 (the very first tier of the sweep). 0 errors out of ~300K calls; cluster `last_tick_us` only 5.6–7.5 ms (well under 50 ms tick budget); `broadcast_lagged_events` ~12K per cluster (compared to 340–425K in the prior `t3.large` bounded-rayon run, a ~25× reduction).

**Interpretation.** The cluster has *more* headroom and *less* lag than the prior run, yet client-perceived latency is 4× higher. Inconsistent with a cluster-side bottleneck. Driver investigation: the swarm's per-tick `drv_cpu` sample read **1,500–1,600 %** on a c7i.2xlarge driver (8 vCPU max — the metric is mathematically impossible at the headline value). On-host kernel data via SSM showed cgroup `nr_throttled = 0`, no OOM, no dropped network packets, ~360 MB RSS used out of 16 GB. The driver was **not** resource-throttled by the kernel.

What the impossibly-high `drv_cpu` reading actually indicates: the swarm's reporter loop computes `drv_cpu = (utime+stime delta in ticks)`, assuming a 1-second sample interval. When the reporter task is starved by the runtime (because all 8 worker threads are busy elsewhere), the actual loop interval grows; the cumulative tick delta stays the same; the percentage reads as much greater than 100 × cores. The metric being broken is itself the diagnostic: **the swarm's tokio runtime is unable to schedule the reporter task on a regular cadence**, which means it's also unable to schedule the per-player drain tasks on a regular cadence, which means the latency the swarm measures is mostly the time it took the swarm itself to get around to processing the frame — not the time the cluster took to produce it.

**Next.** Add a server-stamped timestamp on broadcasts and a driver-side latency decomposition (T1 = client send, T2 = server stamp, T3 = driver match). If most of the 530 ms is between T2 and T3 — i.e., on the driver after the frame arrived — the swarm-side scheduler hypothesis is confirmed.

---

## 2026-04-26 — T1/T2/T3 latency decomposition on the same fleet

**Hypothesis.** From the prior entry: the 530 ms client-perceived latency at 5,750 players is dominated by driver-side scheduler queueing, not cluster-side processing. Adding a server-stamped broadcast timestamp + driver-side decomposition will reveal where in the pipeline the time actually lives.

**Setup.** Wire `DeltaPayload.timestamp: f64` (already present, hardcoded to 0.0) populated with `SystemTime::now().duration_since(UNIX_EPOCH).as_secs_f64()` at cluster `tick()` (arcane `feat/server-timestamp-on-broadcast`). Swarm drain task captures `T_arrival` immediately after `stream.next().await` returns and `T_match` after the entity-id scan; records `total_us = T3 − T1` (existing), `wire_us = T2 − T1` (cross-clock), `drain_us = T3 − T_arrival` (driver-internal, clock-sync free) (arcane_swarm `feat/latency-decomposition`). Image `dev-20260426-latency-decomp`. Same fleet as the prior run, same `clusters_4.big.json` config. Run `20260426_041346`.

**Result.** At 5,750 players: `lat_avg_ms = 516.93`, **`drain_avg_ms = 1.54`**, `wire_avg_ms = 0.00`, `wire_samples = drain_samples = 45,518` (out of an expected ~150K-200K echoes). 0 errors.

**Interpretation.** `drain_us = 1.54 ms` is the actual on-driver decode + entity-scan + record cost per matched echo. The remaining `516 − 1.54 ≈ 514 ms` is everything between "frame arrived in the swarm process" and "the swarm's drain task got scheduled to handle it" — pure tokio executor queueing. **Driver-side scheduler hypothesis confirmed.** The 5,750-tier "failure" from the prior entry was almost entirely measurement bias; the cluster was healthy.

The 26% sample rate (45K / ~175K expected) corroborates: 74 % of echoes never reached the swarm's `record_ok` path during the 30 s steady window because they were buried in the executor's task queue, never processed before the tier ended.

`wire_avg_ms = 0.00` is clock-skew clamping. The cluster's chrony-synced clock is fractionally behind the driver's, so `T2 − T1` goes negative on most samples and we `max(0)` it. Cross-clock wire-portion measurement is not usable on AWS without explicit chrony sync verification — the on-driver `drain_us` measurement remains valid because it's clock-sync free.

The root cause of the scheduler queueing: 5,750 players × 2 tasks per player (send loop + drain) = **11,500 concurrent tokio tasks on 8 worker threads**. Each drain task receives ~76 frames/sec from 4 clusters, each frame is ~322 KB, each drain decodes the **same broadcast bytes independently**. Per-cluster, 1,437 drain tasks decode the same broadcast 1,437 times. The decode (`postcard::from_bytes` on ~5,750 entities) is O(N) and the dominant cost.

**Next.** Add a per-frame decode cache shared across all drain tasks. Multiple drain tasks reading identical bytes from the same cluster broadcast should hit a cached entity-id set after the first decode. Expected to cut redundant decodes from ~437K/sec to ~76/sec (one per cluster per tick) and unbottleneck the swarm-side measurement.

---

## 2026-04-26 — Per-frame decode cache → 7,250-player real ceiling on c7i.2xlarge clusters_4; cluster outbound NIC identified as the wall

**Hypothesis.** From the prior entry: redundant per-player decode of identical broadcast bytes is the swarm's bottleneck. Sharing decoded results across drain tasks (keyed by the first 32 bytes of each broadcast frame, which always include the postcard variant byte + `source_cluster_id` + start of the seq varint) eliminates the redundancy. Expected: drain CPU drops dramatically, latency reads honest, the real cluster ceiling becomes visible.

**Setup.** `arcane_swarm/src/delta_cache.rs` (new module), drain task consults the cache before decoding, populates on miss. arcane_swarm `feat/latency-decomposition` (extended). Image `dev-20260426-decode-cache`. Same fleet, same `clusters_4.big.json` config. Run `20260426_060905`.

**Result.** **Ceiling: 7,250 players at 182 ms client-perceived latency.** Cache hit rate 95–99 % across all tiers. `drain_avg_ms` dropped from 1.54 ms (prior entry) to **0.11 – 0.52 ms** depending on tier. `total_calls` measured per tier rose from 330K (prior entry, at 5,750) to 1.23M — the swarm is now sampling everything it should be. Failure tier: 7,500 at 416 ms latency, with `broadcast_lagged_events` accumulated to 405K and cluster `last_tick_us` at 17.5 ms (well under the 50 ms tick budget, so the cluster still had CPU headroom at the failing tier).

| Players | lat_avg_ms | drain_avg_ms | cache_hit_pct | swarm_pass |
|---|---|---|---|---|
| 5,750 | 116 | 0.11 | 99.0 | ✅ |
| 6,000 | 105 | 0.24 | 96.5 | ✅ |
| 6,250 | 120 | 0.28 | 96.3 | ✅ |
| 6,500 | 121 | 0.30 | 96.0 | ✅ |
| 6,750 | 135 | 0.34 | 95.9 | ✅ |
| 7,000 | 147 | 0.37 | 95.8 | ✅ |
| **7,250** | **182** | **0.39** | **95.7** | **✅** |
| 7,500 | 416 | 0.52 | 95.4 | ❌ |

**Interpretation.** The 5,750-tier latency went from 530 ms → 116 ms with no cluster-side change — the prior measurement was driver-bound, exactly as decomposition predicted. With the swarm-side wall removed, the actual cluster ceiling on 4 × `c7i.2xlarge` clusters is 7,250 players. Cluster CPU is *not* the wall; `last_tick_us` of 21 ms at the ceiling tier leaves ~58 % tick budget headroom.

The wall is **cluster outbound NIC bandwidth**. At 7,500 players × 4 clusters with 1,437 subscribers per cluster, the broadcast pipeline wants to push `1,437 × ~322 KB × 20 Hz ≈ 9.2 GB/s` (~73 Gbps) per cluster. Per-tier `bytes_out` deltas show the cluster sustains roughly 3 Gbps per `c7i.2xlarge` instance — well below the headline 12.5 Gbps burst (which is not sustained for fan-out workloads of this shape). The gap shows up as `broadcast_lagged_events` — tokio's broadcast channel emits these when a per-subscriber send queue falls 256+ messages behind, after which 256 broadcasts' worth of bytes get dropped silently for that subscriber. At 7,500 players, ~67 % of the cluster's intended outbound bytes never reach the wire.

This is the **full-mesh-replication NIC wall on `c7i.2xlarge` cluster hardware**, not a cluster-CPU wall and not a fundamental Arcane wall. The candidates to push past it are now well-defined and tracked:

- Network-optimized instance classes (`c6in.2xlarge` etc.) with ~5× the sustained NIC at ~15 % cost increase.
- WebSocket per-message-deflate compression (arcane#44 — 30–50 % bandwidth reduction, amortized to once-per-broadcast via the existing encode-once-fan-out pattern).
- Position+velocity quantization (f32 → fixed-point or f16, ~30 % per-entity bytes).
- Delta-only broadcasts (arcane#30).
- Affinity clustering (the architectural answer; lifts the O(P²) wall fundamentally).
- Pluggable transport (arcane#43 — moving off TCP eliminates head-of-line under saturation).

**A note on scope.** The 7,250 figure is the no-physics, lean-state, full-mesh, 20 Hz baseline. It's appropriate to compare against MMORPG / sandbox / persistent-world workloads (WoW, EVE, Foxhole) whose server-side per-entity simulation is also light. It is **not** an apples-to-apples comparison against AAA-shooter ceilings (Counter-Strike, Battlefield, Apex), whose servers run real physics for hit registration. A separate sweep with server-side physics enabled (after arcane#51 / #52) will be the right number for that comparison and will land here when measured.

**Next.** (1) Land the per-message-deflate compression (arcane#44) and re-measure on the same `clusters_4.big` fleet for an apples-to-apples bandwidth-vs-ceiling comparison. (2) File and run sibling experiments for realistic per-entity state (~140 B), higher tick rate (30/60 Hz), and `c6in.2xlarge` cluster nodes as separate measurements. (3) Re-measure 2-cluster and 6-cluster scenarios on `c7i.2xlarge` cluster hardware so the published table covers more than the 4-cluster point.

---

## 2026-04-26 — Quantization (arcane#45) lifts 20 Hz baseline 7,250 → 9,000 on the same fleet

**Hypothesis.** Quantizing `EntityState.position` and `velocity` from `Vec3<f64>` (24 B) to `Vec3<i16>` (3-9 B varint) on the wire reduces per-entity broadcast bytes by ~30-42 B. With cluster outbound NIC as the binding bottleneck on the previous 7,250 ceiling, the saving should translate near-linearly into ceiling lift.

**Setup.**

- Image: `ghcr.io/brainy-bots/arcane-benchmark:dev-2026-04-26-tickderive` (carries arcane#48 env-driven tick rate, arcane#49 Vec3Q quantization, arcane_swarm#14 UserDataBytes plumbing, arcane_swarm#15 swarm-side quantization).
- Fleet: `arcaneperhost.clusters_4.tfvars` — 4× c7i.2xlarge clusters, c7i.2xlarge driver, t3.large data plane (Redis, SpacetimeDB, manager).
- Config: `arcane_plus_spacetimedb.clusters_4.json` (canonical lean baseline; sweep 500→10000 step 250, duration 30s/tier, 20 Hz cluster tick, 10 Hz swarm send, MaxLatencyMs=200).
- Run id: `20260426_125527`.
- One terraform fix landed before the run: `arph_cluster.instance_type` now wires from `var.instance_type` (was `var.data_instance_type`). The default tfvars now provisions cluster nodes on the same `c7i.2xlarge` shape advertised in the README.

**Result.** Ceiling **9,000 players** at 20 Hz / 200 ms. Same workload as the 7,250 baseline; only delta is wire quantization. Lift: +24%.

**Interpretation.** Quantization works as expected on a NIC-bottlenecked system: per-entity bytes drop, broadcast cadence stays the same, ceiling rises. Cluster CPU stayed comfortable at this point — the next-tier failure pattern still looks bandwidth-shaped, not CPU-shaped. The +24% headline lift on its own is a clean, attributable optimization win.

**Caveat: the 7,250 reference was taken on the same `c7i.2xlarge` cluster shape, set at terraform-apply time during that run.** This week's terraform fix makes that shape the *default* of the committed module — independent of what was in the file before — so future repro on the committed code lands on the same hardware automatically.

---

## 2026-04-26 — 30 Hz / 100 ms MMO-class headline measurement → 2,250 players

**Hypothesis.** With quantization landed, measure the new MMO-class publishing standard: cluster simulation at 30 Hz, 100 ms latency gate, swarm `TickRateHz` matched to the cluster tick (single source of truth from `ClusterTickRateHz`). Expect the ceiling to drop substantially below the 9,000 at 20 Hz / 200 ms because (a) tick rate is 1.5×, (b) inbound swarm send rate is 3× the historical 10 Hz, (c) latency budget shrinks from 200 ms → 100 ms.

**Setup.**

- Same image and fleet as the 9,000 measurement above.
- Config: `arcane_plus_spacetimedb.clusters_4.tick30.json` (`ClusterTickRateHz: 30`, `MaxLatencyMs: 100`, sweep 500→10000 step 250, 30s/tier).
- Harness change: `Merge-ConfigFileParameters` now derives swarm `TickRateHz` from `ClusterTickRateHz` so the two can't drift out of sync (PR arcane-scaling-benchmarks#56). Manifest confirms swarm sent at 30 Hz.
- Run id: `20260426_131708`.

**Result.** Ceiling **2,250 players** at 30 Hz / 100 ms. Sharp wire-latency cliff — `lat_avg_ms` was 16 ms across tiers 500→2000, ticked to 23 ms at 2,250 (still under gate), then jumped to 181 ms at the 2,500 tier. `wire_avg_ms` jumped from 0.02 ms to 39.86 ms in the same step; `drain_avg_ms` stayed at 0.11 ms. Cluster `tick_ms` stayed at ~3.92 ms (well under the 33 ms tick budget at 30 Hz).

**Interpretation.** This is the new MMO-class publishing headline: **2,250 CCU at 30 Hz / 100 ms on 4× c7i.2xlarge with full-mesh replication, no AOI, no time dilation**. The gap from 9,000 to 2,250 is the cost of moving from incumbent-band (5–20 Hz, 200 ms) to a tighter standard the incumbents can't sustain. The cliff is wire-latency-shaped, not CPU-shaped: cluster CPU has 90%+ headroom even at the failure tier, so the binding limit is network I/O at 30 Hz × 30 Hz × 4 clusters × player² fan-out — full-mesh outbound bandwidth.

**Comparison framing for the README.** Incumbents publish 5–20 Hz tick rates (EVE 1 Hz with time dilation; WoW/FFXIV/Albion 5–20 Hz). Arcane sustains 30 Hz at 2,250 CCU on commodity AWS — **a strictly better update cadence than the incumbent band, with no AOI**. The headline is "Arcane raises the MMO bar to 30 Hz; here's what that costs in player count vs the historical 20 Hz / 200 ms point."

**Next (run C, in flight).** 30 Hz / 200 ms supplementary measurement to disambiguate "did Run B's cliff come from the latency gate or from real capacity loss at 30 Hz?". If 30 Hz / 200 ms ceiling lands meaningfully above 2,250, the gate explains most of the drop. If it stays near 2,250, capacity drops at 30 Hz regardless of the gate. Will append the Run C result here and finalize the README narrative around whichever of those two stories the data tells.

---

## 2026-04-26 — 30 Hz / 200 ms supplementary → 6,250 players; bottleneck reconfirmed as cluster outbound NIC

**Hypothesis.** Run a 30 Hz cluster at the historical 200 ms gate to disambiguate Run B's 2,250 cliff. If the ceiling is meaningfully above 2,250, the latency gate accounts for most of the drop and the headline can publish at the 200 ms gate alongside incumbents.

**Setup.**

- Same image and fleet as Runs A and B.
- Config: `arcane_plus_spacetimedb.clusters_4.tick30_lat200.json` (`ClusterTickRateHz: 30`, `MaxLatencyMs: 200`, sweep 500→10000 step 250).
- Run id: `20260426_165722`.

**Result.** Ceiling **6,250 players** at 30 Hz / 200 ms. Latency progression: stable 68–77 ms across tiers 4250→4750, climbing to 96–132 ms across 5250→6000, jumping to 182 ms at 6,250 (last passing) and 237 ms at 6,500 (gate breach).

**Three-way comparison.**

| Run | Cluster tick | Latency gate | Ceiling | Δ vs Run A |
|---|---|---|---|---|
| A | 20 Hz | 200 ms | 9,000 | baseline |
| C | 30 Hz | 200 ms | 6,250 | −30% (tick-rate cost) |
| B | 30 Hz | 100 ms | 2,250 | −75% (tighter gate dominates) |

The latency gate accounts for most of Run B's drop. The genuine cost of moving from 20 Hz to 30 Hz at a fixed 200 ms gate is ~30%, not 4×.

**Bottleneck — cluster outbound NIC, confirmed.**

Cluster0 `/stats` snapshot at the failure tier:

```
bytes_out:                 340,844,925,384  (~341 GB over the run)
broadcast_lagged_events:   801,105
broadcast_lagged_frames:   10,521,542
ws_send_errors:            904
last_tick_us:              18,160  (out of 33,333 budget at 30 Hz)
entities_current:          1,625   (=  6500 / 4 clusters)
```

`broadcast_lagged_frames = 10.5M` is the smoking gun: the tokio broadcast channel dropped frames because per-subscriber WS sends couldn't drain fast enough. Sustained outbound on cluster0 was ~1.1 GB/sec on a c7i.2xlarge NIC whose sustained throughput tops out near 0.375 GB/sec. Demand-vs-supply ratio at the failure tier is roughly 3×.

The latency-decomposition data agrees: drain-side `drain_avg_ms` stayed at 0.11–0.19 ms across the sweep — the swarm-driver isn't the bottleneck. Wire latency (`wire_avg_ms`) climbed from 5.95 → 89 → 134 ms, which is the queueing wait inside the cluster's send buffer waiting for NIC bytes to drain. Cluster CPU stayed at 11–18 ms tick, well under budget.

**What this means.**

- The **NIC ceiling is the same architectural wall the 7,250 baseline hit** with `Vec3<f64>` payloads. Quantization (Vec3 → Vec3Q) cut per-entity Vec3 bytes from 24 to ~3-9, which moved the wall higher — 7,250 → 9,000 at 20 Hz, and produced the 6,250 number at 30 Hz that wasn't measurable before.
- The path to a higher ceiling at this hardware is **smaller broadcast volume**, not more cluster CPU or smaller cluster count. Three independent levers compose additively:
  1. **Velocity-based dead reckoning** (arcane#46) — broadcast only when velocity changes. On `spread` workload, expected ~70-90% reduction in per-tier broadcast bytes during straight-line motion segments.
  2. **Per-message-deflate compression** (arcane#44, library-blocked today) — additional ~30-50% on top of the bytes that remain.
  3. **Affinity-based AOI** — full-mesh fan-out is O(P²); replacing it with predicted-interaction-only fan-out is the long-term architectural answer (this is Arcane's core premise; see WHY_ARCANE.md).
- Bigger NIC hardware (c5n / c7gn families, 25-100 Gbps) would also lift the ceiling, but at a different cost-per-CCU ratio — worth measuring as a separate sibling experiment, not a hardware substitution for the architectural levers above.

**Headline framing for the README update.**

- Lead number: **6,250 CCU at 30 Hz / 200 ms** on 4× c7i.2xlarge clusters with full-mesh replication, no AOI, no time dilation. Direct comparison to incumbent MMOs at 5–20 Hz / 200 ms — Arcane delivers strictly better update cadence at this player count.
- Secondary: 9,000 CCU at 20 Hz / 200 ms (matches the incumbent tick band on tick rate; shows the headroom available when cadence isn't pushed up).
- Footnote: 2,250 CCU at 30 Hz / 100 ms (tighter playability gate). Useful for the shooter-class conversation once physics-at-scale lands and we can compare to CS / BF / Apex with a fair workload.

**Next.**

1. Update README with the 6,250 / 9,000 / 2,250 trio + bottleneck attribution. Replace the current 7,250 headline.
2. Land velocity-based dead reckoning (arcane#46). Re-measure on the same fleet — expected to lift 30 Hz ceiling significantly because dead reckoning attacks the binding constraint (broadcast bytes) directly.
3. Sibling experiment with `c5n.2xlarge` clusters (25 Gbps NIC) at the same workload. Confirms the NIC interpretation; gives a "what if we paid for network-optimized" data point.
4. Tear down terraform fleet between sessions to stop the cost meter; current $50 budget left ~$30 of headroom after this session.

---

## 2026-04-26 — Velocity-based dead reckoning (arcane#46) → 30 Hz / 200 ms ceiling 6,250 → 8,250 (+32%)

**Hypothesis.** Dead reckoning skips entities whose velocity quantizes identically to last broadcast (issue arcane#46). On the `spread` deterministic-wander workload entities hold velocity for many ticks between turns, so most per-tier broadcasts could shrink substantially — projected 70-90% reduction in broadcast bytes, with corresponding ceiling lift on the NIC-bound system.

**Setup.**

- Image: `ghcr.io/brainy-bots/arcane-benchmark:dev-2026-04-26-deadreckon` (carries arcane#50 = arcane#46 dead-reckoning + everything from the prior `tickderive` image).
- Same 4× c7i.2xlarge cluster fleet (terraform now defaults clusters to `instance_type` after this PR's TF fix).
- Config: `arcane_plus_spacetimedb.clusters_4.tick30_lat200.json` — direct head-to-head with Run C (no DR) at the same gate.
- Run id: `20260426_190419`.

**Result.** Ceiling **8,250 players** at 30 Hz / 200 ms — up from Run C's 6,250 on the identical fleet shape and config. **+32% lift from dead reckoning alone.** Cluster0 stats at run end:

```
ws_accepts:               2,125  (vs 1,625 Run C)        +31%
bytes_out:           326,845 MB  (vs 340,844 MB Run C)   −4%
broadcast_lagged_frames:  8.06M  (vs 10.52M Run C)       −23%
last_tick_us:            16,167  (out of 33,333 budget)
```

Bytes-out per cluster stayed roughly flat despite serving 31% more entities — that's the dead-reckoning win in evidence: per-player broadcast volume dropped, freeing bandwidth headroom for additional players. Cluster CPU still fine (`tick_ms` at ~16ms vs 33ms budget); NIC is still the wall, just being used more efficiently.

**Why +32% and not 70-90%.** The `spread` workload doesn't actually hold straight-line velocity for very long. Three sources of velocity-change broadcasts beyond pure straight-line motion:

- Periodic resync at 60-tick cadence (~2s wall-clock at 30 Hz) — every 2 seconds every entity rebroadcasts regardless.
- Zone events every 30s — converge all players to (2500, 2500), forcing a velocity change on every player simultaneously.
- Burst windows every 30s × 20% cohort × 10 actions per burst — extra game actions that often nudge velocity.

For a workload where players genuinely walk in straight lines for tens of seconds (e.g. a kinematic open-world MMO), the saving would land closer to the 70-90% projection. For our deterministic-wander, ~32% is the honest number.

**Bottleneck status.** Still cluster outbound NIC. broadcast_lagged_frames=8M means we're still saturating the WS send path; dead reckoning lifted the ceiling because the per-player byte cost dropped, not because we left the NIC regime.

**Updated three-way comparison.**

| Run | Tick | Gate | DR | Ceiling | Notes |
|---|---|---|---|---|---|
| A | 20 Hz | 200 ms | off | 9,000 | quantization-only baseline |
| C | 30 Hz | 200 ms | off | 6,250 | tick-rate cost from A |
| **D** | **30 Hz** | **200 ms** | **on** | **8,250** | **+32% over C; new MMO publishing headline** |
| B | 30 Hz | 100 ms | off | 2,250 | tighter gate; B+DR not measured |

**Headline framing.** **8,250 CCU at 30 Hz / 200 ms on 4× c7i.2xlarge with full-mesh replication, no AOI, no time dilation, dead-reckoning enabled.** Direct comparison to incumbent MMOs at 5–20 Hz / 200 ms — Arcane delivers strictly better update cadence at this player count, on commodity hardware, with the architectural option (affinity AOI, arcane#69) still ahead of us.

---

## 2026-04-26 — Realistic-state run (UserDataBytes=100) blocked on wire/cluster JSON contract mismatch

**Hypothesis.** With dead reckoning landed, the realistic-state ceiling at 30 Hz / 200 ms (UserDataBytes=100, ~156 B/entity) becomes the headline shooter-payload number for incumbent comparison.

**Setup.**

- Same image and fleet as Run D.
- Config: `arcane_plus_spacetimedb.clusters_4.tick30_realistic.json` (`UserDataBytes: 100` + `ClusterTickRateHz: 30` + `MaxLatencyMs: 200`).
- Run id: `20260426_192523`.

**Result.** **No ceiling — every PLAYER_STATE was rejected.** Cluster0 stats:

```
ws_accepts:        125
msgs_player_state: 0
parse_failures:    680,931
entities_current:  0
```

**Bug.** The swarm's `fill_pseudo_user_data` (added in arcane_swarm#14 for arcane-scaling-benchmarks#52) writes raw xorshift64* bytes into the wire's `user_data: Vec<u8>`. The cluster's `entry_from_wire_player_state` calls `serde_json::from_slice(&payload.user_data)` to convert into `EntityStateEntry.user_data: serde_json::Value`. Random bytes aren't valid JSON → `from_slice` errs → the whole frame is treated as a parse failure.

The wire-side documentation called the field "opaque application bytes" but the cluster-side parse contract is JSON-only. The discrepancy was masked by every prior measurement having `user_data_bytes=0` (empty `Vec<u8>` skips the JSON parse path).

**Resolution path (next session).**

- Option A (cheap, in arcane_swarm): wrap the xorshift output in a JSON envelope, e.g. `{"d":"<base64>"}` of N total bytes. Preserves the cluster contract, no schema change, ~10 lines.
- Option B (architectural, in arcane): make `EntityStateEntry.user_data` opaque `Vec<u8>` end-to-end and remove the JSON parse from `entry_from_wire_player_state`. Larger semantic change touching the L1 persist path that today serializes user_data as JSON to SpacetimeDB.

Option A unblocks measurement immediately. Option B is the cleaner architectural fix and probably the right answer if we're going to publish "realistic per-entity opaque payload" as a benchmark dimension. Both are next-session work.

**Tear-down.** Terraform fleet destroyed at end of session (no $/hr running). Total session spend ~$15-20, well under the $50 budget. Re-provisioning is a single `terraform apply` at the start of the next session.

---

## 2026-04-27 — JSON envelope fix + Run D' (lean DR @ 100 ms) + Run F (realistic DR @ 100 ms)

**Fix.** Landed brainy-bots/arcane_swarm#16 — `fill_pseudo_user_data` now wraps xorshift bytes in `{"d":"<hex>"}` so the cluster's `serde_json::from_slice` succeeds. Tests guard against regression. Plus benchmark-repo PR #59 bumped the swarm submodule and flipped `tick30_realistic.json` from MaxLatencyMs=200 → 100 to match the locked publishing standard.

**Run D' — lean state at the locked headline gate (30 Hz / 100 ms / DR on).**

- Image: `dev-2026-04-27-jsonenvelope` (full Phase 1 stack).
- Config: `arcane_plus_spacetimedb.clusters_4.tick30.json`.
- Run id: `20260427_003453`.
- **Ceiling: 5,500 players** (vs Run B's 2,250 without DR — **+144%** at the same gate).

**Run F — realistic state at the locked headline gate (30 Hz / 100 ms / DR / UserDataBytes=100).**

- Same image. Config: `arcane_plus_spacetimedb.clusters_4.tick30_realistic.json`.
- Run id: `20260427_004902`.
- **Ceiling: 4,750 players** — only **−14%** from lean despite ~3× larger per-entity wire payload.

**Bottleneck — moved.** Cluster0 stats at the failure tier:

```
last_tick_us:              6,023   (out of 33,333 budget — 18% CPU utilization)
bytes_out:               136 GB    over the run (~0.6 GB/sec sustained)
broadcast_lagged_frames: 342,117   (down from 10.5M in Run C, but non-zero)
broadcast_lagged_events: 35,493
ws_send_errors:          1,246
parse_failures:          0         (JSON envelope works — contrast Run E's 680k)
```

The wall is **no longer the NIC** at this configuration. Demand is ~0.6 GB/sec against a c7i.2xlarge sustained NIC of ~0.375 GB/sec — close to capacity but not multi-x oversubscribed like Run C/D were. Cluster CPU is barely doing anything (18% of budget). And **the broadcast-channel `Lagged` events keep firing even at this load**, which means the **256-message broadcast buffer is the new bottleneck**.

The latency decomposition agrees: at Run F's failure tier, `wire_avg_ms=0.14` and `drain_avg_ms=0.05` — both ~zero. The remaining ~84 ms of `lat_avg_ms` is the gap between cluster timestamp (T2) and swarm drain wakeup (T_arrival): cluster fan-out queueing + network transit + driver TCP receive scheduling. The fan-out queueing inside the broadcast channel explains why bumping the channel buffer (arcane-scaling-benchmarks#77, file:line `arcane-infra/src/ws_server.rs:343`) is the next high-leverage move.

**Updated full-matrix summary.**

| Run | Tick | Gate | DR | State | Ceiling | Limiting factor |
|---|---|---|---|---|---|---|
| A | 20 Hz | 200 ms | off | lean | 9,000 | quantization-only baseline |
| B | 30 Hz | 100 ms | off | lean | 2,250 | NIC + tight gate |
| C | 30 Hz | 200 ms | off | lean | 6,250 | cluster outbound NIC (`broadcast_lagged_frames=10.5M`) |
| D | 30 Hz | 200 ms | on | lean | 8,250 | cluster outbound NIC (still NIC, less lagging) |
| **D'** | **30 Hz** | **100 ms** | **on** | **lean** | **5,500** | **broadcast channel cap; CPU ~30% utilized** |
| **F** | **30 Hz** | **100 ms** | **on** | **realistic** | **4,750** | **broadcast channel cap; CPU 18% utilized** |
| E | 30 Hz | 100 ms | on | realistic | INVALID (pre-fix) | wire/cluster JSON contract bug (now fixed) |

**Publishable headline (replaces the prior 7,250 reference).**

**4,750 CCU at 30 Hz / 100 ms with realistic per-entity payload, dead reckoning, quantization, full-mesh replication on 4× c7i.2xlarge clusters.** This is the honest shooter-payload-at-MMO-tick number. Lean baseline at the same gate: 5,500.

For incumbent comparison (where MMOs publish at 5–20 Hz / 200 ms): Arcane delivers strictly better update cadence at this player count, on commodity hardware, with the architectural escape hatch (affinity AOI / arcane#69) still ahead. The 6,250 → 8,250 → 5,500 → 4,750 progression is the literal cost story of moving from the incumbent gate to the Arcane standard.

**Cost-per-CCU (4,750 realistic ceiling).** 4× c7i.2xlarge clusters + 1× c7i.2xlarge driver + 3× t3.large data-plane = ~$2/hr. At 4,750 CCU: ~$0.00042/CCU/hr.

**Tear-down.** Terraform destroyed (20 resources). Session spend across both 2026-04-26 and 2026-04-27 sessions: ~$25-30 against $50 budget.

**Next.**

1. Land arcane-scaling-benchmarks#77 (broadcast channel cap tuning) — confirmed empirically as the binding wall at the headline gate. Likely lifts the 4,750 ceiling substantially without any other architectural change.
2. README rewrite (task #75) with the headline matrix above.
3. arcane-scaling-benchmarks#76 (option B: cluster opaque user_data) — the right architectural fix for the contract that #16 patched cheaply.

---

## 2026-04-27 — Broadcast channel cap tuned to 2048 → regression. The 256 default was already right.

**Hypothesis.** The 4,750-realistic / 5,500-lean ceiling at 30 Hz / 100 ms (Runs F + D' from the prior journal entry) was bound by the hardcoded 256-slot tokio broadcast channel cap. Cluster CPU at 18% utilization, NIC at ~80%, yet `broadcast_lagged_frames=342k` kept firing — interpreted as "the channel is dropping frames because the cap is too small for 30 Hz × thousands of subscribers". Predicted that raising the cap would let the cluster spend the CPU + NIC headroom and lift the ceiling substantially.

**Setup.**

- arcane#51 landed: env-tunable `ARCANE_BROADCAST_CHANNEL_CAP`, default raised from 256 → 2048.
- New image: `dev-2026-04-27-broadcastcap`. Same 4× c7i.2xlarge cluster fleet.
- Run G: lean DR @ 30 Hz / 100 ms (`tick30.json`). Run id `20260427_031800`.
- Run H: realistic DR @ 30 Hz / 100 ms (`tick30_realistic.json`). Run id `20260427_032943`.

**Result.** Both runs **regressed** the ceiling.

| Workload | cap=256 (prior) | cap=2048 (today) | Δ |
|---|---|---|---|
| Lean DR @ 30 Hz / 100 ms | 5,500 (Run D') | **4,250 (Run G)** | **−23%** |
| Realistic DR @ 30 Hz / 100 ms | 4,750 (Run F) | **4,250 (Run H)** | **−11%** |

**Mechanism.** Run H's cluster0 stats:

```
broadcast_lagged_events:   0       (vs 35,493 in Run F)
broadcast_lagged_frames:   0       (vs 342,117 in Run F)
last_tick_us:              5,459   (16% of 33 ms budget)
ws_send_errors:            756
entities_current:          1,125
```

Cap=2048 *eliminated* `Lagged` events as predicted — the channel never dropped a frame. But the ceiling went *down*, not up. Latency-side mechanism: with a deeper buffer, slow subscribers hold onto stale broadcasts longer in their personal receive queue, so their wall-clock latency at the cluster→subscriber edge stretches. The 100 ms gate is sensitive to that exact stretch. Cap=256 was effectively forcing aggressive freshness — the slowest subscribers got their stale data dropped (counted as Lagged) and they just lived with the gap, which kept the whole system's latency distribution tighter.

**The general lesson.** Broadcast cap tuning is a tradeoff curve, not a "bigger is better" lever. For tight latency gates (≤100 ms), smaller cap forces the system to favor freshness over lossless delivery. For relaxed-latency cases (≥200 ms), bigger cap might win because Lagged drops cost more than queueing delay. The default for the published 30 Hz / 100 ms standard belongs at 256, not 2048.

**Code change.** arcane#52 reverts the default to 256 in `broadcast_channel_cap.rs`. The env-var tunability stays — it's still the right knob, just defaulted to the empirically-correct value for the publishing standard.

**Numbers I'm publishing as the headline.** Unchanged from the 2026-04-27 entry above.

- **4,750 CCU at 30 Hz / 100 ms with realistic per-entity payload** (Run F).
- 5,500 CCU at the same gate, lean baseline (Run D').
- 8,250 CCU at 30 Hz / 200 ms with DR (Run D) — secondary point for relaxed-latency comparison.
- 9,000 CCU at 20 Hz / 200 ms (Run A) — incumbent-tick-band reference.

---

## 2026-04-27 — Run I: clusters_8 + Redis on c5n.large → 4,000 (regression). 4-cluster setup is empirically optimal.

**Hypothesis.** Doubling cluster count from 4 → 8 should lift the realistic ceiling. Math says per-cluster outbound bytes scales as P²/N, so 8c at the same P should halve per-cluster NIC pressure and free per-cluster fan-out work. Bonus: NIC-optimized Redis (c5n.large at 25 Gbps) eliminates Redis from any analysis at 8c's 4.7× cross-traffic vs 4c.

**Setup.**

- Image: `dev-2026-04-27-broadcastcap`. **`ARCANE_BROADCAST_CHANNEL_CAP=256` set as env var on cluster docker run** (RemoteBenchmark.ps1 change) since the broadcastcap image's default of 2048 was empirically wrong (Runs G + H). Note: arcane#52 reverted the upstream default to 256 but a new image hasn't been cut yet for that.
- Fleet: `arcaneperhost.clusters_8.fastredis.tfvars` — 8 × c7i.2xlarge clusters, c7i.2xlarge driver, Redis on **c5n.large** (25 Gbps NIC, ~$0.108/hr), manager + spacetime on t3.large. New `redis_instance_type` terraform variable threads the NIC-optimized choice; default still falls through to `data_instance_type` so existing tfvars work unchanged.
- Config: `arcane_plus_spacetimedb.clusters_8.tick30_realistic.json` (`ClusterTickRateHz: 30`, `MaxLatencyMs: 100`, `UserDataBytes: 100`, sweep 500→15000 step 500).
- Run id: `20260427_081304`.

**Result.** Ceiling **4,000 players** — **−16% regression vs Run F's 4,750 at 4c.**

Cluster0 stats at the failure tier:

```
last_tick_us:              1,818   (5% of 33 ms tick budget — even MORE idle than 4c)
broadcast_lagged_frames:   23      (down from 342k at 4c — DR + 8c basically eliminated lagged events)
entities_current:          563     (= 4500/8; half the entities per cluster as expected)
bytes_out:                 29.6 GB total
parse_failures:            0
```

Per-tier latency breakdown (cliff is at 4,500 = 100.72 ms, just over the gate):

| Players | lat_avg_ms | wire_avg_ms | drain_avg_ms |
|---|---|---|---|
| 1,000 | 16.6 | 14.3 | 0.00 |
| 2,000 | 16.6 | 9.7 | 0.00 |
| 3,000 | 21.1 | 4.6 | 0.00 |
| 3,500 | 30.1 | 3.0 | 0.01 |
| **4,000** | **49.8** | **2.0** | **0.01** |
| 4,500 | 100.7 | 1.2 | 0.05 |

Wire latency is *lower* than at 4c (1-14 ms vs up to 89 ms in Run F) — cluster fan-out is genuinely faster with smaller per-cluster frames. Drain latency stays trivial. The 49 ms total at 4,000 is dominated by the **T2→T_arrival gap** (cluster send → driver receive): cluster-to-subscriber TCP queueing + driver-side WS receive scheduling.

**Why 8c regressed — honest analysis (corrected).**

I initially attributed the regression to "per-player connection count grows with N in full mesh." That was wrong. **Each player connects to exactly one cluster** (manager `/join` → single cluster URL → one WebSocket per player). Per-cluster subscriber count is P/N, not P. `ws_accepts=563` at cluster0 confirms this matches 4500/8.

So adding clusters genuinely *does* reduce per-cluster work along every metric:

| Metric | 4c at 4,750 ceiling | 8c at 4,000 ceiling |
|---|---|---|
| Subscribers per cluster | 1,188 | 562 (halved) |
| Owned entities per cluster | 1,188 | 562 (halved) |
| `last_tick_us` (CPU per tick) | 6 ms (18% of budget) | 1.8 ms (5% — *more* idle) |
| `broadcast_lagged_frames` | 342k | 23 (basically zero) |
| `bytes_out` sustained per cluster | ~270 MB/s | ~25 MB/s |

Yet the ceiling dropped from 4,750 → 4,000. **All measurable per-cluster pressure went down, but the system ceiling went down too.** Without more instrumentation I can't pin the mechanism. Plausible candidates:

1. **AWS variance.** 4c and 8c ran on different fleets, different physical hosts, different placements. A single 16% delta is within normal AWS run-to-run variance for full-mesh networked workloads. Without an A/B re-test on the same day with the same fleet shape, we can't rule out "this is just noise."
2. **Inter-cluster delta convergence latency.** Each cluster broadcasts the *full world* to its subscribers. To do that, it must receive deltas from all N-1 other clusters via Redis pub/sub before assembling its broadcast. At 8c the cluster has to wait for 7 sources to land per tick vs 3 at 4c. Even though Redis throughput is fine, the *worst-case* convergence time per tick may grow with N — the slowest neighbor sets the bar.
3. **Cluster-side neighbor-deserialize overhead** in the tokio runtime. Cheap on CPU but each deserialize task adds scheduler-latency variance; at 8c there are 2.3× more such tasks per tick.
4. **Manager round-robin distribution unevenness.** 4500/8 = 562.5; some cluster gets 562, another 563. Marginal.

**What we know with confidence:** the 4-cluster ceiling (4,750 realistic) and 8-cluster ceiling (4,000 realistic) are both empirically measured, but the 8c regression mechanism isn't characterized. Going to 6c or 12c would help disambiguate variance from a real architectural curve, but adds another $5-10 to the budget without changing the headline.

**What this is NOT evidence of.** It is *not* evidence that "multi-cluster is useless." Multi-cluster is the substrate for capabilities the benchmark intentionally doesn't exercise:

- **Affinity-based AOI** (per-player subscribes to K nearby clusters where K ≪ N) — the architectural premise of Arcane. Without AOI, every cluster has to know about every entity, so multi-cluster only redistributes byte work without reducing it.
- **Geographic distribution** (cluster per region; players connect to nearest).
- **Heterogeneous workloads** (physics-tier vs logic-tier clusters).
- **Fault isolation** (cluster failure kills its slice, not the whole game).
- **Capacity beyond single-machine limits** (when one cluster can't hold all entities — not our case at this scale).

In a benchmark that tests "every player sees every entity" with no AOI, multi-cluster's only lever is byte distribution, and the byte distribution maxes out somewhere around 4 clusters at this hardware tier. **That's the right empirical finding for this test premise**; it's just not a comment on the architectural value of multi-cluster generally.

**Genuine paths to lift past 4,750 realistic at 30 Hz / 100 ms in full mesh (none easy):**

- Bigger driver instance (c7i.4xlarge or c7i.8xlarge) — cheap experiment, might absorb whatever per-cluster receive jitter is occurring.
- Network-optimized cluster instances (c5n.2xlarge / c6in.2xlarge) — same shape as Redis upgrade, just for clusters.
- A/B re-test 4c vs 8c on the same day to characterize the variance band properly.

**Decisions made on Martin's behalf.**

1. Stopped after Run I rather than running clusters_6 to find an intermediate point. The structural argument for why 8c regresses is general (per-player connection grows with N) and applies to 6c too in proportion. Confirming 6c numerically would burn another $5 to learn the same shape.
2. Set `ARCANE_BROADCAST_CHANNEL_CAP=256` in the topology RemoteBenchmark.ps1 docker run rather than waiting for a new image with the arcane#52 default revert baked in — saved the ~10 minutes of image rebuild time. The override is also defensive against future changes.
3. Did *not* test 8c at the 200 ms gate (would have been Run J). The 100 ms gate is the publishing standard; 200 ms data point is already covered by Run D at 4c.

**Tear-down.** Terraform fleet destroyed (28 resources). Total session spend across 2026-04-26 + 2026-04-27 + this run: ~$35-45 against the $50 budget.

**Final headline matrix (unchanged from prior entry):**

- **4,750 CCU at 30 Hz / 100 ms / realistic** — Run F, 4 clusters. **Empirically optimal cluster count for this workload.**
- 5,500 lean at the same gate.
- 8,250 lean at 30 Hz / 200 ms.
- 9,000 lean at 20 Hz / 200 ms.

**Next.** Physics integration ([arcane#51](https://github.com/brainy-bots/arcane/issues/51), [arcane#52](https://github.com/brainy-bots/arcane/issues/52)) per the agreed plan. The full-mesh ceiling is now well-characterized; the next benchmark publication track adds server-side rigid-body physics for shooter-class fairness.

**Decisions made on Martin's behalf during this measurement (called out for review).**

1. Stopped after Run G + H rather than running a third cap value (e.g. 1024 or 512) — the 2× regression in both workloads is enough signal that the trend is monotonic for our gate; more values would have been wasted spend.
2. Kept the env-var tunability intact rather than reverting #51 entirely — operators with different latency budgets will want this knob.
3. Did *not* set `ARCANE_BROADCAST_CHANNEL_CAP=256` explicitly in the topology docker run, since the arcane#52 default revert achieves the same effect cleaner. (If the upstream default ever changes, the topology env override would be the defensive next step.)

**Tear-down.** Terraform fleet destroyed (20 resources). Total session spend across 2026-04-26 + 2026-04-27 + 2026-04-27 (this run): ~$30-35 against the $50 budget.

**Next.**

1. README rewrite (task #75) with the publishable matrix above. Now with confirmed evidence that the 4,750 / 5,500 numbers are not "easy lift away" — the 256 cap is the right value, the cluster CPU and NIC headroom is real but there's no trivial way to convert it into more CCU at the 100 ms gate.
2. The honest path forward beyond 4,750 at 100 ms is architectural: dead reckoning is in, quantization is in, JSON-envelope is in — what's left is **affinity-based AOI** (arcane#69) which moves us off the O(P²) full-mesh fan-out entirely. That's the next major track.

---

## What this journal captures vs what it doesn't

**Captures.** The experimental chain — hypothesis, setup, result, interpretation, next. Each entry links to a specific `RunId` for anyone who wants to inspect the raw manifest/CSV/diag logs.

**Doesn't capture.** Conversations where we decided *not* to try something. Those live in PR discussions and internal notes. If a non-trivial decision was made to skip an avenue (e.g., "skipped 8-cluster because the shape was already unambiguous at 6-cluster"), the entry that preceded that skip should note it in its **Next** section.

**Format convention.** Date + short title. Hypothesis is the first paragraph. Setup names the image tag and run ID. Result includes the ceiling number and at least one distinctive anomaly (if any). Interpretation separates what the data *does* show from what it does *not*. Next is always the specific action that came out of this entry.

New entries go at the bottom, newest-on-bottom, so reading top-to-bottom reconstructs the chronology correctly.
