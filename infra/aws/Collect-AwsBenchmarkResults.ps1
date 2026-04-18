<#
.SYNOPSIS
  Check benchmark drivers for in-flight SSM work, then sync all completed runs from S3 into results/runs/.

.DESCRIPTION
  Intended workflow (Terraform or script-provisioned environments with fixed topology names):

  1. For **AwsSpacetimeOnly** and **AwsArcanePerHost**, locate the **driver** EC2 instance(s) and query SSM for
     commands still **Pending**, **InProgress**, or **Delayed**. If any are found, prints a short notice so you know
     a benchmark may still be running on that environment.
  2. Lists every **RunId** prefix under **s3://&lt;bucket&gt;/&lt;ArtifactPrefix&gt;/&lt;Environment&gt;/** for both
     topologies and runs **aws s3 sync** into **&lt;repo&gt;/results/runs/&lt;Environment&gt;/&lt;RunId&gt;/**.

  **Driver discovery** (first match wins per topology):
  - Optional **-AwsSpacetimeOnlyStatePath** / **-AwsArcanePerHostStatePath**: JSON from setup with **BenchmarkInstanceId**.
  - **EC2 tags** (use these on the driver instance when you move to Terraform; fixed names, no per-deploy name variable):
    - **ArcaneBenchmarkEnvironment** = `AwsSpacetimeOnly` or `AwsArcanePerHost`
    - **ArcaneBenchmarkRole** = `driver`
    Only **running** instances are considered.

  **Bucket:** pass **-ArtifactBucket**, or omit to use the default Terraform-created name
  **arcane-benchmark-artifacts-&lt;account&gt;-&lt;region&gt;**.

  Re-running **terraform apply** for a singleton stack should be handled in Terraform (e.g. lifecycle / workspace rules)
  so a second deploy fails or no-ops with a clear message; this script does not enforce that.
#>
param(
  [string]$ArtifactBucket = '',
  [string]$ArtifactPrefix = 'benchmark-aws',
  [string]$Region = 'us-east-1',

  [string]$AwsSpacetimeOnlyStatePath = '',
  [string]$AwsArcanePerHostStatePath = '',

  [switch]$SkipSsmCheck
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/Import-AwsBenchmarkEnvironment.ps1')
. (Join-Path $PSScriptRoot 'lib/AwsHelpers.ps1')

Assert-AwsCli

$tagEnv = 'ArcaneBenchmarkEnvironment'
$tagRole = 'ArcaneBenchmarkRole'
$roleDriver = 'driver'

function Read-BenchmarkStateIfPresent {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Get-DriverInstanceIdFromState {
  param([object]$State, [string]$ExpectedEnvironment)
  if ($null -eq $State) { return '' }
  if ([string]$State.Environment -ne $ExpectedEnvironment) { return '' }
  $id = [string]$State.BenchmarkInstanceId
  if ([string]::IsNullOrWhiteSpace($id)) { return '' }
  return $id.Trim()
}

function Get-DriverInstanceIdsByTags {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$EnvironmentName
  )
  $filters = @(
    "Name=tag:$tagEnv,Values=$EnvironmentName",
    "Name=tag:$tagRole,Values=$roleDriver",
    'Name=instance-state-name,Values=running'
  )
  $filterArgs = foreach ($f in $filters) { @('--filters', $f) }
  $raw = aws ec2 describe-instances --region $Region @filterArgs --query 'Reservations[].Instances[].InstanceId' --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "describe-instances failed for $EnvironmentName : $raw"
    return @()
  }
  $arr = $raw | ConvertFrom-Json
  if ($null -eq $arr) { return @() }
  return @($arr | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Get-DriverInstanceIdsForTopology {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [string]$StatePath
  )
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $st = Read-BenchmarkStateIfPresent -Path $StatePath
  $fromState = Get-DriverInstanceIdFromState -State $st -ExpectedEnvironment $EnvironmentName
  if (-not [string]::IsNullOrWhiteSpace($fromState)) { [void]$seen.Add($fromState) }
  foreach ($id in Get-DriverInstanceIdsByTags -Region $Region -EnvironmentName $EnvironmentName) {
    [void]$seen.Add($id)
  }
  return @($seen)
}

function Test-DriverHasActiveSsmCommand {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceId
  )
  $raw = aws ssm list-commands --region $Region --instance-id $InstanceId --max-results 25 --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "list-commands failed for $InstanceId : $raw"
    return $false
  }
  $doc = $raw | ConvertFrom-Json
  $cmds = @($doc.Commands)
  foreach ($c in $cmds) {
    $s = [string]$c.Status
    if ($s -in @('Pending', 'InProgress', 'Delayed')) { return $true }
  }
  return $false
}

function Get-S3RunIdPrefixes {
  param(
    [Parameter(Mandatory)][string]$Bucket,
    [Parameter(Mandatory)][string]$PrefixRoot,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$Region
  )
  $base = "$PrefixRoot/$EnvironmentName/".Replace('//', '/')
  $all = [System.Collections.Generic.List[string]]::new()
  $token = ''
  do {
    $args = @(
      's3api', 'list-objects-v2',
      '--bucket', $Bucket,
      '--prefix', $base,
      '--delimiter', '/',
      '--region', $Region,
      '--output', 'json'
    )
    if (-not [string]::IsNullOrWhiteSpace($token)) {
      $args += @('--continuation-token', $token)
    }
    $raw = aws @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "list-objects-v2 failed: $raw" }
    $j = $raw | ConvertFrom-Json
    foreach ($p in @($j.CommonPrefixes)) {
      $pref = [string]$p.Prefix
      if (-not [string]::IsNullOrWhiteSpace($pref)) { [void]$all.Add($pref.TrimEnd('/')) }
    }
    $token = [string]$j.NextContinuationToken
  } while (-not [string]::IsNullOrWhiteSpace($token))

  $runIds = [System.Collections.Generic.List[string]]::new()
  foreach ($full in $all) {
    $leaf = ($full -split '/')[-1]
    if (-not [string]::IsNullOrWhiteSpace($leaf)) { [void]$runIds.Add($leaf) }
  }
  return , @([string[]]@($runIds | Sort-Object -Unique))
}

# --- bucket ---
$bucket = $ArtifactBucket.Trim()
if ([string]::IsNullOrWhiteSpace($bucket)) {
  $caller = Assert-AwsCallerIdentity
  $bucket = Get-ArcaneBenchmarkDefaultArtifactBucketName -AccountId "$($caller.Account)" -Region $Region
}

$prefixRoot = $ArtifactPrefix.Trim().Trim('/')

# --- SSM notices ---
if (-not $SkipSsmCheck) {
  foreach ($envName in $script:AwsBenchmarkKnownEnvironments) {
    $statePath = if ($envName -eq 'AwsSpacetimeOnly') { $AwsSpacetimeOnlyStatePath } else { $AwsArcanePerHostStatePath }
    $drivers = Get-DriverInstanceIdsForTopology -Region $Region -EnvironmentName $envName -StatePath $statePath
    if ($drivers.Count -eq 0) {
      Write-Host "SSM check: no running driver found for $envName (tags $tagEnv + $tagRole=$roleDriver, or state BenchmarkInstanceId)." -ForegroundColor DarkGray
      continue
    }
    foreach ($iid in $drivers) {
      if (Test-DriverHasActiveSsmCommand -Region $Region -InstanceId $iid) {
        Write-Host "Notice: $envName driver $iid has SSM command(s) still in progress (Pending/InProgress/Delayed). A benchmark run may not be finished yet." -ForegroundColor Yellow
      }
    }
  }
}

# --- sync all run folders ---
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$synced = 0
foreach ($envName in $script:AwsBenchmarkKnownEnvironments) {
  $runIds = Get-S3RunIdPrefixes -Bucket $bucket -PrefixRoot $prefixRoot -EnvironmentName $envName -Region $Region
  foreach ($runId in $runIds) {
    $src = "s3://$bucket/$prefixRoot/$envName/$runId/"
    $dest = Join-Path $repoRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $envName $runId)))
    $null = New-Item -ItemType Directory -Path $dest -Force
    Write-Host "Sync: $src" -ForegroundColor Cyan
    Write-Host "  -> $dest" -ForegroundColor Cyan
    aws s3 sync $src $dest --region $Region
    if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed (exit $LASTEXITCODE) for $src" }
    $synced++
  }
}

Write-Host "Collect finished. Bucket=$bucket SyncedRunFolders=$synced (under results/runs)." -ForegroundColor Green
