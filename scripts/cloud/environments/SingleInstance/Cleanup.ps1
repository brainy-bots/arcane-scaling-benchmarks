# Tear down SingleInstance resources (instance + optionally the security group this run created).
# Requires: Common/AwsHelpers.ps1 dot-sourced by the caller.

function Remove-SingleInstanceAwsBenchmarkEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [switch]$SkipSecurityGroupDelete
  )

  if ($State.Environment -ne 'SingleInstance') {
    throw "Remove-SingleInstanceAwsBenchmarkEnvironment: state Environment must be SingleInstance (got '$($State.Environment)')."
  }

  $region = $State.Region
  $instanceId = $State.InstanceId
  $sgId = $State.SecurityGroupId
  $deleteSg = (-not $SkipSecurityGroupDelete) -and $State.CreatedSecurityGroup -and -not [string]::IsNullOrWhiteSpace($sgId)

  if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
    Write-Host "Terminating $instanceId ..." -ForegroundColor Cyan
    aws ec2 terminate-instances --region $region --instance-ids $instanceId | Out-Null
    Write-Host 'Waiting for instance terminated...' -ForegroundColor DarkGray
    aws ec2 wait instance-terminated --region $region --instance-ids $instanceId 2>$null | Out-Null
  }

  if ($deleteSg) {
    Write-Host "Deleting security group $sgId ..." -ForegroundColor Cyan
    aws ec2 delete-security-group --region $region --group-id $sgId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "delete-security-group failed for $sgId (it may still be in use). Remove it manually in console."
    }
  }
}
