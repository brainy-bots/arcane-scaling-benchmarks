<#
.SYNOPSIS
  Launch EC2, run scripts/Run-Benchmark.ps1 remotely via SSM, then download results to this machine.

.DESCRIPTION
  Orchestrates environment-specific setup (see environments/<Environment>/), remote bootstrap, benchmark, and
  optional cleanup. To provision or destroy infrastructure alone, use Setup-AwsBenchmark.ps1 and
  Cleanup-AwsBenchmark.ps1.

  **Results:** The instance uploads to S3 (ephemeral disk is lost when the instance terminates). By default this
  script then **syncs from S3 into your local repo** under `results/runs/<Environment>/<RunId>/` — same layout as a
  local `Run-Benchmark.ps1` run — so the person running the script has artifacts on disk when the command finishes.
  Use **-SkipLocalResultsDownload** only if you intentionally want bucket-only artifacts.

  **SingleInstance:** After clone, SSM runs **`scripts/start-benchmark-deps.sh`** so Redis + SpacetimeDB match local Docker.
  **DistributedComponents:** Redis and SpacetimeDB run on **separate** instances; the driver uses **private IPs** (no `start-benchmark-deps.sh` on the driver).

  Requires: AWS CLI; instance profile with SSM + S3 PutObject on -ArtifactBucket; your IAM user/role needs
  **s3:GetObject** (and list) on that bucket for the post-run download.

.PARAMETER Environment
  Topology under scripts/cloud/environments/<Name>/. Add new folders and register names in
  Tools/Import-AwsBenchmarkEnvironment.ps1.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactBucket,

  [string]$Environment = 'SingleInstance',

  [string]$Region = 'us-east-1',
  [string]$InstanceType = 'c7i.2xlarge',
  [int]$RootVolumeGiB = 100,
  [string]$ArtifactPrefix = 'benchmark-aws',

  [Parameter(Mandatory = $true)]
  [string]$IamInstanceProfileName,

  [string]$RepoUrl = 'https://github.com/brainy-bots/arcane-scaling-benchmarks.git',
  [string]$Branch = 'main',

  [string]$SubnetId = '',
  [string]$SecurityGroupId = '',
  [string]$KeyName = '',

  [switch]$TerminateOnExit,

  [string]$BenchmarkPwshArgs = '',

  [string]$StateOutPath = '',

  # Optional: PAT or OAuth token for private git submodules. If omitted, uses env ARCANE_BENCHMARK_GITHUB_TOKEN.
  [string]$GithubToken = '',

  # Default: <repo root>/results/runs/<Environment>/<RunId>/ (same shape as local Run-Benchmark.ps1).
  [string]$LocalResultsDir = '',

  [switch]$SkipLocalResultsDownload
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Tools/Import-AwsBenchmarkEnvironment.ps1')

if ($script:AwsBenchmarkKnownEnvironments -notcontains $Environment) {
  throw "Unknown -Environment '$Environment'. Known: $($script:AwsBenchmarkKnownEnvironments -join ', ')"
}

# Dot-source at script scope (not inside a function) so AWS helpers and env commands are visible here.
. (Join-Path $PSScriptRoot 'Common/AwsHelpers.ps1')
$envBase = Join-Path $PSScriptRoot "environments\$Environment"
foreach ($leaf in @('Setup.ps1', 'RemoteBenchmark.ps1', 'Cleanup.ps1')) {
  $p = Join-Path $envBase $leaf
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing environment script: $p" }
  . $p
}
. (Join-Path $PSScriptRoot 'Common/AwsBenchmarkEnvironmentRegistry.ps1')

Assert-AwsCli
Assert-IamInstanceProfile -name $IamInstanceProfileName

$resolvedGh = $GithubToken
if ([string]::IsNullOrWhiteSpace($resolvedGh)) { $resolvedGh = $env:ARCANE_BENCHMARK_GITHUB_TOKEN }
$githubTokenB64 = ''
if (-not [string]::IsNullOrWhiteSpace($resolvedGh)) {
  $githubTokenB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resolvedGh.Trim()))
  Write-Host 'GitHub submodule auth: token will be used for git submodule update on the instance.' -ForegroundColor DarkGray
} else {
  Write-Warning 'No -GithubToken or ARCANE_BENCHMARK_GITHUB_TOKEN: private submodules will fail to clone on EC2.'
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$state = $null

$initParams = @{
  Region                 = $Region
  InstanceType           = $InstanceType
  RootVolumeGiB          = $RootVolumeGiB
  SubnetId               = $SubnetId
  SecurityGroupId        = $SecurityGroupId
  KeyName                = $KeyName
  IamInstanceProfileName = $IamInstanceProfileName
  RunId                  = $runId
}

try {
  $state = Invoke-BenchmarkAwsEnvironmentInitialize -Environment $Environment -Parameters $initParams

  $state | Add-Member -NotePropertyName RunId -NotePropertyValue $runId -Force
  $state | Add-Member -NotePropertyName ArtifactBucket -NotePropertyValue $ArtifactBucket -Force
  $state | Add-Member -NotePropertyName ArtifactPrefix -NotePropertyValue $ArtifactPrefix -Force

  if (-not [string]::IsNullOrWhiteSpace($StateOutPath)) {
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateOutPath -Encoding utf8
    Write-Host "State saved: $StateOutPath" -ForegroundColor DarkGray
  }

  $remoteParams = @{
    State                = $state
    RunId                = $runId
    ArtifactBucket       = $ArtifactBucket
    ArtifactPrefix       = $ArtifactPrefix
    RepoUrl              = $RepoUrl
    Branch               = $Branch
    BenchmarkPwshArgs    = $BenchmarkPwshArgs
    GithubTokenB64       = $githubTokenB64
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
}
finally {
  if ($TerminateOnExit -and $null -ne $state) {
    Invoke-BenchmarkAwsEnvironmentRemove -Environment $state.Environment -State $state
  }
}
