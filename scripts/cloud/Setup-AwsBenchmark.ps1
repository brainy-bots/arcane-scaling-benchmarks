<#
.SYNOPSIS
  Provision AWS resources for a benchmark environment (no benchmark run).

.DESCRIPTION
  Use this to bring up infrastructure only; run Cleanup-AwsBenchmark.ps1 (or terminate manually) when done.
  The full pipeline is still Run-Benchmark-Aws.ps1 (setup → remote benchmark → optional cleanup).

.PARAMETER Environment
  Topology name. Each value maps to scripts/cloud/environments/<Name>/. Register new names in
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

  [string]$SubnetId = '',
  [string]$SecurityGroupId = '',
  [string]$KeyName = '',

  [string]$StateOutPath = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Tools/Import-AwsBenchmarkEnvironment.ps1')

if ($script:AwsBenchmarkKnownEnvironments -notcontains $Environment) {
  throw "Unknown -Environment '$Environment'. Known: $($script:AwsBenchmarkKnownEnvironments -join ', ')"
}

. (Join-Path $PSScriptRoot 'Common/AwsHelpers.ps1')
$setupPath = Join-Path $PSScriptRoot "environments\$Environment\Setup.ps1"
if (-not (Test-Path -LiteralPath $setupPath)) { throw "Missing environment script: $setupPath" }
. $setupPath

Assert-AwsCli
Assert-IamInstanceProfile -name $IamInstanceProfileName

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'

switch ($Environment) {
  'SingleInstance' {
    $state = Initialize-SingleInstanceAwsBenchmarkEnvironment `
      -Region $Region `
      -InstanceType $InstanceType `
      -RootVolumeGiB $RootVolumeGiB `
      -SubnetId $SubnetId `
      -SecurityGroupId $SecurityGroupId `
      -KeyName $KeyName `
      -IamInstanceProfileName $IamInstanceProfileName `
      -RunId $runId
  }
  default {
    throw "Environment '$Environment' is registered but not implemented in Setup-AwsBenchmark.ps1."
  }
}

$state | Add-Member -NotePropertyName RunId -NotePropertyValue $runId -Force
$state | Add-Member -NotePropertyName ArtifactBucket -NotePropertyValue $ArtifactBucket -Force
$state | Add-Member -NotePropertyName ArtifactPrefix -NotePropertyValue $ArtifactPrefix -Force

if ([string]::IsNullOrWhiteSpace($StateOutPath)) {
  $StateOutPath = Join-Path $PSScriptRoot (".benchmark-aws-state-$runId.json")
}

$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateOutPath -Encoding utf8
Write-Host "State saved: $StateOutPath" -ForegroundColor Green
Write-Host "Tear down with: pwsh ./Cleanup-AwsBenchmark.ps1 -StatePath '$StateOutPath'"
$state
