# AWS benchmark automation (`infra/aws`)

## How to run

There are exactly **two ways** to run the benchmark, plus a separate cleanup step:

### Option 1: Without Docker (single command)

```powershell
pwsh ./infra/aws/Run-Repro-Aws-Controller.ps1 `
  -PlanFile ./plans/headline-13500.toml `
  -BenchmarkImage ghcr.io/brainy-bots/arcane-benchmark:dev
```

This does everything: preflight checks, terraform provision, fleet startup, benchmark run with live dashboard, and prompts you to rerun or destroy when done. Use `-NonInteractive` for CI (auto-cleanup). Use `-SkipCleanup` to keep the fleet alive for inspection.

Override defaults with `-Tfvars <name>` (default: `arcaneperhost.clusters_4.drivers_12.tfvars`) and `-Region <region>` (default: `us-east-1`).

### Option 2: With Docker (single command)

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

Runs `terraform destroy` and audits AWS for leaked resources. Override with `-Tfvars <name>` and `-Region <region>`.

## Prerequisites

- **AWS CLI** configured (`aws sts get-caller-identity` works)
- **Terraform** ≥ 1.5
- **PowerShell 7+** (`pwsh`)
- **curl** (real binary, not a PowerShell alias)
- **Rust toolchain** to build `benchmark-controller` (one-time: `cargo build -p benchmark-controller --release`)

## Internal scripts (not user-facing)

The files below exist in this directory but are called by `Run-Repro-Aws-Controller.ps1` — do not invoke them directly:

- `Setup-Benchmark-Aws.ps1` — terraform apply + SSM wait
- `Run-Benchmark-Aws-Controller.ps1` — fleet container lifecycle + controller run
- `Test-ReproPrereqs.ps1` — preflight validation
- `lib/PostRunMenu.ps1` — interactive rerun/destroy menu
