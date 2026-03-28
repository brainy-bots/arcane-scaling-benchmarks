<#
.SYNOPSIS
  Launch EC2 (or other registered topology), run scripts/Run-Benchmark.ps1 remotely via SSM, sync results to S3.

.DESCRIPTION
  Orchestrates environment-specific setup (see environments/<Environment>/), remote bootstrap, benchmark, and
  optional cleanup. To provision or destroy infrastructure alone, use Setup-AwsBenchmark.ps1 and
  Cleanup-AwsBenchmark.ps1.

  **Fail-fast:** After cloning the repo, the SSM script runs **`scripts/start-benchmark-deps.sh`** (the same
  script you can run locally) so Redis + SpacetimeDB in Docker match between laptop and EC2.

  Requires: AWS CLI, instance profile with SSM + S3 PutObject on -ArtifactBucket.

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
  [string]$Branch = 'master',

  [string]$SubnetId = '',
  [string]$SecurityGroupId = '',
  [string]$KeyName = '',

  [switch]$TerminateOnExit,

  [string]$BenchmarkPwshArgs = '',

  [string]$StateOutPath = ''
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

Assert-AwsCli
Assert-IamInstanceProfile -name $IamInstanceProfileName

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$state = $null

try {
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
      throw "Environment '$Environment' is registered but not implemented in Run-Benchmark-Aws.ps1."
    }
  }

  $state | Add-Member -NotePropertyName RunId -NotePropertyValue $runId -Force
  $state | Add-Member -NotePropertyName ArtifactBucket -NotePropertyValue $ArtifactBucket -Force
  $state | Add-Member -NotePropertyName ArtifactPrefix -NotePropertyValue $ArtifactPrefix -Force

  if (-not [string]::IsNullOrWhiteSpace($StateOutPath)) {
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateOutPath -Encoding utf8
    Write-Host "State saved: $StateOutPath" -ForegroundColor DarkGray
  }

  switch ($Environment) {
    'SingleInstance' {
      $result = Invoke-SingleInstanceAwsRemoteBenchmark `
        -State $state `
        -RunId $runId `
        -ArtifactBucket $ArtifactBucket `
        -ArtifactPrefix $ArtifactPrefix `
        -RepoUrl $RepoUrl `
        -Branch $Branch `
        -BenchmarkPwshArgs $BenchmarkPwshArgs
    }
    default {
      throw "Environment '$Environment' has no remote benchmark step in Run-Benchmark-Aws.ps1."
    }
  }

  if ($result.Invocation.Status -ne 'Success') { exit 1 }
}
finally {
  if ($TerminateOnExit -and $null -ne $state) {
    switch ($state.Environment) {
      'SingleInstance' { Remove-SingleInstanceAwsBenchmarkEnvironment -State $state }
      default { Write-Warning "No cleanup registered for environment '$($state.Environment)'." }
    }
  }
}
