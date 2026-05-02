<#
.SYNOPSIS
  Run the benchmark via the new controller path. Reads Terraform output, launches
  the local `benchmark-controller` binary against the in-VPC orchestrator, and
  surfaces the controller's exit code.

.DESCRIPTION
  This is the controller-driven replacement for `Run-Benchmark-Aws.ps1`. It
  runs the operator's `benchmark-controller` binary on the operator's laptop;
  the controller talks to the orchestrator EC2 over WebSocket + HTTP/SSE, and
  the orchestrator manages drivers + clusters from inside the VPC. There is
  NO per-driver SSM fan-out — the orchestrator is the only thing the operator
  needs to address from outside the VPC.

  Step in the lifecycle:
    1. terraform apply  (in infra/terraform/aws_benchmark) — provisions the
       fleet (orchestrator + drivers + clusters) with the orchestrator's HTTP
       endpoint exposed to the operator's CIDR.
    2. THIS SCRIPT      — runs the controller against the orchestrator; the
       controller writes phase_*.json + manifest.json to the configured
       results dir (and to S3 if --s3-bucket is given).
    3. terraform destroy — tear down.

  Old path (Run-Benchmark-Aws.ps1) still works during the transition, but
  this is the recommended path post-controller landing.

.PARAMETER StatePath
  JSON produced by `terraform output -json benchmark_state` in
  infra/terraform/aws_benchmark.

.PARAMETER PlanFile
  Path to a TOML test plan (see crates/benchmark-controller/README.md for
  schema). Example plans live under plans/.

.PARAMETER ResultsDir
  Local directory to write phase_*.json + manifest.json. Defaults to
  results/runs/<timestamp>/.

.PARAMETER ControllerBinary
  Path to the benchmark-controller binary. Defaults to looking for
  `target/release/benchmark-controller` in this repo.

.PARAMETER S3Bucket
  Optional S3 bucket to upload results to (matches the artifact bucket from
  Terraform output). When omitted, results are written locally only.

.PARAMETER S3Prefix
  S3 prefix under the bucket. Defaults to `runs/<timestamp>/`.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $PlanFile,
    [string] $ResultsDir,
    [string] $ControllerBinary,
    [string] $S3Bucket,
    [string] $S3Prefix
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $StatePath)) {
    throw "Terraform state file not found: $StatePath"
}
if (-not (Test-Path $PlanFile)) {
    throw "Plan file not found: $PlanFile"
}

# Resolve the controller binary.
if (-not $ControllerBinary) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidate = Join-Path $repoRoot 'target/release/benchmark-controller'
    if (-not (Test-Path $candidate)) {
        $candidate = Join-Path $repoRoot 'target/debug/benchmark-controller'
    }
    if (-not (Test-Path $candidate)) {
        throw "benchmark-controller binary not found. Build it with: cargo build -p benchmark-controller --release"
    }
    $ControllerBinary = $candidate
}

# Read the orchestrator endpoint from Terraform state.
$state = Get-Content -Raw $StatePath | ConvertFrom-Json
$orchestratorHost = $state.value.orchestrator_public_dns
if (-not $orchestratorHost) {
    $orchestratorHost = $state.value.orchestrator_public_ip
}
if (-not $orchestratorHost) {
    throw "Terraform state does not export orchestrator_public_dns or orchestrator_public_ip. Bump infra/terraform/aws_benchmark/outputs.tf to include the orchestrator endpoint."
}
$orchestratorPort = if ($state.value.orchestrator_http_port) { $state.value.orchestrator_http_port } else { 8090 }
$orchestratorUrl = "http://${orchestratorHost}:${orchestratorPort}"

# Default ResultsDir to a timestamped folder.
if (-not $ResultsDir) {
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $ResultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "../results/runs/$stamp"
    $ResultsDir = (Resolve-Path -LiteralPath ($ResultsDir | Split-Path -Parent)).Path + '/' + (Split-Path -Leaf $ResultsDir)
}
if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

Write-Host "==> orchestrator: $orchestratorUrl"
Write-Host "==> plan:         $PlanFile"
Write-Host "==> results dir:  $ResultsDir"
if ($S3Bucket) {
    Write-Host "==> s3:           s3://$S3Bucket/$S3Prefix"
}

$ctlArgs = @(
    '--plan', $PlanFile,
    '--orchestrator-url', $orchestratorUrl,
    '--results-dir', $ResultsDir,
    '--submitter', "operator-$env:USERNAME"
)
if ($S3Bucket) {
    $ctlArgs += '--s3-bucket', $S3Bucket
    if ($S3Prefix) { $ctlArgs += '--s3-prefix', $S3Prefix }
}

Write-Host "==> launching: $ControllerBinary $($ctlArgs -join ' ')"
& $ControllerBinary @ctlArgs
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host "==> controller exited 0 (overall PASS)" -ForegroundColor Green
} else {
    Write-Host "==> controller exited $exitCode (overall FAIL or error)" -ForegroundColor Red
}
exit $exitCode
