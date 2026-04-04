# Known benchmark topologies (folder names under environments/). Loaded by orchestrator scripts.
# Dot-source this file, then dot-source Common/AwsHelpers.ps1 and the environment scripts at script scope
# (not inside a function), so Initialize-/Invoke-/Remove-* are visible to the caller.

$script:AwsBenchmarkKnownEnvironments = @(
  'SingleInstance'
  'DistributedComponents'
)

function Get-AwsBenchmarkKnownEnvironments {
  return @($script:AwsBenchmarkKnownEnvironments)
}
