# Routes -Environment to per-topology RemoteBenchmark functions.
# Dot-source after lib/AwsHelpers.ps1 and the topology RemoteBenchmark.ps1 module(s) for the current run.
#
# Provisioning and teardown are handled by Terraform (see ../../terraform/aws_benchmark/), not by this registry.

function Invoke-BenchmarkAwsEnvironmentRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][hashtable]$Parameters
  )
  switch ($Environment) {
    'AwsSpacetimeOnly' { return Invoke-AwsSpacetimeOnlyRemoteBenchmark @Parameters }
    'AwsArcanePerHost' { return Invoke-AwsArcanePerHostRemoteBenchmark @Parameters }
    default {
      throw "Environment '$Environment' has no remote benchmark implementation. Register it in AwsBenchmarkEnvironmentRegistry.ps1."
    }
  }
}
