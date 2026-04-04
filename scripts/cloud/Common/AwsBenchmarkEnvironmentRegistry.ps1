# Routes -Environment to environment-specific Initialize / RemoteBenchmark / Cleanup functions.
# Dot-source after Common/AwsHelpers.ps1 and the environment module(s) needed for the current operation
# (e.g. Setup.ps1 only for provision-only; Setup + RemoteBenchmark + Cleanup for full orchestration).

function Invoke-BenchmarkAwsEnvironmentInitialize {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][hashtable]$Parameters
  )
  switch ($Environment) {
    'SingleInstance' { return Initialize-SingleInstanceAwsBenchmarkEnvironment @Parameters }
    'DistributedComponents' { return Initialize-DistributedComponentsAwsBenchmarkEnvironment @Parameters }
    default {
      throw "Environment '$Environment' has no Initialize implementation. Register it in AwsBenchmarkEnvironmentRegistry.ps1."
    }
  }
}

function Invoke-BenchmarkAwsEnvironmentRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][hashtable]$Parameters
  )
  switch ($Environment) {
    'SingleInstance' { return Invoke-SingleInstanceAwsRemoteBenchmark @Parameters }
    'DistributedComponents' { return Invoke-DistributedComponentsAwsRemoteBenchmark @Parameters }
    default {
      throw "Environment '$Environment' has no remote benchmark implementation. Register it in AwsBenchmarkEnvironmentRegistry.ps1."
    }
  }
}

function Invoke-BenchmarkAwsEnvironmentRemove {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][object]$State,
    [switch]$SkipSecurityGroupDelete
  )
  switch ($Environment) {
    'SingleInstance' {
      if ($SkipSecurityGroupDelete) {
        Remove-SingleInstanceAwsBenchmarkEnvironment -State $State -SkipSecurityGroupDelete
      } else {
        Remove-SingleInstanceAwsBenchmarkEnvironment -State $State
      }
    }
    'DistributedComponents' {
      if ($SkipSecurityGroupDelete) {
        Remove-DistributedComponentsAwsBenchmarkEnvironment -State $State -SkipSecurityGroupDelete
      } else {
        Remove-DistributedComponentsAwsBenchmarkEnvironment -State $State
      }
    }
    default {
      throw "Environment '$Environment' has no Remove implementation. Register it in AwsBenchmarkEnvironmentRegistry.ps1."
    }
  }
}
