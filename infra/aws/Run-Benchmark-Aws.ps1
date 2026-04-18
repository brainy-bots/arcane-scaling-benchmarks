<#
.SYNOPSIS
  Run scripts/Run-Benchmark.ps1 on existing EC2 benchmark infrastructure via SSM (no provision, no teardown).

.DESCRIPTION
  **Step 2 of 3 — benchmark only.** Does **not** create or destroy AWS resources.

  1. **terraform apply** (in `infra/terraform/aws_benchmark`) — provision the topology you need and write the state JSON:
     `terraform output -json benchmark_state > .benchmark-aws-terraform.json`.
  2. **This script** — repeat as needed (new **RunId** / S3 prefix / local folder each time).
  3. **terraform destroy** — terminate all resources (EC2, security group, S3 bucket, IAM role, instance profile).

  **Environment** (topology) is read from the state JSON produced by **terraform output benchmark_state**. Options are
  **AwsSpacetimeOnly** (SpacetimeDB + driver) and **AwsArcanePerHost** (one instance per Redis, SpacetimeDB,
  manager, each cluster, and driver).

  **Typical use:** **-StatePath** and **-ConfigFile** only. Optional **-ArcaneClusterCount** (when **≥ 0**) overrides the
  JSON for that run so you need not edit the file (still must be **≤ MaxArcaneClusters** in state for **AwsArcanePerHost**).

  **-RemoteProvisionProfile** is stored in state (from the Terraform `remote_provision_profile` variable) and used here
  when you omit the same parameter (**Full** = Redis + Arcane builds where applicable; **SpacetimeOnly** = skip Redis
  container / skip Arcane manager+cluster **cargo** on the remote script).

  **Results:** Instance uploads to S3; by default this script **syncs** to `results/runs/<Environment>/<RunId>/`
  under the benchmark repo unless **-SkipLocalResultsDownload**.

  Requires: AWS CLI; state file from **terraform output benchmark_state**; your identity needs **s3:GetObject** on the artifact bucket for download.

  Before SSM, the script resolves **BenchmarkMode** / **ArcaneClusterCount** the same way **Run-Benchmark.ps1** does and
  **fails early** when that intent is incompatible with the **Environment** in the state file.

  **Advanced:** non-empty **-BenchmarkPwshArgs** overrides **-ConfigFile** / **-ArcaneClusterCount**. Do **not** pass
  **-Environment**. For **AwsSpacetimeOnly**, do **not** pass **-BenchmarkMode** (the remote run is always **SpacetimeOnly**).

  **SSM timeout:** **-SsmDriverBenchmarkTimeoutSeconds** caps the **driver** SSM command (clone / build / **Run-Benchmark.ps1** /
  S3 upload). That is separate from **DurationSeconds** in the JSON, which only controls the **load test** phase inside
  **Run-Benchmark.ps1**. The shell on EC2 often needs many hours before the timed workload even starts.

  **-ValidateOnly:** run local checks (state, bucket, intent vs topology) and print the resolved remote args and S3 prefix;
  do not call SSM.

.PARAMETER StatePath
  JSON produced by **terraform output -json benchmark_state** (in `infra/terraform/aws_benchmark`).

.PARAMETER ConfigFile
  Benchmark JSON path (resolved locally; sent to the instance as a path relative to the repo root). Required unless
  **-BenchmarkPwshArgs** is set.

.PARAMETER ArcaneClusterCount
  If **≥ 0**, adds **-ArcaneClusterCount** for that run (overrides JSON). Default **-1** means omit (use JSON only).

.PARAMETER BenchmarkPwshArgs
  If set, overrides **-ConfigFile** / **-ArcaneClusterCount**.

.PARAMETER RemoteProvisionProfile
  **Full** or **SpacetimeOnly**. Leave empty to use the value saved at setup (default **Full** if missing).

.PARAMETER SsmDriverBenchmarkTimeoutSeconds
  Max seconds for the **long** driver SSM invocation (default **28800** = 8 h). Shorter phases (Redis, Spacetime start,
  etc.) keep fixed limits in the environment scripts.

.PARAMETER ValidateOnly
  Validate configuration and print what would run; do not invoke SSM or download results.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$StatePath,

  [string]$ConfigFile = '',

  [int]$ArcaneClusterCount = -1,

  [string]$ArtifactBucket = '',
  [string]$ArtifactPrefix = '',

  [string]$RepoUrl = 'https://github.com/brainy-bots/arcane-scaling-benchmarks.git',
  [string]$Branch = 'main',

  [string]$BenchmarkPwshArgs = '',

  [string]$RemoteProvisionProfile = '',

  [ValidateRange(300, 172800)]
  [int]$SsmDriverBenchmarkTimeoutSeconds = 28800,

  [string]$GithubToken = '',

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

function ConvertTo-RemoteRepoRelativeConfigPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ConfigFullPath
  )
  $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $full = [System.IO.Path]::GetFullPath($ConfigFullPath)
  if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  $tail = $full.Substring($root.Length).TrimStart('\', '/')
  if ([string]::IsNullOrWhiteSpace($tail)) { return $null }
  return './' + ($tail -replace '\\', '/')
}

$benchArgsBuilt = $BenchmarkPwshArgs.Trim()
if ([string]::IsNullOrWhiteSpace($benchArgsBuilt)) {
  $cfgIn = $ConfigFile.Trim()
  if ([string]::IsNullOrWhiteSpace($cfgIn)) {
    throw 'Pass -ConfigFile, or use -BenchmarkPwshArgs for advanced scenarios.'
  }
  $cfgResolved = Resolve-BenchmarkConfigFilePathForValidation -ConfigPath $cfgIn `
    -SearchBasePaths @((Get-Location).Path, $repoRootForValidation)
  if (-not $cfgResolved) {
    throw "Config file not found: '$cfgIn' (search: current directory and repo root $repoRootForValidation)."
  }
  $remoteRel = ConvertTo-RemoteRepoRelativeConfigPath -RepoRoot $repoRootForValidation -ConfigFullPath $cfgResolved
  if (-not $remoteRel) {
    throw "ConfigFile must be under the benchmark repo root ($repoRootForValidation). Resolved: $cfgResolved"
  }
  $benchArgsBuilt = '-ConfigFile "{0}"' -f $remoteRel
  if ($ArcaneClusterCount -ge 0) {
    $benchArgsBuilt += " -ArcaneClusterCount $ArcaneClusterCount"
  }
}

$envBase = Join-Path $PSScriptRoot "topologies\$Environment"
foreach ($leaf in @('RemoteBenchmark.ps1')) {
  $p = Join-Path $envBase $leaf
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing environment script: $p" }
  . $p
}
. (Join-Path $PSScriptRoot 'lib/AwsBenchmarkEnvironmentRegistry.ps1')

Assert-AwsCli

$rp = $RemoteProvisionProfile.Trim()
if ([string]::IsNullOrWhiteSpace($rp)) {
  $rpFromState = $state.RemoteProvisionProfile
  if ($null -ne $rpFromState -and -not [string]::IsNullOrWhiteSpace([string]$rpFromState)) {
    $rp = [string]$rpFromState
  } else {
    $rp = 'Full'
  }
}
if ($rp -ne 'Full' -and $rp -ne 'SpacetimeOnly') {
  throw "RemoteProvisionProfile must be Full or SpacetimeOnly (got '$rp')."
}

Assert-BenchmarkRunMatchesAwsEnvironment -Environment $Environment -State $state `
  -BenchmarkPwshArgs $benchArgsBuilt -RemoteProvisionProfile $rp `
  -ConfigSearchBasePaths @((Get-Location).Path, $repoRootForValidation)

$bucket = $ArtifactBucket.Trim()
if ([string]::IsNullOrWhiteSpace($bucket)) {
  $bucket = [string]$state.ArtifactBucket
}
if ([string]::IsNullOrWhiteSpace($bucket)) {
  throw "Artifact bucket not in state and -ArtifactBucket not set. Re-export state with 'terraform output -json benchmark_state' or pass -ArtifactBucket here."
}

$prefix = $ArtifactPrefix.Trim()
if ([string]::IsNullOrWhiteSpace($prefix)) {
  $prefix = [string]$state.ArtifactPrefix
}
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'benchmark-aws' }

$resolvedGh = $GithubToken
if ([string]::IsNullOrWhiteSpace($resolvedGh)) { $resolvedGh = $env:ARCANE_BENCHMARK_GITHUB_TOKEN }
$githubTokenB64 = ''
if (-not [string]::IsNullOrWhiteSpace($resolvedGh)) {
  $githubTokenB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resolvedGh.Trim()))
  Write-Host 'GitHub submodule auth: token will be used for git submodule update on the instance.' -ForegroundColor DarkGray
} else {
  Write-Warning 'No -GithubToken or ARCANE_BENCHMARK_GITHUB_TOKEN: private submodules may fail on the instance.'
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$Region = [string]$state.Region

$remoteParams = @{
  State                            = $state
  RunId                            = $runId
  ArtifactBucket                   = $bucket
  ArtifactPrefix                   = $prefix
  RepoUrl                          = $RepoUrl
  Branch                           = $Branch
  BenchmarkPwshArgs                = $benchArgsBuilt
  GithubTokenB64                   = $githubTokenB64
  RemoteProvisionProfile           = $rp
  SsmDriverBenchmarkTimeoutSeconds = $SsmDriverBenchmarkTimeoutSeconds
}

Write-Host "Run benchmark on existing AWS env (no provision/teardown). Environment=$Environment RunId=$runId Region=$Region RemoteProvisionProfile=$rp" -ForegroundColor Cyan
Write-Host "Remote Run-Benchmark.ps1 args: $benchArgsBuilt" -ForegroundColor DarkGray
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
