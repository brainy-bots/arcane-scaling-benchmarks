# Reproducing the benchmark via the controller path

This is the **new** reproduction flow that uses the swarm orchestrator + benchmark controller. The old `Run-Benchmark-Aws.ps1` SSM-fan-out path still works during the transition; this doc describes the controller-driven path that replaces it.

For background on why the architecture changed, see:
- Orchestrator design: `arcane_swarm/docs/SWARM_ORCHESTRATOR_DESIGN.md`
- Controller epic: [`arcane-scaling-benchmarks#75`](https://github.com/brainy-bots/arcane-scaling-benchmarks/issues/75)

## The architecture in one paragraph

The **swarm orchestrator** runs in the same VPC as the cluster fleet. Drivers register with it on startup; the orchestrator manages all driver coordination + cluster `/stats` collection + a telemetry SSE stream. The **benchmark controller** runs on the operator's laptop. It reads a TOML test plan, drives the orchestrator over HTTP (`POST /commands/submit`) according to the plan's phase schedule, subscribes to the orchestrator's telemetry SSE, evaluates per-phase validity gates, and writes `phase_*.json` + `manifest.json` to a local results dir (and to S3 if configured). There is **no per-driver SSM fan-out** — the orchestrator is the only thing the operator addresses from outside the VPC.

## What you need

- **AWS CLI** configured for the target account
- **Terraform** ≥ 1.5
- **Rust toolchain** to build the controller binary (one-time, locally)
- A **TOML test plan** under `plans/` (sample: `plans/headline-13500.toml`)

Nothing else. The cloud nodes pull a pre-built Docker image from GHCR; you do not compile on EC2.

## Step-by-step

### 1. Build the controller binary (one-time)

```bash
cargo build -p benchmark-controller --release
```

This produces `target/release/benchmark-controller`. The PowerShell launcher discovers this path automatically; pass `-ControllerBinary <path>` to override.

### 2. Provision the fleet

```bash
cd infra/terraform/aws_benchmark
terraform init
terraform apply -var-file=<your.tfvars>
terraform output -json benchmark_state > .benchmark-aws-terraform.json
```

The Terraform now exports the **orchestrator endpoint** (`orchestrator_public_dns` + `orchestrator_http_port`) alongside the existing fleet outputs. The orchestrator's HTTP port is open to your operator CIDR via the security group.

### 3. Run the benchmark via the controller

```powershell
pwsh ./infra/aws/Run-Benchmark-Aws-Controller.ps1 `
    -StatePath .benchmark-aws-terraform.json `
    -PlanFile ./plans/headline-13500.toml `
    -S3Bucket your-artifact-bucket `
    -S3Prefix runs/2026-05-02-headline
```

The script:
1. Reads the orchestrator endpoint from the Terraform state JSON.
2. Launches the local `benchmark-controller` binary against that endpoint.
3. The controller drives the run end-to-end and writes `phase_*.json` + `manifest.json` to the results directory + S3.
4. The script's exit code matches the controller's (0 = overall pass, 1 = overall fail or error).

A typical 13,500-CCU run takes ~25 minutes; the controller surfaces real-time status via stderr, and the orchestrator's `/telemetry/stream` is also available for a separate dashboard.

### 4. Tear down

```bash
cd infra/terraform/aws_benchmark
terraform destroy -var-file=<your.tfvars>
```

## Local smoke test (no AWS, no Docker)

The controller path has a **no-deployment smoke test** built into the crate: it spins up the orchestrator + a synthetic driver in-process and runs a tiny TOML plan end-to-end. This validates the full code path before any cloud spend.

```bash
cargo test -p benchmark-controller --test full_loop_e2e -- --nocapture
```

Use this whenever you change the controller, the orchestrator wire schema, or the gate / scheduler logic.

## What's different from the old path

| Concern | Old path (SSM) | New path (controller) |
|---|---|---|
| Phase schedule | PowerShell helpers in `BenchmarkHarnessHelpers.ps1` | TOML plan parsed by the controller |
| Driver coordination | Per-driver SSM `RunCommand` fan-out | Orchestrator manages drivers via WebSocket |
| Validity gates | Computed post-tier from S3 stderr | Evaluated in real time by the controller against the orchestrator's SSE telemetry |
| Per-tier results | Aggregated post-run from per-driver S3 logs | Written directly by the controller as `phase_*.json` |
| Run manifest | Built post-run from S3 | Built directly by the controller as `manifest.json` |
| Operator-facing artifacts | `tier_*.json` per driver, then aggregated | `phase_*.json` (controller, benchmark output) + orchestrator telemetry archive snapshots (operator data) |

## When the controller fails

The controller exits non-zero on any of:
- A phase's validity gate signals `Fail` (real-time abort)
- The orchestrator HTTP endpoint is unreachable
- The TOML plan fails to parse
- The S3 upload fails (when `--s3-bucket` is set)

In all cases, partial results (any phase files that were written before the failure) remain on disk for post-mortem inspection.

## Migration notes

- `infra/aws/Run-Benchmark-Aws.ps1` is **kept** during the transition. Use it for any pre-controller benchmark configurations that haven't been ported to TOML.
- The old `BenchmarkHarnessHelpers.ps1` tier-ramp logic stays in place; the new controller doesn't depend on it. Removal is tracked as a follow-up after the controller path has at least one published benchmark run.
- Terraform vars need the new orchestrator outputs (see `infra/terraform/aws_benchmark/outputs.tf`); existing tfvars don't need changes, but you may need `terraform apply` to refresh the state JSON before this script can read the orchestrator endpoint.
