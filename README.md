# Arcane — scaling benchmark

This repository is the public scaling benchmark for [**Arcane**](https://github.com/brainy-bots/arcane) — a Rust multiplayer game backend engine that partitions server authority across N cluster nodes by predicted player-interaction probability rather than by spatial zoning or flat hashing. The benchmark measures the headline properties Arcane is designed to deliver, end-to-end on commodity AWS hardware: **how many concurrent players** can be sustained, **at what server tick rate**, with **how much per-entity replication state**, and **at what server-side latency**.

The headline run below is reproducible from scratch by any reader with an AWS account in about **25–35 minutes** on commodity AWS hardware (add a few minutes for the one-time `benchmark-controller` build on first run).

> **13,500 CCU at 60 Hz, 1 KB payload, 10.4 ms mean server-side latency, on commodity AWS hardware.**

## The claim

| Variable | Value |
|---|---|
| Concurrent players (CCU) | **13,500** |
| Server tick / broadcast rate | **60 Hz** (16.67 ms per tick) |
| Per-entity payload | **1,000 bytes** opaque `user_data` per entity, included whenever the entity is in the broadcast delta (see [What the workload actually does](#what-the-workload-actually-does) for the dead-reckoning detail) |
| Mean server-side latency | **10.39 ms** (median 10.24 ms; range across 12 independent drivers: 8.63 – 13.15 ms) |
| Latency category | **< 20 ms server-side**, every driver, every tier |
| Error rate at top tier | **0.000 %** (0 errors / ~24,000,000 round-trips) |
| Cluster fleet | **4 × `c6in.2xlarge`** (8 vCPU, 16 GB RAM, 50 Gbps NIC) |
| Supporting nodes | 1 × `t3.large` Arcane manager · 1 × `t3.large` SpacetimeDB persistence · 1 × `c5n.large` Redis pub/sub |
| AWS region | us-east-1 |
| Run mode | Full-mesh broadcast (no area-of-interest filtering, no affinity clustering active — worst case for replication bandwidth) |
| Simulation | Kinematic motion + radius-collision (no rigid-body physics) |
| Run ID | `20260427_191741` |

*On the 1 KB number.* That's the **slot size** carried whenever an entity appears in a broadcast delta — not the per-tick per-player downstream wire rate. Most entities are velocity-stable most ticks and are dead-reckoned client-side rather than re-broadcast (a standard MMO replication technique; see [What the workload actually does](#what-the-workload-actually-does) below for the detail). Effective bytes-on-the-wire depend on movement pattern.

*The engine is not at its ceiling.* 1,125 per driver is the √N driver-safety cap that prevents a single load generator from becoming the bottleneck — not a measured engine break. Latency stayed essentially flat across the entire ramp; full methodology and interpretation are in [docs/BENCHMARK-METHODOLOGY.md](docs/BENCHMARK-METHODOLOGY.md).

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
  -PlanFile ./plans/headline-13500.toml `
  -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:v0.3.0
```

This does everything: preflight, terraform provision, fleet startup, benchmark run with live dashboard, and prompts to rerun or destroy when done.

### Option 2: With Docker

```powershell
docker run --rm -it `
  -e AWS_PROFILE=default `
  -e AWS_REGION=us-east-1 `
  -v "${env:USERPROFILE}\.aws:/root/.aws:ro" `
  -v "${PWD}\results:/workspace/results" `
  ghcr.io/brainy-bots/arcane-benchmark-operator:v0.3.0
```

### Cleanup (separate)

```powershell
pwsh ./infra/aws/Cleanup-Benchmark-Aws.ps1
```

### Configuration

Override the fleet topology with `-Tfvars <name>` (default: `arcaneperhost.clusters_4.drivers_12.tfvars`). Available tfvars are in `infra/terraform/aws_benchmark/`.

Results land under `results/runs/<Environment>/<RunId>/`. Add `-S3UploadResults` to also upload to the Terraform-created S3 bucket.

**Total cost of one full reproduction: ~$5** on AWS on-demand pricing.

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

To stay on the right side of intellectual honesty about a number that's deliberately impressive: here is the explicit list of what the 13,500 / 60 Hz / 1 KB / 10.4 ms result *does* and *does not* establish.

### What it proves

- **The Arcane cluster pipeline sustains the configured workload at 13,500 CCU on this fleet shape, with mean server-side action-to-broadcast latency under 13 ms on every one of 12 independent drivers, and zero errors across ~24 million round-trips at the top tier.** Every claim in that sentence is directly measured at the driver, by 12 independent processes, all reporting in agreement.
- **The latency curve is essentially flat from 1.5K to 13.5K CCU.** Across a 9× growth in CCU, mean latency drifted from 8.02 ms to 9.41 ms. The engine is not under stress at the top tier; the run terminated at the configured per-driver safety cap (`floor(4000 / sqrt(12)) = 1154`), not at an engine break.
- **Reproducibility is real.** The Docker image, Terraform module, TOML benchmark plans, and controller-driven operator workflow are all committed. Anyone with an AWS account can re-run this and see numbers in the same band.

### What it does NOT prove

- **The engine's ceiling.** The run hit a *driver-side* safety cap, not an engine break. The actual engine ceiling on this fleet is higher; we just didn't measure it. To find it we'd need more or larger driver instances.
- **End-to-end production latency.** The 10.4 ms figure is server-side — drivers are in the same VPC. Real players are over the public internet (typically 30–60 ms regional, 100–200 ms global), so end-to-end perceived latency in a shipped game is roughly 40–70 ms regional.
- **Cluster outbound bandwidth.** This run did **not** capture per-tier `bytes_out` from cluster `/stats` (a known instrumentation gap; tracked as a follow-up). The latency curve is consistent with a sustained 60 Hz broadcast cadence, but we cannot directly verify that broadcast rate from the artifacts of this specific run. Future runs will record `bytes_out` per tier so the egress story is grounded in measurement, not inference.
- **Long-running stability.** Each tier is held for 30 seconds of steady state. We have not measured a 12-hour or 24-hour soak at the top tier; behaviors that emerge slowly (memory creep, file-descriptor leaks, tick-budget drift over time) are not in scope.
- **Real game physics.** The simulation is kinematic motion plus radius-collision. It does **not** run server-side rigid-body dynamics, hit registration, raycasts, vehicle physics, joint constraints, or ragdolls. AAA shooter dedicated servers do — adding equivalent physics will lower the ceiling, and that measurement is on the roadmap as a separate publication.
- **Production cost economics.** Compute and egress costs are deliberately not stated in this README. The benchmark is an engine measurement, not a pricing artifact.
- **Real-world variability.** Synthetic drivers do not model the action mix, AOI patterns, churn, or geographic distribution of actual game traffic. The workload (2 actions/sec, 5 reads/sec, periodic bursts) is stylized for reproducibility, not faithful to any specific shipping game.
- **Multi-region / cross-AZ resilience.** Single AWS region (`us-east-1`), single placement group, no cluster-loss recovery exercised.

---

## Architecture context

Arcane partitions server authority across N cluster nodes by **predicted player-interaction probability**, not by spatial zoning or flat hashing. Players who interact frequently get co-located on the same cluster; each cluster fans broadcasts out to its subscribers. Inter-cluster delta replication runs over Redis pub/sub.

This run is **full-mesh visible** at the architectural level — every cluster merges neighbor deltas via Redis pub/sub before broadcasting, so every one of the 13,500 players is *eligible* to see every entity. No area-of-interest filtering is applied. (Actual on-the-wire bandwidth is reduced substantially by the dead-reckoning + quantization optimizations described above; full-mesh *visibility* and full-mesh *bandwidth* are not the same thing.) With AI-driven affinity clustering active in production, per-cluster fan-out drops by the affinity hit rate and the ceiling lifts further.

The simulation here is a **kinematic physics baseline** — `position += velocity × dt` plus radius-based collision. Real rigid-body physics on the server (Rapier as default, pluggable) is on the roadmap; once it lands a separate shooter-class measurement will be published, with a lower ceiling, directly comparable to AAA shooter dedicated-server numbers.

---

## Project structure

```
plans/                TOML test plans (e.g. headline-13500.toml)
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
