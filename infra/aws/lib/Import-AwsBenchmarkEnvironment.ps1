# Known benchmark topologies (folder names under topologies/). Loaded by orchestrator scripts.
# Dot-source this file, then dot-source lib/AwsHelpers.ps1 and the topology scripts at script scope
# (not inside a function), so Initialize-/Invoke-/Remove-* are visible to the caller.

$script:AwsBenchmarkKnownEnvironments = @(
  'AwsSpacetimeOnly'
  'AwsArcanePerHost'
)

function Get-AwsBenchmarkKnownEnvironments {
  return @($script:AwsBenchmarkKnownEnvironments)
}
