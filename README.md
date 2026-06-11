# Arcane — scaling benchmark

This repository is the public scaling benchmark for [**Arcane**](https://github.com/brainy-bots/arcane) — a Rust multiplayer game backend engine that partitions server authority across N cluster nodes by predicted player-interaction probability rather than by spatial zoning or flat hashing. The benchmark measures how many concurrent players can be sustained, at what server tick rate, with how much per-entity replication state, and at what server-side latency.

The headline run below is reproducible from scratch by any reader with an AWS account in about **25–35 minutes** on commodity AWS hardware (add a few minutes for the one-time `benchmark-controller` build on first run).

> **2,750 CCU at 60 Hz, 1 KB payload, 28.8 ms mean server-side latency, zero errors, on commodity AWS hardware.** Full-mesh broadcast, no area-of-interest filtering — worst case for replication bandwidth. The run hits a NIC saturation cliff at 3,000 CCU; at 30 Hz or with smaller payloads the projected ceiling is 3,900–5,500 CCU on the same fleet.

## What changed

A previous version of this README claimed 13,500 CCU. That number was invalid for two reasons:

1. **Ghost entity bug.** A driver-default misconfiguration caused each load generator to spawn 100 phantom entities on startup before the benchmark controller took over. With 12 drivers, that inflated entity counts by 1,200 — the server was handling far more entities than the reported CCU indicated.
2. **Driver cap, not engine ceiling.** The run hit a per-driver safety cap (`floor(4000 / √12) = 1,154 per driver`), which is a load-generation limit, not an engine break. Latency was flat at the top tier, so there was no way to tell whether the engine was under stress or coasting.

This version fixes the driver default (entity counts now match CCU targets exactly), uses a larger fleet (8 × c6in.4xlarge clusters, 50 Gbps NIC), and ramps in 250-step increments until the engine actually breaks. The result is a **measured NIC saturation cliff** at 3,000 CCU: latency jumps 24× (28 ms → 682 ms) with 65,000+ lagged events — a hard wall, not gradual degradation. Last passing tier: **2,750 CCU at 28.8 ms mean latency, 0 errors**.

The numbers are lower because they are real. The previous number was an artifact of a broken measurement; this is the first valid ceiling measurement for this fleet shape.

## The claim

| Variable | Value |
|---|---|
| Concurrent players (CCU) | **2,750** |
| Server tick / broadcast rate | **60 Hz** (16.67 ms per tick) |
| Per-entity payload | **1,000 bytes** opaque `user_data` per entity, included whenever the entity is in the broadcast delta |
| Mean server-side latency | **28.82 ms** (range across 20 independent drivers: 27.63 – 30.55 ms) |
| Latency category | **< 31 ms server-side**, every driver, at top passing tier |
| Error rate at top tier | **0.000 %** (0 errors / 3,080,416 round-trips) |
| Cluster fleet | **8 × `c6in.4xlarge`** (16 vCPU, 32 GB RAM, 50 Gbps NIC) |
| Supporting nodes | 1 × `t3.large` Arcane manager · 1 × `t3.large` SpacetimeDB persistence · 1 × `c5n.large` Redis pub/sub |
| AWS region | us-east-1 |
| Run mode | Full-mesh broadcast (no area-of-interest filtering, no affinity clustering active — worst case for replication bandwidth) |
| Simulation | Kinematic motion + radius-collision (no rigid-body physics) |
| Run ID | `20260528_035946` |

*On the 1 KB number.* That's the **slot size** carried whenever an entity appears in a broadcast delta — not the per-tick per-player downstream wire rate. Most entities are velocity-stable most ticks and are dead-reckoned client-side rather than re-broadcast (a standard MMO replication technique; see [BENCHMARK-METHODOLOGY.md](docs/BENCHMARK-METHODOLOGY.md) for the detail). Effective bytes-on-the-wire depend on movement pattern.

*This is not the engine's absolute ceiling.* It is the ceiling **on this fleet shape** at 60 Hz and 1 KB user data. The bottleneck is NIC saturation on the cluster nodes — broadcast bandwidth scales as O(N²) per cluster. Reducing tick rate or payload size shifts the ceiling upward (see [Projected ceilings](#projected-ceilings) below). Adding more clusters distributes the fan-out and also raises it.

---

## Reproduce (live ASCII dashboard)

There are exactly two ways to run the benchmark. Both produce identical results.

### Option 1: Without Docker

Prerequisites: AWS CLI, Terraform, PowerShell 7+, curl, Rust toolchain.

```bash
cargo build -p benchmark-controller --release
```

```powershell
pwsh ./infra/aws/Run-Repro-Aws-Controller.ps1 `
  -PlanFile ./plans/ceiling-8cluster-6000.toml `
  -Tfvars arcaneperhost.clusters_8.drivers_20.tfvars `
  -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:dev
```

This does everything: preflight, terraform provision, fleet startup, benchmark run with live dashboard, and prompts to rerun or destroy when done.

### Option 2: With Docker

```powershell
docker run --rm -it `
  -e AWS_PROFILE=default `
  -e AWS_REGION=us-east-1 `
  -v "${env:USERPROFILE}\.aws:/root/.aws:ro" `
  -v "${PWD}\results:/workspace/results" `
  ghcr.io/brainy-bots/arcane-benchmark-operator:dev
```

### Cleanup (separate)

```powershell
pwsh ./infra/aws/Cleanup-Benchmark-Aws.ps1
```

### Configuration

Override the fleet topology with `-Tfvars <name>` (default: `arcaneperhost.clusters_8.drivers_20.tfvars` — the fleet that produced the published run `20260528_035946`). Available tfvars are in `infra/terraform/aws_benchmark/`.

Results land under `results/runs/<Environment>/<RunId>/`. Add `-S3UploadResults` to also upload to the Terraform-created S3 bucket.

---

## Results

### Measured: 8 clusters, 60 Hz, 1 KB user data

Run `20260528_035946`. Fleet: 8 × c6in.4xlarge clusters, 20 × c6in.4xlarge drivers, 1 × t3.large data, 1 × c5n.large Redis. Latency gate: 50 ms mean.

| Tier (CCU) | Entities | Mean Latency (ms) | Errors | Outcome |
|---|---|---|---|---|
| 500 | 500 | 14.42 | 0 | PASS |
| 750 | 750 | 20.78 | 0 | PASS |
| 1,000 | 1,000 | 12.63 | 0 | PASS |
| 1,250 | 1,250 | 18.65 | 0 | PASS |
| 1,500 | 1,500 | 14.64 | 0 | PASS |
| 1,750 | 1,750 | 19.53 | 0 | PASS |
| 2,000 | 2,000 | 19.53 | 0 | PASS |
| 2,250 | 2,250 | 21.54 | 0 | PASS |
| 2,500 | 2,500 | 23.95 | 0 | PASS |
| 2,750 | 2,750 | 28.82 | 0 | PASS |
| 3,000 | 3,000 | 682.08 | 65,441 lagged | **FAIL** |

Entity counts match CCU targets exactly at every tier — confirmed via driver telemetry after the ghost-entity fix.

### Projected ceilings

The following projections are estimated from the single measured run above, not from separate measurements. They assume broadcast bandwidth scales as **N² × tick_rate × frame_size** per cluster. Because bandwidth is quadratic in player count, halving tick rate or payload size yields √2 ≈ 1.41× more players, not 2×. Both halved together give 2×.

| Scenario | Tick Rate | User Data | Estimated Ceiling | Scaling Factor |
|---|---|---|---|---|
| **Measured** | 60 Hz | 1,000 B | **2,750** | — |
| Reduced tick rate | 30 Hz | 1,000 B | **~3,900** | ×√2 |
| Reduced payload | 60 Hz | 500 B | **~3,900** | ×√2 |
| Both reduced | 30 Hz | 500 B | **~5,500** | ×2 |

These are single-fleet-shape projections from one data point. Adding more clusters, using area-of-interest filtering, or enabling affinity clustering all change the scaling dynamics and are not captured here.

---

# Benchmark methodology (full details)

The README keeps the fast-scan version for first-time readers. Full technical
methodology is documented in:

- [docs/BENCHMARK-METHODOLOGY.md](docs/BENCHMARK-METHODOLOGY.md)

Short version:

- The run is driven by `benchmark-controller` and uses per-tier validity gates
  (latency, error rate, and achieved aggregate entities).
- The controller evaluates steady-state only after ramp readiness, so a tier is
  not marked as passing before required load is actually reached.
- Latency is measured driver-side as action-send to ack-broadcast elapsed time.
- The workload is intentionally replication-heavy (full-mesh visibility, no AOI
  filtering), and includes burst behavior.
- Replication uses dead-reckoning and wire quantization, so 1 KB is payload slot
  size when an entity is in a delta, not "full-world snapshot every tick."

---

## What this benchmark proves, and what it does NOT prove

### What it proves

- **The Arcane cluster pipeline sustains the configured workload at 2,750 CCU on this fleet shape, with mean server-side latency under 31 ms on every one of 20 independent drivers, and zero errors across ~3 million round-trips at the top tier.** Every claim in that sentence is directly measured at the driver, by 20 independent processes, all reporting in agreement.
- **The ceiling is a NIC saturation cliff, not a software limit.** At 3,000 CCU, latency jumps 24× (28 → 682 ms) with 65,000+ lagged events. This is consistent with outbound bandwidth exhaustion on the cluster nodes — O(N²) per-cluster fan-out hitting the NIC wall. Software overhead (CPU, memory, tick scheduling) is not the binding constraint on this fleet shape.
- **Reproducibility is real.** The Docker image, Terraform module, TOML benchmark plans, and controller-driven operator workflow are all committed. Anyone with an AWS account can re-run this and see numbers in the same band.

### What it does NOT prove

- **The engine's absolute ceiling.** 2,750 is the ceiling on this specific fleet (8 × c6in.4xlarge at 60 Hz / 1 KB). More clusters, lower tick rates, smaller payloads, or area-of-interest filtering all raise it. The projected ceilings above suggest where those configurations land, but they have not been independently measured yet.
- **End-to-end production latency.** The 28.8 ms figure is server-side — drivers are in the same VPC. Real players are over the public internet (typically 30–60 ms regional, 100–200 ms global), so end-to-end perceived latency in a shipped game is roughly 60–90 ms regional.
- **Long-running stability.** Each tier is held for 20 seconds of steady state. We have not measured a 12-hour or 24-hour soak at the top tier; behaviors that emerge slowly (memory creep, file-descriptor leaks, tick-budget drift over time) are not in scope.
- **Real game physics.** The simulation is kinematic motion plus radius-collision. It does **not** run server-side rigid-body dynamics, hit registration, raycasts, or vehicle physics. Adding equivalent physics will lower the ceiling, and that measurement is on the roadmap as a separate publication.
- **Production cost economics.** Compute and egress costs are deliberately not stated in this README. The benchmark is an engine measurement, not a pricing artifact.
- **Real-world variability.** Synthetic drivers do not model the action mix, AOI patterns, churn, or geographic distribution of actual game traffic. The workload (2 actions/sec, 5 reads/sec, periodic bursts) is stylized for reproducibility, not faithful to any specific shipping game.
- **Multi-region / cross-AZ resilience.** Single AWS region (`us-east-1`), single placement group, no cluster-loss recovery exercised.

---

## Architecture context

Arcane partitions server authority across N cluster nodes by **predicted player-interaction probability**, not by spatial zoning or flat hashing. Players who interact frequently get co-located on the same cluster; each cluster fans broadcasts out to its subscribers. Inter-cluster delta replication runs over Redis pub/sub.

This run is **full-mesh visible** at the architectural level — every cluster merges neighbor deltas via Redis pub/sub before broadcasting, so every one of the 2,750 players is *eligible* to see every entity. No area-of-interest filtering is applied. (Actual on-the-wire bandwidth is reduced substantially by the dead-reckoning + quantization optimizations described above; full-mesh *visibility* and full-mesh *bandwidth* are not the same thing.) With AI-driven affinity clustering active in production, per-cluster fan-out drops by the affinity hit rate and the ceiling lifts further.

The simulation here is a **kinematic physics baseline** — `position += velocity × dt` plus radius-based collision. Real rigid-body physics on the server (Rapier as default, pluggable) is on the roadmap; once it lands a separate shooter-class measurement will be published, with a lower ceiling, directly comparable to AAA shooter dedicated-server numbers.

---

## Project structure

```
plans/                TOML test plans (e.g. ceiling-8cluster-6000.toml)
infra/
  terraform/          Terraform modules — AWS fleet provisioning
  aws/                Run-Repro-Aws-Controller.ps1 + Cleanup-Benchmark-Aws.ps1
crates/
  benchmark-controller/   Operator binary (terminal dashboard) — builds on your laptop
  benchmark-cluster/      Arcane cluster binary — baked into Docker image
docker/               Image helper scripts
arcane/               Arcane Engine (git submodule) — image build
arcane_swarm/         Load generator + orchestrator (git submodule) — image build
results/              Run artifacts land here
```

## Documentation

- This **`README.md`** — headline numbers + reproduction instructions
- [docs/BENCHMARK-METHODOLOGY.md](docs/BENCHMARK-METHODOLOGY.md) — full benchmark methodology, gating logic, measurement definitions, and interpretation
- [infra/terraform/aws_benchmark/README.md](infra/terraform/aws_benchmark/README.md) — Terraform variables and fleet topology reference

## License

arcane-scaling-benchmarks is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0). See [LICENSE](LICENSE) for the full text. The Arcane engine and swarm driver this repository benchmarks are released under the same license; see the [arcane](https://github.com/brainy-bots/arcane) and [arcane_swarm](https://github.com/brainy-bots/arcane_swarm) repositories.

For commercial licensing inquiries: martin.mba@gmail.com
