# Reproducing the experiment

The benchmark is driven by a **single script**: `scripts/Run-Benchmark.ps1`. It does **not** build binaries, pull images, or publish the SpacetimeDB module—you prepare those first, then run the script.

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

From the repo root (or any directory; paths resolve from the script location):

```powershell
.\scripts\Run-Benchmark.ps1
```

Outputs go under `results/runs/<Environment>/<yyyyMMdd_HHmmss>/` by default (`-Environment` defaults to `Local`; use another label or match your cloud topology name). Each run has `spacetimedb_only/` and `arcane_plus_spacetimedb/` with `benchmark_scenarios_results.csv` and `stderr/` logs. Override with `-OutDir`. See `results/README.md`.

Useful switches: `-SpacetimeStep`, `-SpacetimeMaxPlayers`, `-ArcaneCeilingStartPlayers`, `-ArcaneClusterCounts`, `-FindArcaneCeiling:$false`, `-DurationSeconds`, `-PersistBatchSize`. See the script’s comment-based help.

---

## One run at a time

Ports are fixed (manager 8081, clusters 8090+). Do not run two benchmarks on the same host concurrently.

---

## Canonical parameters

See [docs/CANONICAL_PARAMETERS.md](docs/CANONICAL_PARAMETERS.md).

---

## Comparing with documentation

Compare ceiling lines from the script output or CSVs with **arcane-demos** `docs/SCALING_EXPERIMENT_RESULTS.md`. Hardware and OS will shift exact numbers.

---

## AWS

Optional flow (three phases, split by tool so every AWS resource is declarative). **Requires Terraform (>= 1.3)** — see [module install instructions](infra/terraform/aws_benchmark/README.md#install-terraform) (works on Windows, macOS, Linux).

1. **Provision** — `terraform apply` in **`infra/terraform/aws_benchmark/`** creates the EC2 fleet, security group, S3 artifact bucket, IAM role, and instance profile. Pick the topology with **`-var=topology=AwsSpacetimeOnly`** (SpacetimeDB + driver) or **`-var=topology=AwsArcanePerHost`** (Redis + SpacetimeDB + manager + N clusters + driver). Export state for the run phase: `terraform output -json benchmark_state > .benchmark-aws-terraform.json`.
2. **Run** — **`infra/aws/Run-Benchmark-Aws.ps1 -StatePath .benchmark-aws-terraform.json -ConfigFile <...>`** invokes SSM on the driver to clone the repo, build, run the benchmark, and upload artifacts to S3. **`infra/aws/Collect-AwsBenchmarkResults.ps1`** / **`Sync-AwsBenchmarkResultsFromS3.ps1`** pull results into **`results/runs/<Environment>/<runId>/`** locally.
3. **Tear down** — `terraform destroy` removes every resource. No alternate cleanup path exists; this keeps reproduction deterministic for anyone starting from an empty AWS account.

See **`infra/terraform/aws_benchmark/README.md`** for the module details.
