<#
.SYNOPSIS
  Run scripts/Run-Benchmark.ps1 on an already-provisioned EC2 benchmark fleet via SSM. The scenario
  (SpacetimeDB-only vs Arcane+SpacetimeDB) is selected by the config file you pass, via its
  BenchmarkMode field. Every node pulls the same pre-built image; no compilation happens on EC2.

.DESCRIPTION
  **Step 2 of 3 — benchmark only.** Does **not** create or destroy AWS resources.

  1. **terraform apply** (in `infra/terraform/aws_benchmark`) — provision the topology and export
     the state JSON: `terraform output -json benchmark_state > .benchmark-aws-terraform.json`.
  2. **This script** — pulls the benchmark image on every node, runs the role containers, runs
     the benchmark, syncs results to S3 (and optionally to a local folder).
  3. **terraform destroy** — remove every resource.

  **Environment** (topology) is read from the state JSON produced by `terraform output`. Options are
  **AwsSpacetimeOnly** (SpacetimeDB + driver) and **AwsArcanePerHost** (Redis + SpacetimeDB + manager +
  N clusters + driver).

  **The benchmark image** contains `spacetime` (via the upstream base), `arcane-manager`,
  `benchmark-cluster`, `arcane-swarm`, the benchmark WASM modules, PowerShell 7, and the benchmark
  scripts/configs. Roles are selected by the container command (`spacetime start`, `arcane-manager`,
  `benchmark-cluster`, `run-benchmark`, etc.). See the Dockerfile at the repo root.

  **Pinning the image:** pass `-BenchmarkImage <registry>/<repo>:<tag>`. Tag should be pinned for
  reproducibility (`:latest` is convenient for dev but not for published numbers).

  **Results:** each run uploads to `s3://<bucket>/<prefix>/<Environment>/<RunId>/`. By default this
  script also syncs them to `results/runs/<Environment>/<RunId>/` locally unless
  `-SkipLocalResultsDownload`.

  Before SSM, the script validates that the resolved run intent (config's `BenchmarkMode`,
  `ArcaneClusterCount`) matches the provisioned topology; it fails early if not.

.PARAMETER StatePath
  JSON produced by `terraform output -json benchmark_state` (in `infra/terraform/aws_benchmark`).

.PARAMETER ConfigFile
  Benchmark config JSON (path on your local filesystem, under the benchmark repo). The orchestrator
  stages the file to S3 at `s3://<bucket>/<prefix>/<env>/<runId>/runtime-config/<filename>` and the
  driver mounts it into the container at `/opt/benchmark/runtime-configs/<filename>` for this run.
  No image rebuild is needed to use a new config — just point at the local file.

.PARAMETER ArcaneClusterCount
  If `>= 0`, validated against the topology before SSM and conveyed to Run-Benchmark.ps1 via the
  config JSON (`ArcaneClusterCount`). Must be `<= MaxArcaneClusters`
  in state for AwsArcanePerHost.

.PARAMETER BenchmarkImage
  Pre-built benchmark image reference, e.g. `ghcr.io/brainy-bots/arcane-benchmark:v0.1.0`. Required
  unless `ARCANE_BENCHMARK_IMAGE` is set in the environment.

.PARAMETER SsmDriverBenchmarkTimeoutSeconds
  Max seconds for the long driver SSM invocation. Default 28 800 (8 h).

.PARAMETER LocalResultsDir
  Override for the local results destination. Defaults to `<repo>/results/runs/<Environment>/<RunId>/`.

.PARAMETER SkipLocalResultsDownload
  Leave results only in S3 (do not sync back).

.PARAMETER ValidateOnly
  Validate configuration and print what would run; do not invoke SSM or download results.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$StatePath,

  [Parameter(Mandatory = $true)]
  [string]$ConfigFile,

  [int]$ArcaneClusterCount = -1,

  [string]$ArtifactBucket = '',
  [string]$ArtifactPrefix = '',

  [string]$BenchmarkImage = '',

  [ValidateRange(300, 172800)]
  [int]$SsmDriverBenchmarkTimeoutSeconds = 28800,

  [string]$LocalResultsDir = '',

  [switch]$SkipLocalResultsDownload,

  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $StatePath)) {
  throw "State file not found: $StatePath"
}
$state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json

. (Join-Path $PSScriptRoot 'lib/Import-AwsBenchmarkEnvironment.ps1')

$Environment = [string]$state.Environment
if ([string]::IsNullOrWhiteSpace($Environment)) {
  throw "State file has no Environment property: $StatePath"
}
if ($script:AwsBenchmarkKnownEnvironments -notcontains $Environment) {
  throw "Unknown Environment '$Environment' in state. Known: $($script:AwsBenchmarkKnownEnvironments -join ', ')"
}

. (Join-Path $PSScriptRoot 'lib/AwsHelpers.ps1')
. (Join-Path $PSScriptRoot 'lib/AwsBenchmarkRunValidation.ps1')

