# Shared AWS CLI helpers for infra/aws run-phase scripts (dot-source from orchestrators / topology RemoteBenchmark modules).
# Provisioning helpers are intentionally absent — EC2 / security groups / S3 / IAM are owned by Terraform (infra/terraform/aws_benchmark/).

function Assert-AwsCli {
  $null = aws --version 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'AWS CLI not found or not working.' }
}

# Cross-platform temp directory. $env:TEMP is Windows-only; on Linux/macOS it
# is empty and Join-Path produces a relative path. Use the .NET API which
# honors $TMPDIR on POSIX and falls back to /tmp.
function Get-ArcaneTempDir {
  return [System.IO.Path]::GetTempPath()
}

function Assert-AwsCallerIdentity {
  $raw = aws sts get-caller-identity --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw @"
AWS credentials are not usable. Run 'aws sts get-caller-identity' locally and fix auth (aws configure, SSO, or environment variables).

CLI output: $raw
"@
  }
  $j = $raw | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace([string]$j.Account)) {
    throw 'aws sts get-caller-identity returned no Account.'
  }
  return $j
}

function Get-ArcaneBenchmarkDefaultArtifactBucketName {
  param(
    [Parameter(Mandatory)][string]$AccountId,
    [Parameter(Mandatory)][string]$Region
  )
  $r = $Region.Trim().ToLowerInvariant()
  return "arcane-benchmark-artifacts-$AccountId-$r"
}

function Get-AwsCliFileUri([string]$path) {
  $full = [System.IO.Path]::GetFullPath($path)
  if ($full -match '^[A-Za-z]:\\') {
    return 'file://' + $full
  }
  return 'file:///' + ($full -replace '\\', '/')
}

function Escape-BashDoubleQuoted([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
}

function Get-Ec2PrivateIp {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceId
  )
  $ip = aws ec2 describe-instances --region $Region --instance-ids $InstanceId --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip) -or $ip -eq 'None') {
    throw "Could not read PrivateIpAddress for instance $InstanceId"
  }
  return $ip.Trim()
}

function Send-SsmRunShellScript {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$ScriptBody,
    [string]$Comment = 'Arcane benchmark SSM',
    [int]$TimeoutSeconds = 3600
  )
  $paramsPath = Join-Path (Get-ArcaneTempDir) ("arcane-ssm-$([guid]::NewGuid().ToString('n')).json")
  try {
    # Always normalize to LF before sending to AWS-RunShellScript.
    # This avoids CRLF contamination from Windows-authored strings causing
    # remote Linux shell failures (e.g., "_script.sh: not found"/exit 127).
    $normalizedScriptBody = $ScriptBody -replace "`r`n", "`n" -replace "`r", "`n"
    $paramObj = @{ commands = @($normalizedScriptBody); executionTimeout = @("$TimeoutSeconds") }
    [System.IO.File]::WriteAllText(
      $paramsPath,
      ($paramObj | ConvertTo-Json -Depth 10 -Compress),
      [System.Text.UTF8Encoding]::new($false)
    )
    $fileUri = Get-AwsCliFileUri $paramsPath
    $sendRaw = aws ssm send-command --region $Region --instance-ids $InstanceId --document-name 'AWS-RunShellScript' `
      --comment $Comment --timeout-seconds $TimeoutSeconds --parameters "$fileUri" --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "send-command failed: $sendRaw" }
    $cmdId = ($sendRaw | ConvertFrom-Json).Command.CommandId
    if ([string]::IsNullOrWhiteSpace($cmdId)) { throw 'send-command returned no CommandId' }
    return $cmdId
  } finally {
    Remove-Item -LiteralPath $paramsPath -Force -ErrorAction SilentlyContinue
  }
}

function Wait-SsmCommandInvocation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$CommandId,
    [string]$Label = 'SSM',
    [int]$PollSeconds = 5,
    [switch]$ThrowOnFailure
  )
  Write-Host "$Label CommandId=$CommandId (waiting)..." -ForegroundColor Cyan
  do {
    Start-Sleep -Seconds $PollSeconds
    $invRaw = aws ssm get-command-invocation --region $Region --command-id $CommandId --instance-id $InstanceId --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "get-command-invocation failed: $invRaw" }
    $inv = $invRaw | ConvertFrom-Json
  } while ($inv.Status -in 'Pending', 'InProgress', 'Delayed')

  Write-Host "$Label Status: $($inv.Status)" -ForegroundColor $(if ($inv.Status -eq 'Success') { 'Green' } else { 'Yellow' })
  if ($ThrowOnFailure -and $inv.Status -ne 'Success') {
    Write-Host '--- stdout ---' -ForegroundColor DarkGray
    $inv.StandardOutputContent
    Write-Host '--- stderr ---' -ForegroundColor DarkGray
    $inv.StandardErrorContent
    throw "$Label SSM command failed: $($inv.Status)"
  }
  return $inv
}
