# Reproducing the experiment

The benchmark is driven by a **single script**: `scripts/Run-Benchmark.ps1`. The scenario (SpacetimeDB-only vs Arcane + SpacetimeDB) is selected by the **config file** you point it at — configs live in `configs/` and each one fully specifies a setup (workload parameters, sweep bounds, cluster count, which module to publish). The script does **not** build binaries, pull images, or publish the SpacetimeDB module — you prepare those first, then run the script with `-ConfigFile <your-config>.json`.

**Runtime:** A full run can take **30+ minutes**. Use a separate terminal window so your IDE stays responsive.

---

## Prerequisites (before `Run-Benchmark.ps1`)

- **PowerShell** 5.1 or **PowerShell 7+** (Windows or Linux).
- **Rust** (stable) and **wasm32-unknown-unknown** for building the module and swarm: [rustup.rs](https://rustup.rs)
- **Docker** (recommended): use the **same** Redis + SpacetimeDB containers locally as on EC2 so numbers are comparable to cloud runs.
- **Git submodules:** `arcane/`, `arcane_swarm/`, etc.

### Redis + SpacetimeDB — same recipe as cloud (recommended)

From the repo root, with Docker running:

```powershell
# Windows (Git Bash path preferred; otherwise pure PowerShell fallback)
.\scripts\Start-BenchmarkDeps.ps1
```

Linux / macOS / WSL:

```bash
./scripts/start-benchmark-deps.sh
```

This starts **`redis:7-alpine`** and **`clockworklabs/spacetime:latest`** on **`127.0.0.1:6379`** and **`127.0.0.1:3000`** (container names `arcane-bench-redis`, `arcane-bench-spacetime`). The EC2 launcher runs the **same shell script** after cloning.

Pin the server image to match your CLI (optional):

```powershell
$env:SPACETIME_IMAGE = 'clockworklabs/spacetime:2.0.5'
.\scripts\Start-BenchmarkDeps.ps1
```

**Alternative:** run Redis and SpacetimeDB **without** Docker (native install, `spacetime start`, etc.) and pass `-RedisHost` / `-SpacetimeHost` if needed. That works, but it is **not** the same environment as the default cloud path—expect small shifts vs EC2.

Stop/remove containers when finished: `docker rm -f arcane-bench-redis arcane-bench-spacetime`

### Networking and published ceilings

Docker on **Windows** or **macOS** does not support a portable, in-repo way to inject realistic **inter-machine** RTT the way Linux-only `tc`/`netem` on the host would. The harness is aimed at **PowerShell 7 + Docker Desktop** for local runs. Treat **local ceilings** as workload-valid but **network-optimistic** relative to multi-node production. For numbers you publish as “real WAN-ish,” plan **multi-host or cloud** runs where latency comes from the actual topology (documented in the run manifest and README when you update them).

```powershell
git clone --recurse-submodules https://github.com/brainy-bots/arcane-scaling-benchmarks.git
cd arcane-scaling-benchmarks
git submodule update --init --recursive
```

### Build binaries (you run these)

From the repo root:

```powershell
cd arcane_swarm
cargo build -p arcane-swarm --bin arcane-swarm --release
cd ..

cd arcane
cargo build -p arcane-infra --bin arcane-manager --features manager --release
cargo build -p arcane-infra --bin arcane-cluster --features cluster-ws --release
cd ..
```

### Publish the module (you run this)

With SpacetimeDB **reachable on port 3000** (Docker from the step above, or your own install). The **SpacetimeDB CLI** on your host talks to that server:

```powershell
cd spacetimedb_demo\spacetimedb
spacetime build
# Local Docker: use --anonymous so a saved cloud token does not break JWT checks against the container.
spacetime publish arcane --yes --anonymous -s http://127.0.0.1:3000
cd ..\..
```

**wasm-opt** (optional): improves WASM optimization for SpacetimeDB builds. See [Binaryen releases](https://github.com/WebAssembly/binaryen/releases).

---

## Run the benchmark

From the repo root (or any directory; paths resolve from the script location), pick the config that matches the scenario you want:

```powershell
# SpacetimeDB-only
.\scripts\Run-Benchmark.ps1 -ConfigFile .\configs\spacetimedb_only.json

# Arcane + SpacetimeDB (2 clusters) — ArcaneClusterCount lives in the config, not on the CLI
.\scripts\Run-Benchmark.ps1 -ConfigFile .\configs\arcane_plus_spacetimedb.clusters_2.json
```

The config's **`BenchmarkMode`** field dispatches the scenario; every workload parameter (tick rate, burst profile, sweep bounds, cluster count, pass criteria) lives in the config. One config per setup — to change parameters, pick or create a different config under `configs/` rather than editing values between runs.

Outputs go under `results/runs/<Environment>/<yyyyMMdd_HHmmss>/` by default (`-Environment` defaults to `Local`; use another label or match your cloud topology name). Each run contains either `spacetimedb_only/` or `arcane_plus_spacetimedb/` with `benchmark_scenarios_results.csv` and `stderr/` logs. Override with `-OutDir`. See `results/README.md`.

---

## One run at a time

Ports are fixed (manager 8081, clusters 8090+). Do not run two benchmarks on the same host concurrently.

---

## Canonical parameters

See [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md).

---

## What the benchmark actually measures

Both scenarios report the same four-column workload (`writes/s`, `ok`, `err`, `lat_avg_ms`), and both scenarios measure that latency the same way — **client-perceived latency**, not server-side reducer RTT or client-side enqueue time.

### Why not just time the call?

Both backends are fire-and-forget from the client:

- **Arcane**: the swarm writes a postcard-encoded `PlayerStatePayload` via `WebSocket.send(...)`, which returns as soon as bytes are queued in the local send buffer.
- **SpacetimeDB**: the swarm calls `conn.reducers.update_player_input(...)`, which returns as soon as the SDK enqueues the reducer message on the persistent WebSocket.

Timing the call site on either backend is meaningless — both complete in microseconds regardless of whether the server is healthy, saturated, or gone. Previous revisions of the harness wrapped these calls with `Instant::now()` / `elapsed()` and reported the result as "latency." The resulting numbers were dominated by local memcpy time and did not move under server load, which is why prior ceiling measurements had to lean on side-channel validity gates (entity counts on SpacetimeDB, `/stats` poll on Arcane) rather than trust the latency column.

### What `lat_avg_ms` now means

The swarm measures the wall-clock gap between a player's outbound write and the moment that same player's own entity state comes back from the server:

- **Arcane**: the swarm decodes every incoming binary broadcast frame (`arcane_wire::decode_server`), scans `DeltaPayload::updated` for its own `entity_id`, and on first hit records `now - last_send` as a latency sample.
- **SpacetimeDB**: the swarm subscribes to the `entity` table (a spatial box around each player's starting position, plus the player's own row unconditionally), registers `on_update(Entity)`, and on every invocation where `new.entity_id == self` records `now - last_send` as a latency sample.

Both paths feed the same `record_ok(Duration)` in `Metrics`, so `lat_avg_ms` in FINAL lines and the CSV is the same quantity on both backends. That number represents **action → world-reflection time** — what a game client actually perceives. Under server load, tick processing slides later, the echo/subscription push arrives late, and the number rises. Under catastrophic load, echoes never arrive and the tier fails via the `NotDelivered` / `Transport` / `ConnectionDrop` counters instead.

### Pass / fail gates

A tier passes iff both:

- `(total_errs / total_calls) < MaxErrRate` (1% budget by default), AND
- `lat_avg_ms < MaxLatencyMs` (200 ms by default — the game-playability bar)

Comparable across backends by construction: the workload knobs (`TickRateHz`, `ActionsPerSec`, `ReadRateHz`, burst profile) match, the error counters match, and the latency column measures the same physical quantity.

---

## Comparing with documentation

Compare ceiling lines from the script output or CSVs with **arcane-demos** `docs/SCALING_EXPERIMENT_RESULTS.md`. Hardware and OS will shift exact numbers.

---

## AWS

Optional flow (three phases, split by tool so every AWS resource is declarative). **Requires Terraform (>= 1.3)** — see [module install instructions](infra/terraform/aws_benchmark/README.md#install-terraform) (works on Windows, macOS, Linux).

1. **Provision** — `terraform apply` in **`infra/terraform/aws_benchmark/`** creates the EC2 fleet, security group, S3 artifact bucket, IAM role, and instance profile. The topology is selected by passing one of the **committed scenario tfvars files** with `-var-file`:

   ```bash
   # SpacetimeDB + driver
   terraform apply -var-file=spacetimeonly.tfvars

   # Redis + SpacetimeDB + manager + 2 cluster nodes + driver
   terraform apply -var-file=arcaneperhost.clusters_2.tfvars
   ```

   **Never edit a tfvars file to switch scenarios.** The whole point of `-var-file` is that the topology is chosen at command time. To add a new topology or cluster count, drop a sibling file (e.g. `arcaneperhost.clusters_4.tfvars`) alongside the existing ones — do not mutate a shared file in place. The generic `terraform.tfvars` is `.gitignore`d so nobody accidentally makes it the canonical thing to edit.

   After apply, export state for the run phase:
   ```bash
   terraform output -json benchmark_state > .benchmark-aws-terraform.json
   ```
2. **Run** — **`infra/aws/Run-Benchmark-Aws.ps1 -StatePath .benchmark-aws-terraform.json -ConfigFile <...> -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:v0.3.0`** invokes SSM on every node to `docker pull` the pre-built benchmark image and `docker run` the role container (`spacetime start`, `arcane-manager`, `benchmark-cluster`, `run-benchmark`). Nothing is compiled on EC2. Results are uploaded to S3; **`infra/aws/Collect-AwsBenchmarkResults.ps1`** / **`Sync-AwsBenchmarkResultsFromS3.ps1`** pull them into **`results/runs/<Environment>/<runId>/`** locally.
3. **Tear down** — `terraform destroy` removes every resource. No alternate cleanup path exists; this keeps reproduction deterministic for anyone starting from an empty AWS account.

See **`infra/terraform/aws_benchmark/README.md`** for the module details.
