<#
.SYNOPSIS
  Download a completed cloud benchmark run from S3 into the local repo (results/runs/...).

.DESCRIPTION
  Use when the orchestrator did not download results (e.g. -SkipLocalResultsDownload, crash after upload,
  or any run that synced to the same S3 layout). Same layout as the automatic post-run sync:
  spacetimedb_only/, arcane_plus_spacetimedb/, CSVs, stderr/.

  Requires: AWS CLI; IAM with s3:GetObject and s3:ListBucket on the prefix.

  Specify either **-S3Uri** (full prefix, trailing slash recommended) or **-ArtifactBucket** + **-RunId**
  with optional -ArtifactPrefix and -Environment (same defaults as setup/run scripts). **-Environment** must be a
  current topology name (**AwsSpacetimeOnly** or **AwsArcanePerHost**) when used for the default
  local path under **results/runs/**. For older S3 prefixes (legacy folder names), pass **-LocalResultsDir** so the
  download target is explicit.
#>
param(
  [string]$S3Uri = '',

  [string]$ArtifactBucket = '',
  [string]$ArtifactPrefix = 'benchmark-aws',
  [string]$Environment = 'AwsSpacetimeOnly',
  # Last path segment of the S3 prefix when using -S3Uri alone (defaults extracted from -S3Uri when possible).
  [string]$RunId = '',

  [string]$LocalResultsDir = '',
  [string]$Region = 'us-east-1'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/Import-AwsBenchmarkEnvironment.ps1')
. (Join-Path $PSScriptRoot 'lib/AwsHelpers.ps1')
Assert-AwsCli

$envSeg = $Environment.Trim().Trim('/')
if ($script:AwsBenchmarkKnownEnvironments -notcontains $envSeg) {
  throw "Unknown -Environment '$envSeg'. Known: $($script:AwsBenchmarkKnownEnvironments -join ', '). For legacy S3 path segments, pass -LocalResultsDir with the full local folder path."
}

$source = $S3Uri.Trim()
$runIdForPath = $RunId.Trim()
if ([string]::IsNullOrWhiteSpace($source)) {
  $bucket = $ArtifactBucket.Trim()
  if ([string]::IsNullOrWhiteSpace($bucket) -or [string]::IsNullOrWhiteSpace($runIdForPath)) {
    throw 'Provide -S3Uri (full s3://.../prefix/) or both -ArtifactBucket and -RunId.'
  }
  $prefix = $ArtifactPrefix.Trim().Trim('/')
  $rid = $runIdForPath.Trim('/')
  $source = "s3://$bucket/$prefix/$envSeg/$rid/"
} elseif ([string]::IsNullOrWhiteSpace($runIdForPath)) {
  $u = $source.TrimEnd('/')
  $runIdForPath = ($u -split '/')[-1]
  if ([string]::IsNullOrWhiteSpace($runIdForPath)) {
    throw 'Could not infer -RunId from -S3Uri; pass -RunId for the local results folder name.'
  }
}

if ($source -notmatch '^s3://') {
  throw "-S3Uri must start with s3:// (got: $source)"
}
if ($source -notmatch '/$') {
  $source = $source + '/'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dest = $LocalResultsDir.Trim()
if ([string]::IsNullOrWhiteSpace($dest)) {
  $dest = Join-Path $repoRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $envSeg $runIdForPath)))
} elseif ([System.IO.Path]::IsPathRooted($dest)) {
  $dest = [System.IO.Path]::GetFullPath($dest)
} else {
  $dest = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $dest))
}

$null = New-Item -ItemType Directory -Path $dest -Force
Write-Host "Sync: $source" -ForegroundColor Cyan
Write-Host "  -> $dest" -ForegroundColor Cyan
aws s3 sync $source $dest --region $Region
if ($LASTEXITCODE -ne 0) {
  throw "aws s3 sync failed (exit $LASTEXITCODE)."
}
Write-Host "Done. Local results: $dest" -ForegroundColor Green
