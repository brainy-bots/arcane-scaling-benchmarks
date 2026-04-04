<#
.SYNOPSIS
  Tear down AWS benchmark infrastructure (from saved state or explicit IDs).

.DESCRIPTION
  **Preferred:** pass **-StatePath** to the JSON written by Setup-AwsBenchmark.ps1 or by Run-Benchmark-Aws.ps1
  (-StateOutPath). That file is the source of truth for instance IDs and the temporary security group.

  **SingleInstance only:** you may omit -StatePath and pass **-Environment SingleInstance** with **-InstanceId**,
  **-Region**, and optional **-SecurityGroupId** / **-CreatedSecurityGroup** when you created the SG in the same run.

  **DistributedComponents:** **-StatePath is required.** This topology provisions three EC2 instances; manual
  -InstanceId is not supported and would not tear down Redis/Spacetime/driver correctly.

.PARAMETER SkipSecurityGroupDelete
  If set, do not delete a security group even when CreatedSecurityGroup is true.
#>
param(
  [string]$StatePath = '',

  [string]$Environment = '',

  [string]$InstanceId = '',
  [string]$Region = '',
  [string]$SecurityGroupId = '',
  [switch]$CreatedSecurityGroup,

  [switch]$SkipSecurityGroupDelete
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Tools/Import-AwsBenchmarkEnvironment.ps1')

function ConvertTo-BenchmarkStateObject([object]$raw) {
  if ($raw -is [hashtable]) {
    return [pscustomobject]$raw
  }
  return $raw
}

$state = $null

if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
  if (-not (Test-Path -LiteralPath $StatePath)) {
    throw "State file not found: $StatePath"
  }
  $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json
  $state = ConvertTo-BenchmarkStateObject $state
  $Environment = $state.Environment
}

if ([string]::IsNullOrWhiteSpace($Environment)) {
  throw 'Provide -StatePath, or set -Environment together with -InstanceId and -Region.'
}

if ($script:AwsBenchmarkKnownEnvironments -notcontains $Environment) {
  throw "Unknown -Environment '$Environment'. Known: $($script:AwsBenchmarkKnownEnvironments -join ', ')"
}

. (Join-Path $PSScriptRoot 'Common/AwsHelpers.ps1')
$cleanupPath = Join-Path $PSScriptRoot "environments\$Environment\Cleanup.ps1"
if (-not (Test-Path -LiteralPath $cleanupPath)) { throw "Missing environment script: $cleanupPath" }
. $cleanupPath

Assert-AwsCli

if ($null -eq $state) {
  if ($Environment -eq 'DistributedComponents') {
    throw 'DistributedComponents requires -StatePath (JSON from setup or orchestrator). Manual -InstanceId is only valid for SingleInstance.'
  }
  if ([string]::IsNullOrWhiteSpace($InstanceId) -or [string]::IsNullOrWhiteSpace($Region)) {
    throw 'Without -StatePath, you must pass -InstanceId and -Region.'
  }
  $state = [pscustomobject]@{
    Environment          = $Environment
    Region               = $Region
    InstanceId           = $InstanceId
    SecurityGroupId      = $SecurityGroupId
    CreatedSecurityGroup = [bool]$CreatedSecurityGroup
  }
}

. (Join-Path $PSScriptRoot 'Common/AwsBenchmarkEnvironmentRegistry.ps1')
Invoke-BenchmarkAwsEnvironmentRemove -Environment $Environment -State $state -SkipSecurityGroupDelete:$SkipSecurityGroupDelete

Write-Host 'Cleanup finished.' -ForegroundColor Green
