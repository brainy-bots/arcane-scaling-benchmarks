# Arcane — scaling benchmark

This repository is the public scaling benchmark for [**Arcane**](https://github.com/brainy-bots/arcane) — a Rust multiplayer game backend engine that partitions server authority across N cluster nodes by predicted player-interaction probability rather than by spatial zoning. The benchmark measures the headline properties Arcane is designed to deliver, end-to-end on commodity AWS hardware: **how many concurrent players** can be sustained, **at what server tick rate**, with **how much per-entity replication state**, and **at what server-side latency**.

The result below is reproducible from scratch by any reader with an AWS account in **~25 minutes** using a pre-built public Docker image — no compilation step required.

> **13,500 concurrent players at 60 Hz with 1 KB of per-entity state, 10.4 ms mean server-side latency, on commodity AWS hardware.**

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

*The engine is not at its ceiling.* 1,125 per driver is the √N driver-safety cap that prevents a single load generator from becoming the bottleneck — not a measured engine break. Latency stayed essentially flat across the entire ramp; the full curve and methodology are in [Detailed description](#detailed-description) below.

---

## Reproduce in 10 minutes

You need: an AWS account, [Terraform](https://developer.hashicorp.com/terraform/install), [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) with credentials configured, and [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell). **No build step required** — the Docker image is pre-built and public.

### 1. Clone (~1 min)

```bash
git clone https://github.com/brainy-bots/arcane-scaling-benchmarks.git
cd arcane-scaling-benchmarks
```

### 2. Provision the fleet (~5 min)

Terraform creates everything from scratch in your AWS account: 4 clusters + 12 driver instances + manager + Redis + SpacetimeDB + S3 bucket + IAM + security groups.

```bash
cd infra/terraform/aws_benchmark
terraform init
terraform apply -var-file=arcaneperhost.clusters_4.drivers_12.tfvars -auto-approve
terraform output -json benchmark_state > .benchmark-aws-terraform.json
cd ../../..
```

Wait ~60 seconds after `terraform apply` finishes for SSM agents to register on every instance. The run script will fail loudly if any node is not yet `SSM-Online`.

### 3. Run the benchmark (~25 min)

The harness ramps from 1,500 to 13,500 aggregate CCU in 125-player-per-driver steps, holding each tier for 30 s of steady state.

```powershell
pwsh ./infra/aws/Run-Benchmark-Aws.ps1 `
  -StatePath ./infra/terraform/aws_benchmark/.benchmark-aws-terraform.json `
  -ConfigFile ./configs/arcane_plus_spacetimedb.clusters_4.drivers_12.tick60_lat50_realistic_1kb.json `
  -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:dev-2026-04-27-multidriver
```

Per-driver artifacts land in `s3://<artifact-bucket>/benchmark-aws/AwsArcanePerHost/<run_id>/driver-N/`. Each driver writes one `FINAL: players=N lat_avg_ms=X.XX total_errs=0` line per tier; the top tier is `players=1125`, mean latency across all 12 drivers should land in the 9–13 ms band.

### 4. Tear down (~2 min)

```bash
cd infra/terraform/aws_benchmark
terraform destroy -var-file=arcaneperhost.clusters_4.drivers_12.tfvars -auto-approve
```

**Total cost of one full reproduction: ~$5** on AWS on-demand pricing.

---

# Detailed description

Everything below is the careful, technical version of the headline above. If the table was enough for your decision, you can stop here. If you want to verify the claim, evaluate Arcane for your own use case, or read the methodology in detail, keep going.

## Latency curve

driver-0 sample, ramp from 125 to 1,125 players-per-driver (1.5K → 13.5K aggregate CCU):

| Aggregate CCU | Mean latency |
|---|---|
| 1,500 | 8.02 ms |
| 6,000 | 8.55 ms |
| 12,000 | 8.52 ms |
| **13,500** | **9.41 ms** |

+1.4 ms across 9× CCU growth. The engine is not under stress at the top tier — the run terminated at the configured per-driver safety cap (`floor(4000 / sqrt(12)) = 1,154`), not at an engine break.

## What "server-side latency" measures, exactly

The driver records a wall-clock timestamp when it sends an outbound action (a `seq_id`-tagged WebSocket message) and another wall-clock timestamp when it receives the next server broadcast frame whose ack-list contains that `seq_id`. The reported `lat_avg_ms` is the mean of those deltas across every action the driver sent during the 30 s steady-state phase of a tier.

That measurement includes: cluster ingest, action processing in the simulation tick, broadcast encoding, network transit driver-side, and any kernel-level scheduling on either side. It does **not** include public-internet RTT — the swarm is in the same VPC as the cluster fleet, so this is a server-side latency floor. Add typical regional internet RTT (30–60 ms) for an end-to-end perceived figure.

## What the workload actually does

Each simulated player:
- Sends **2 game actions per second** (`pickup_item`, `use_item`, `interact`)
- Sends **5 reads per second**
- Subscribes to its cluster's broadcast stream (no area-of-interest filtering — full visibility is supported architecturally)
- Participates in a **20 % cohort burst every 30 s** (10 actions / player in a 500 ms window)
- Plus periodic zone events

The cluster's broadcast pipeline applies two bandwidth optimizations that are worth naming explicitly so the reader doesn't infer a naive `60 Hz × 1 KB × 13,500-entity snapshot` is going on the wire:

- **Dead-reckoning delta encoding.** An entity is only included in a tick's broadcast when its quantized velocity changed since the last broadcast, plus periodic resync ticks for recovery. Most ticks broadcast a small fraction of the world's entities — clients dead-reckon the rest from the last known velocity.
- **Wire-level position/velocity quantization.** Continuous f64 simulation values are encoded as i16 on the wire (~6 B per `Vec3`, vs 24 B raw). The 1 KB `user_data` payload rides on top of that and is included whenever the entity is in the delta.

Both are standard MMO replication techniques; we name them so the headline numbers are interpretable and not mistaken for raw fan-out throughput.

Validity gate, enforced per tier on every driver:
- Error rate < 1 %
- Mean latency < 50 ms (engine-side gate; the 100 ms production target leaves headroom for regional internet RTT)
- Cluster `/stats` confirms entity count actually reached the target
- All 12 driver SSM commands return `Status=Success`

Any tier failing any gate aborts the ramp and the harness reports the lower ceiling. The 13,500 number above is not the highest the harness *attempted* — it is the highest tier that **passed** every gate on every driver.

---

## What this benchmark proves, and what it does NOT prove

To stay on the right side of intellectual honesty about a number that's deliberately impressive: here is the explicit list of what the 13,500 / 60 Hz / 1 KB / 10.4 ms result *does* and *does not* establish.

### What it proves

- **The Arcane cluster pipeline sustains the configured workload at 13,500 CCU on this fleet shape, with mean server-side action-to-broadcast latency under 13 ms on every one of 12 independent drivers, and zero errors across ~24 million round-trips at the top tier.** Every claim in that sentence is directly measured at the driver, by 12 independent processes, all reporting in agreement.
- **The latency curve is essentially flat from 1.5K to 13.5K CCU.** Across a 9× growth in CCU, mean latency drifted from 8.02 ms to 9.41 ms. The engine is not under stress at the top tier; the run terminated at the configured per-driver safety cap (`floor(4000 / sqrt(12)) = 1154`), not at an engine break.
- **Reproducibility is real.** The Docker image, Terraform module, configuration JSON, and run script are all committed. Anyone with an AWS account can re-run this and see numbers in the same band.

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
configs/              Benchmark scenario JSON files
infra/
  terraform/          Terraform module — provisions and destroys all AWS resources
  aws/                PowerShell run scripts — drives the workload over SSM
crates/
  benchmark-cluster/                  Arcane cluster binary with BenchmarkSimulation
  benchmark-spacetimedb-persist/      SpacetimeDB persistence module (Arcane mode)
  benchmark-spacetimedb-full/         SpacetimeDB-only baseline module
arcane/               Arcane Engine (git submodule)
arcane_swarm/         Load generator (git submodule)
```

## Documentation

- [REPRODUCIBILITY.md](REPRODUCIBILITY.md) — Full reproduction instructions including local mode (no AWS account required for smaller runs)
- [infra/aws/README.md](infra/aws/README.md) — Run / collect script reference
- [infra/terraform/aws_benchmark/README.md](infra/terraform/aws_benchmark/README.md) — Terraform module reference
- [docs/BENCHMARK_JOURNAL.md](docs/BENCHMARK_JOURNAL.md) — Dated log of every benchmark experiment, including dead ends
- [docs/WORKLOAD_PARITY.md](docs/WORKLOAD_PARITY.md) — Workload equivalence between Arcane and SpacetimeDB-only modes
- [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md) — Fixed workload parameters

## License

arcane-scaling-benchmarks is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0). See [LICENSE](LICENSE) for the full text. The Arcane engine and swarm driver this repository benchmarks are released under the same license; see the [arcane](https://github.com/brainy-bots/arcane) and [arcane_swarm](https://github.com/brainy-bots/arcane_swarm) repositories.

For commercial licensing inquiries: martin.mba@gmail.com
