# Terminate Redis, SpacetimeDB, and driver instances; optionally delete the security group created for this run.
# Requires: Common/AwsHelpers.ps1 dot-sourced by the caller.

function Get-DistributedComponentsCleanupInstanceIdPlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][object]$State)

  $redisId = [string]$State.RedisInstanceId
  $stId = [string]$State.SpacetimeInstanceId
  $benchId = [string]$State.BenchmarkInstanceId
  $missing = [System.Collections.Generic.List[string]]::new()
  if ([string]::IsNullOrWhiteSpace($redisId)) { [void]$missing.Add('RedisInstanceId') }
  if ([string]::IsNullOrWhiteSpace($stId)) { [void]$missing.Add('SpacetimeInstanceId') }
  if ([string]::IsNullOrWhiteSpace($benchId)) { [void]$missing.Add('BenchmarkInstanceId') }
  $ids = @($redisId, $stId, $benchId) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  [pscustomobject]@{
    MissingFieldNames      = @($missing)
    InstanceIdsToTerminate = @($ids)
    AllThreeMissing        = [bool]($missing.Count -eq 3)
  }
}

function Remove-DistributedComponentsAwsBenchmarkEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [switch]$SkipSecurityGroupDelete
  )

  if ($State.Environment -ne 'DistributedComponents') {
    throw "Remove-DistributedComponentsAwsBenchmarkEnvironment: state Environment must be DistributedComponents (got '$($State.Environment)')."
  }

  $region = $State.Region
  $plan = Get-DistributedComponentsCleanupInstanceIdPlan -State $State
  if ($plan.AllThreeMissing) {
    throw 'DistributedComponents cleanup requires RedisInstanceId, SpacetimeInstanceId, and BenchmarkInstanceId in state. Use -StatePath from Setup-AwsBenchmark.ps1 or a Run-Benchmark-Aws.ps1 run that saved state — not manual -InstanceId (SingleInstance-only).'
  }
  if ($plan.MissingFieldNames.Count -gt 0) {
    Write-Warning "State is missing: $($plan.MissingFieldNames -join ', '). Terminating only instances with known IDs."
  }

  $ids = $plan.InstanceIdsToTerminate
  $sgId = $State.SecurityGroupId
  $deleteSg = (-not $SkipSecurityGroupDelete) -and $State.CreatedSecurityGroup -and -not [string]::IsNullOrWhiteSpace($sgId)

  if ($ids.Count -gt 0) {
    Write-Host "Terminating instances: $($ids -join ', ') ..." -ForegroundColor Cyan
    $termArgs = @('ec2', 'terminate-instances', '--region', $region, '--instance-ids') + $ids
    & aws @termArgs | Out-Null
    Write-Host 'Waiting for instances terminated...' -ForegroundColor DarkGray
    $waitArgs = @('ec2', 'wait', 'instance-terminated', '--region', $region, '--instance-ids') + $ids
    & aws @waitArgs 2>$null | Out-Null
  }

  if ($deleteSg) {
    Write-Host "Deleting security group $sgId ..." -ForegroundColor Cyan
    aws ec2 delete-security-group --region $region --group-id $sgId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "delete-security-group failed for $sgId (it may still be in use). Remove it manually in console."
    }
  }
}
