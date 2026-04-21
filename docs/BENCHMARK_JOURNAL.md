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

**Setup.** Arcane 2-cluster AWS run using the codebase as it existed before this week's work. All server-side roles (cluster × 2, Redis, SpacetimeDB, manager) on `t3.large` (2 vCPU burstable, 8 GiB). Driver `c7i.2xlarge` (8 vCPU). Config `arcane_plus_spacetimedb.clusters_2.json` (start 1500, step 250, max 6000). Instance types confirmed by 2026-04-22 CloudTrail audit — earlier journal drafts and the README incorrectly stated cluster nodes were `c7i.2xlarge`; they were never that. Corrected here and everywhere else on 2026-04-22.

**Result.** Ceiling appeared to be 2000. Failure mode looked like ramp-timeout at 2250 players.

**Interpretation at the time.** Assumed we had hit some CPU or memory limit on the cluster at ~1800-2000 players.

**Actual cause (discovered later).** Container default `nofile=1024` ulimit. The cluster's `listener.accept()` loop hit EMFILE at exactly 1007 accepted sockets per cluster (1000 clients + ~7 internal FDs), silently exited on Err, and every subsequent connection attempt was refused. The classifier attributed this to "driver_or_network" because cluster CPU/broadcast/WS-send counters were all clean — the cluster kept ticking idle with no new connections.

**Next.** Add `--ulimit nofile=65536:65536` to every benchmark container's `docker run`.

---

## 2026-04-21 — ulimit fix

**Hypothesis.** The 2000-cap is the container's FD limit, not a cluster or workload limit.

