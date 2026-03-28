<#
.SYNOPSIS
  Tear down AWS benchmark infrastructure (from saved state or explicit IDs).

.DESCRIPTION
  Prefer -StatePath from Setup-AwsBenchmark.ps1 or a Run-Benchmark-Aws.ps1 run that saved state.
  Alternatively pass -InstanceId and -Region (and security group fields if a temporary SG was created).

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

switch ($Environment) {
  'SingleInstance' {
    if ($SkipSecurityGroupDelete) {
      Remove-SingleInstanceAwsBenchmarkEnvironment -State $state -SkipSecurityGroupDelete
    } else {
      Remove-SingleInstanceAwsBenchmarkEnvironment -State $state
    }
  }
  default {
    throw "Environment '$Environment' has no cleanup implementation in Cleanup-AwsBenchmark.ps1."
  }
}

Write-Host 'Cleanup finished.' -ForegroundColor Green