$repoRootForValidation = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# ── Resolve + validate config file ────────────────────────────────────────────
$cfgIn = $ConfigFile.Trim()
if ([string]::IsNullOrWhiteSpace($cfgIn)) {
  throw 'Pass -ConfigFile (path to a config under configs/ in this repo).'
}
$cfgResolved = Resolve-BenchmarkConfigFilePathForValidation -ConfigPath $cfgIn `
  -SearchBasePaths @((Get-Location).Path, $repoRootForValidation)
if (-not $cfgResolved) {
  throw "Config file not found: '$cfgIn' (search: current directory and repo root $repoRootForValidation)."
}
$cfgFileName = [System.IO.Path]::GetFileName($cfgResolved)
# Configs are staged to S3 per run and mounted into the container. The path
# below is where the driver's RemoteBenchmark.ps1 mounts the host-side
# runtime-config dir; see `docker run -v` in topologies/*/RemoteBenchmark.ps1.
$containerConfigPath = "/opt/benchmark/runtime-configs/$cfgFileName"

# Build the intent string used for validation (matches the pre-image flow).
$benchIntentArgs = '-ConfigFile "./configs/{0}"' -f $cfgFileName
if ($ArcaneClusterCount -ge 0) {
  $benchIntentArgs += " -ArcaneClusterCount $ArcaneClusterCount"
}

$envBase = Join-Path $PSScriptRoot "topologies\$Environment"
$remoteScript = Join-Path $envBase 'RemoteBenchmark.ps1'
if (-not (Test-Path -LiteralPath $remoteScript)) { throw "Missing environment script: $remoteScript" }
. $remoteScript

. (Join-Path $PSScriptRoot 'lib/AwsBenchmarkEnvironmentRegistry.ps1')

Assert-AwsCli

Assert-BenchmarkRunMatchesAwsEnvironment -Environment $Environment -State $state `
  -BenchmarkPwshArgs $benchIntentArgs -RemoteProvisionProfile 'Full' `
  -ConfigSearchBasePaths @((Get-Location).Path, $repoRootForValidation)

$bucket = $ArtifactBucket.Trim()
if ([string]::IsNullOrWhiteSpace($bucket)) { $bucket = [string]$state.ArtifactBucket }
if ([string]::IsNullOrWhiteSpace($bucket)) {
  throw "Artifact bucket not in state and -ArtifactBucket not set. Re-export state with 'terraform output -json benchmark_state' or pass -ArtifactBucket here."
}

$prefix = $ArtifactPrefix.Trim()
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = [string]$state.ArtifactPrefix }
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'benchmark-aws' }

$img = $BenchmarkImage.Trim()
if ([string]::IsNullOrWhiteSpace($img)) { $img = [string]$env:ARCANE_BENCHMARK_IMAGE }
if ([string]::IsNullOrWhiteSpace($img)) {
  throw 'No benchmark image specified. Pass -BenchmarkImage (e.g. ghcr.io/brainy-bots/arcane-benchmark:v0.1.0) or set $env:ARCANE_BENCHMARK_IMAGE.'
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$Region = [string]$state.Region

# Resolve the cluster simulation tick rate from the config. Optional field —
# defaults to 20 to preserve historical behavior. The driver passes this to
# the cluster container as BENCHMARK_TICK_RATE_HZ; the env-driven helper in
# arcane-infra/tick_rate.rs picks it up. Sibling configs that want a higher
# headline (e.g. the 30 Hz MMO standard) just set the field.
. (Join-Path $script:__AwsBenchmarkRepoRoot 'scripts\BenchmarkConfigJsonc.ps1') 2>$null
if (-not (Get-Command ConvertFrom-BenchmarkConfigJsonc -ErrorAction SilentlyContinue)) {
  $repoRootForJsonc = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  . (Join-Path $repoRootForJsonc 'scripts\BenchmarkConfigJsonc.ps1')
}
$cfgRaw = Get-Content -Raw -LiteralPath $cfgResolved
$cfgJson = ConvertFrom-BenchmarkConfigJsonc -Text $cfgRaw
$clusterTickRateHz = 20
if ($cfgJson.PSObject.Properties.Name -contains 'ClusterTickRateHz') {
  $clusterTickRateHz = [int]$cfgJson.ClusterTickRateHz
}

# Multi-driver pre-launch validation. The config file declares per-driver
# values; infrastructure declares actual driver count. Both must agree, and
# per-driver tier max must fit under the safety cap. Failing here prevents
# us from spending AWS time on a misconfigured run that the harness would
# only mark INVALID after spinning up the full cluster fleet.
$cfgDriverCount        = if ($cfgJson.PSObject.Properties.Name -contains 'DriverCount')         { [int]$cfgJson.DriverCount }         else { 1 }
$cfgMaxPerDriver       = if ($cfgJson.PSObject.Properties.Name -contains 'MaxPlayersPerDriver') { [int]$cfgJson.MaxPlayersPerDriver } else { 0 }
$cfgPerDriverMaxPlayers = if ($cfgJson.PSObject.Properties.Name -contains 'ArcaneCeilingMaxPlayers') { [int]$cfgJson.ArcaneCeilingMaxPlayers } else { 0 }
$infraDriverCount      = if ($state.PSObject.Properties.Name -contains 'ArphDriverCount' -and $null -ne $state.ArphDriverCount) { [int]$state.ArphDriverCount } else { 1 }
if ($infraDriverCount -lt 1) { $infraDriverCount = 1 }

if ($cfgDriverCount -ne $infraDriverCount) {
  throw "Config DriverCount=$cfgDriverCount disagrees with provisioned ArphDriverCount=$infraDriverCount. Either pick a config that matches the deployed driver count, or re-apply Terraform with arph_driver_count=$cfgDriverCount."
}
if ($cfgMaxPerDriver -gt 0 -and $cfgPerDriverMaxPlayers -gt 0 -and $cfgPerDriverMaxPlayers -gt $cfgMaxPerDriver) {
  $aggregateMax = $cfgPerDriverMaxPlayers * $infraDriverCount
  $needDrivers  = [int][Math]::Ceiling($aggregateMax / $cfgMaxPerDriver)
  throw "Per-driver ArcaneCeilingMaxPlayers=$cfgPerDriverMaxPlayers exceeds MaxPlayersPerDriver=$cfgMaxPerDriver safety cap. To target aggregate $aggregateMax CCU you need at least arph_driver_count=$needDrivers (currently $infraDriverCount). Either lower the per-driver tier max or provision more drivers."
}
Write-Host ("Multi-driver validation: drivers={0} per_driver_max={1} cap={2} aggregate_max={3}" `
    -f $infraDriverCount, $cfgPerDriverMaxPlayers, $cfgMaxPerDriver, ($cfgPerDriverMaxPlayers * $infraDriverCount)) -ForegroundColor DarkCyan