**Setup.** Same fleet as prior run, plus `--ulimit nofile=65536:65536` added to every docker run in both `AwsArcanePerHost` and `AwsSpacetimeOnly` topologies (PR arcane-scaling-benchmarks#35). Rebuilt image tag `dev-20260421-observability`. Same config (`clusters_2`, start 500, step 250, max 6000).

**Result.** Run `20260421_070438`. Ceiling moved from 2000 → **3500 players**. Failure mode changed from silent accept-stop to cluster container OOM-kill at 3750 (anon-rss 6.5 GB on 16 GB instance).

**Interpretation.** The ulimit was the entire reason for the 2000 cap. The true cluster ceiling on `t3.large` (8 GiB) is ~1750 clients per cluster (RAM-bound via per-connection state; 6.5 GB anon-rss on an 8 GB instance). The earlier "classifier attributed to driver_or_network" was a false signal — there was no CPU saturation anywhere.

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

**Setup.** Config `spacetimedb_only.wide.json` (step 250, max 6000). AwsSpacetimeOnly topology: one `t3.large` for SpacetimeDB (same box class every other server role uses) + one `c7i.2xlarge` for driver. Image `dev-20260421-stdb-wide`. Run `20260421_151956`.

**Result.** Ceiling **1750 players** at ~51 ms latency. Server became unreachable at 2000 (SpacetimeDB hit its single-node cap; failure mode: connection refused, not latency climb).

**Interpretation.** This is SpacetimeDB's ceiling on this hardware: one node, architectural cap, no horizontal scaling path. Latency stays flat at the tick-floor right up to the crash — SpacetimeDB is fine until it isn't. This is the number the "Arcane vs SpacetimeDB" comparison points back to.

---

## 2026-04-21 — Arcane 2-cluster (canonical run)

**Setup.** Config `arcane_plus_spacetimedb.clusters_2.json`, 4 clusters of... wait, 2 clusters. Image `dev-20260421-client-lat`. Run `20260421_145648` (third attempt after two transient AWS retries).

**Result.** Ceiling **3500 players** at ~50 ms. Failure mode: cluster 1 OOM-killed at 3750 (anon-rss 6.5 GB on 8 GiB `t3.large`).

**Interpretation.** At N=2, per-cluster workload is bound by RAM: each cluster holds roughly the full world's entities (own + one neighbor) plus ~1800 local WS connection states. 6.5 GB is the observed cap on an 8 GiB `t3.large`; beyond ~1800 clients per cluster we OOM. Task #62 tracks a heap-profile investigation.

---

## 2026-04-21 — Arcane 4-cluster (canonical run, first major data point)

**Setup.** `arcane_plus_spacetimedb.clusters_4.json` (added same day; ArcaneClusterCount=4, max 10000). Run `20260421_155106`.

**Result.** Ceiling **6000 players** at 126 ms latency. Failure mode: latency gate triggered at 6250 (276 ms). `broadcast_lagged_events = 0` across all four clusters at every passing tier — clean delivery.

**Interpretation.** Near-linear scaling from 2c (3500) → 4c (6000), but with a clear latency-climb shape: ~50 ms at low tiers, rising smoothly to 126 ms at the ceiling. The climb reflects full-mesh replication cost growing per-cluster with N (each of 4 clusters receives 3 neighbors' state vs 1 neighbor at N=2). RAM is no longer binding (per-cluster local count dropped from ~1800 to ~1500); per-cluster CPU — only 2 vCPU on `t3.large`, further constrained by the burstable CPU-credit economy under sustained load — is now the proximate limit.

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

**Hypothesis.** Bounding the rayon pool to half the node's cores leaves the other half reliably available for tokio subscriber tasks. Expected: broadcast_lagged drops to near-zero, latency stays monotonic, ceiling moves up cleanly. (Thinking at the time assumed cluster nodes were `c7i.2xlarge` / 8 vCPU, so the bound would be 4 threads. CloudTrail audit on 2026-04-22 showed they were actually `t3.large` / 2 vCPU — `num_cpus/2` on 2 vCPU = 1 thread, i.e. effectively serial. The hypothesis was tested on hardware that could never have distinguished it from the serial baseline.)

**Setup.** arcane#41 (pool sized by `max(1, num_cpus/2)`, `ARCANE_CLUSTER_ENCODE_THREADS` env override). Submodule bumped in arcane-scaling-benchmarks#44. Image `dev-20260422-bounded-rayon`. Config `clusters_4`. Run `20260422_010033`.

**Result.** Ceiling **5750 players** (LOWER than serial's 6000 and lower than unbounded's 6750). Latency at 6000 = 277 ms (gate violated, tier failed). `broadcast_lagged_events` still climbing to ~340-425k per cluster. Non-monotonic latency shape unchanged from the unbounded run (dips to 50 ms at 5000-5750, same masking pattern).

**Interpretation.** Hypothesis falsified. Bounding rayon did NOT meaningfully reduce broadcast lag. The serial-encoding baseline (arcane#40 reverted to serial behavior in effect because we've done both tests) had **zero lag across all clusters** at 6000 players — serial is strictly better on delivery quality than any parallel variant we've tried.

**New interpretation.** The lag mechanism isn't primarily rayon-vs-tokio core contention. Looking at the data more carefully:

- Cluster's per-tick CPU is within budget (`tick_us` ≤ 100 ms even at ceiling tiers).
- Driver (swarm) CPU is sustained at **700-800% of one core** from about 1000 players onward across every run. The swarm's 8-vCPU node is fully saturated.
- `broadcast_lagged_events` growth rate is roughly constant across tiers once it begins, which fits a constant-saturation bottleneck (driver) better than a scale-with-load bottleneck (cluster CPU).

Revised mechanism: **the driver's TCP recv buffer fills because its tokio tasks can't process incoming WS frames fast enough** (driver is CPU-saturated). TCP backpressure propagates to the cluster's send side; the cluster's per-subscriber send tasks `await` on a blocked socket; they stop draining the broadcast `recv` side; the producer outpaces them; `Lagged` accumulates. Parallel encoding *widens* this gap (producer encodes faster, driver still can't catch up), which is why parallel variants have more lag than serial — nothing to do with intra-cluster thread scheduling.

If this is right, the "cluster ceiling" numbers from 4c onward have been partly **driver-limited**, not cluster-limited. The real cluster capability could be significantly higher on identical hardware.

**Next.** Verify the hypothesis by lifting the driver bottleneck only, not changing cluster hardware. Upgrade the driver-only instance to `c7i.4xlarge` (double the cores: 16 vCPU), keep cluster nodes at `t3.large`. If latency stays flat at the floor and `broadcast_lagged` drops to near-zero, the hypothesis is confirmed and our published ceiling numbers have been artificially low on the Arcane side. This is a ~5-minute terraform change and ~$1 of EC2.

---

## 2026-04-22 — Hardware audit: cluster nodes were `t3.large`, not `c7i.2xlarge`

**Trigger.** While preparing the driver-upsize tfvars I noticed the committed `arcaneperhost.clusters_*.tfvars` set `data_instance_type = "t3.large"` for every server-side role. The README and the first draft of this journal claimed cluster nodes were `c7i.2xlarge`. Couldn't reconcile the two — asked: what actually ran?

**Audit.** AWS CloudTrail `RunInstances` events for 2026-04-21, filtered by `ArcaneBenchmarkRole` tag, covering every benchmark apply that day (SpacetimeDB-only runs at 09:23, 11:20, 12:19 UTC; Arcane runs at 11:48, 12:50, 16:31, 19:41, 21:54 UTC). Every single server-side instance — SpacetimeDB, every Arcane cluster, manager, Redis — was `t3.large`. Only the driver was `c7i.2xlarge`.

**What this changes about the story.**

- **The comparison is actually fairer than we described.** Both backends ran on identical per-node hardware (`t3.large`, 2 vCPU burstable, 8 GiB). Per-node efficiency is directly comparable without an instance-class wrinkle. The driver is oversized (8 vCPU `c7i.2xlarge`) specifically so it doesn't cap the test.
- **The 6.5 GB OOM fits `t3.large` exactly** (8 GiB instance).
- **`t3.large` is burstable.** Sustained CPU above the 30% baseline draws from a finite credit pool; under default `unlimited` mode you pay for burst but don't throttle. This is an uncontrolled knob in all results so far and needs to be either (a) switched to `standard` mode (throttling would become visible) or (b) acknowledged in methodology notes. Added to followup list.
- **The bounded-rayon experiment from 2026-04-22 was almost vacuous by arithmetic.** `num_cpus/2` on 2 vCPU is 1 thread = serial. Parallel pre-encoding was always going to be compute-identical to serial on `t3.large`; the only place rayon could have helped was if scheduling overhead differed meaningfully, and it didn't. Rayon deserves a real test on a multi-vCPU box before being declared unhelpful — the current data only falsifies "unbounded rayon helps on 2 vCPU," not "parallel pre-encoding helps in general."
- **The driver-CPU-saturation hypothesis is still worth testing.** Driver is 8 vCPU, diag shows 700-800% CPU use; that's real even independent of cluster hardware. Lifting it to 16 vCPU is still the cheapest next move.

**What this does NOT change.**

- The ceiling numbers themselves (1750 / 3500 / 6000 / 6750) stand. Those are empirical outcomes of the actual runs. Only the *hardware description* attached to them was wrong.
- The qualitative story stands: SpacetimeDB caps at one node, Arcane scales across four before the full-mesh replication tax asserts itself. The corrected hardware description makes this a cleaner claim, not a weaker one.

**Fixes applied this day.**

- `README.md`: hardware line + "what these numbers say" first bullet rewritten.
- This journal: every `c7i.2xlarge` reference that described cluster/SpacetimeDB hardware corrected to `t3.large` inline.
- `arcane/docs/architecture/clustering-system-requirements.md`: benchmark-evidence section + workload→capability examples corrected (separate PR on the arcane repo).

**Next.** Continue with the driver-upsize experiment. Also file a followup to run the parallel-pre-encoding test on cluster nodes with > 2 vCPU — that experiment has not actually been meaningfully performed yet.

---

## What this journal captures vs what it doesn't

**Captures.** The experimental chain — hypothesis, setup, result, interpretation, next. Each entry links to a specific `RunId` for anyone who wants to inspect the raw manifest/CSV/diag logs.

**Doesn't capture.** Conversations where we decided *not* to try something. Those live in PR discussions and internal notes. If a non-trivial decision was made to skip an avenue (e.g., "skipped 8-cluster because the shape was already unambiguous at 6-cluster"), the entry that preceded that skip should note it in its **Next** section.

**Format convention.** Date + short title. Hypothesis is the first paragraph. Setup names the image tag and run ID. Result includes the ceiling number and at least one distinctive anomaly (if any). Interpretation separates what the data *does* show from what it does *not*. Next is always the specific action that came out of this entry.

New entries go at the bottom, newest-on-bottom, so reading top-to-bottom reconstructs the chronology correctly.