# Stage the local config to S3 so the driver can pull it at run time. This is
# the mechanism that lets researchers add new sibling configs without rebuilding
# the image: the orchestrator uploads, the driver downloads + bind-mounts, and
# the run's `runtime-config/<filename>` S3 key is the durable record of what
# config produced the results in the same prefix.
$s3ConfigKey  = "$prefix/$Environment/$runId/runtime-config/$cfgFileName"
$s3ConfigUri  = "s3://$bucket/$s3ConfigKey"
Write-Host "Staging config to $s3ConfigUri ..." -ForegroundColor DarkCyan
$uploadOut = aws s3 cp $cfgResolved $s3ConfigUri --region $Region 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Failed to stage config to S3 (exit $LASTEXITCODE). Output: $uploadOut"
}

$remoteParams = @{
  State                            = $state
  RunId                            = $runId
  ArtifactBucket                   = $bucket
  ArtifactPrefix                   = $prefix
  BenchmarkImage                   = $img
  ContainerConfigPath              = $containerConfigPath
  S3ConfigUri                      = $s3ConfigUri
  ClusterTickRateHz                = $clusterTickRateHz
  SsmDriverBenchmarkTimeoutSeconds = $SsmDriverBenchmarkTimeoutSeconds
}

Write-Host "Run benchmark on existing AWS env. Environment=$Environment RunId=$runId Region=$Region Image=$img" -ForegroundColor Cyan
Write-Host "Config (in container): $containerConfigPath" -ForegroundColor DarkGray
Write-Host "Config (S3 source):    $s3ConfigUri" -ForegroundColor DarkGray
Write-Host "Cluster tick rate:     ${clusterTickRateHz} Hz" -ForegroundColor DarkGray
Write-Host "S3 results prefix: s3://$bucket/$prefix/$Environment/$runId/" -ForegroundColor DarkYellow
Write-Host "SSM driver benchmark timeout: ${SsmDriverBenchmarkTimeoutSeconds}s" -ForegroundColor DarkGray

if ($ValidateOnly) {
  Write-Host 'ValidateOnly: checks passed; no SSM run.' -ForegroundColor Green
  exit 0
}

$result = Invoke-BenchmarkAwsEnvironmentRemoteBenchmark -Environment $Environment -Parameters $remoteParams

if ($result.Invocation.Status -ne 'Success') { exit 1 }

if (-not $SkipLocalResultsDownload) {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  $dest = $LocalResultsDir.Trim()
  if ([string]::IsNullOrWhiteSpace($dest)) {
    $dest = Join-Path $repoRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $state.Environment $runId)))
  } elseif ([System.IO.Path]::IsPathRooted($dest)) {
    $dest = [System.IO.Path]::GetFullPath($dest)
  } else {
    $dest = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $dest))
  }
  $null = New-Item -ItemType Directory -Path $dest -Force
  Write-Host "Downloading results to: $dest" -ForegroundColor Cyan
  $syncRaw = aws s3 sync $result.S3Dest $dest --region $Region 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "aws s3 sync to local failed (exit $LASTEXITCODE). Ensure your AWS identity can read $($result.S3Dest). Output: $syncRaw"
  }
  Write-Host "Local results: $dest" -ForegroundColor Green
} else {
  Write-Host "Skipped local download (-SkipLocalResultsDownload). Staged copy: $($result.S3Dest)" -ForegroundColor Yellow
}
