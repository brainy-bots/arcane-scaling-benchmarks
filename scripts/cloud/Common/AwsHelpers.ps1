# Shared AWS CLI helpers for cloud benchmark scripts (dot-source from orchestrators / environment modules).

function Assert-AwsCli {
  $null = aws --version 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'AWS CLI not found or not working.' }
}

function Get-Ubuntu2204Ami([string]$reg) {
  $name = '/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id'
  $ami = aws ssm get-parameters --region $reg --names $name --query 'Parameters[0].Value' --output text
  if ([string]::IsNullOrWhiteSpace($ami) -or $ami -eq 'None') { throw "Could not resolve Ubuntu 22.04 AMI in $reg" }
  return $ami.Trim()
}

function Get-DefaultSubnet([string]$reg) {
  $vpcId = aws ec2 describe-vpcs --region $reg --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text
  if ([string]::IsNullOrWhiteSpace($vpcId) -or $vpcId -eq 'None') { throw 'No default VPC; pass -SubnetId (and -SecurityGroupId).' }
  $sn = aws ec2 describe-subnets --region $reg --filters "Name=vpc-id,Values=$vpcId" --query 'Subnets[0].SubnetId' --output text
  if ([string]::IsNullOrWhiteSpace($sn) -or $sn -eq 'None') { throw 'No subnet in default VPC; pass -SubnetId.' }
  return $sn.Trim()
}

function Get-AwsCliFileUri([string]$path) {
  $full = [System.IO.Path]::GetFullPath($path)
  if ($full -match '^[A-Za-z]:\\') {
    return 'file://' + $full
  }
  return 'file:///' + ($full -replace '\\', '/')
}

function New-BenchmarkSecurityGroup([string]$reg, [string]$vpcId) {
  $sg = aws ec2 create-security-group --region $reg --group-name "arcane-bench-$(Get-Random)" --description 'Arcane benchmark' --vpc-id $vpcId --query 'GroupId' --output text
  if ($LASTEXITCODE -ne 0) { throw 'create-security-group failed' }
  return $sg.Trim()
}

# Allow benchmark nodes in the same security group to reach each other (Redis, SpacetimeDB, Arcane manager/clusters).
function Add-BenchmarkDistributedIngressFromSelf {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$GroupId
  )
  $portRanges = @(
    @(6379, 6379),   # Redis
    @(3000, 3000),   # SpacetimeDB
    @(8081, 8081),   # arcane-manager
    @(8090, 8110)    # arcane-cluster WS
  )
  foreach ($pr in $portRanges) {
    $from = $pr[0]
    $to = $pr[1]
    $json = "[{`"IpProtocol`":`"tcp`",`"FromPort`":$from,`"ToPort`":$to,`"UserIdGroupPairs`":[{`"GroupId`":`"$GroupId`"}]}]"
    $tmp = Join-Path $env:TEMP ("arcane-sg-ing-$([guid]::NewGuid().ToString('n')).json")
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    $fileUri = Get-AwsCliFileUri $tmp
    $raw = aws ec2 authorize-security-group-ingress --region $Region --group-id $GroupId --ip-permissions $fileUri 2>&1
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
      if ("$raw" -match 'InvalidPermission\.Duplicate') { continue }
      throw "authorize-security-group-ingress failed: $raw"
    }
  }
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

function Wait-SsmAgentOnline {
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceId,
    [int]$TimeoutMinutes = 20
  )
  Write-Host 'Waiting for SSM agent...' -ForegroundColor Cyan
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  do {
    Start-Sleep -Seconds 15
    $ping = aws ssm describe-instance-information --region $Region --filters "Key=InstanceIds,Values=$InstanceId" --query 'InstanceInformationList[0].PingStatus' --output text 2>$null
    if ($ping -eq 'Online') { return }
    if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for SSM Online.' }
  } while ($true)
}

function Assert-IamInstanceProfile([string]$name) {
  if ($name -eq 'YourInstanceProfileName') {
    throw 'Replace -IamInstanceProfileName with a real EC2 instance profile name.'
  }
  aws iam get-instance-profile --instance-profile-name $name --output json 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "IAM instance profile not found: '$name'"
  }
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
  $paramsPath = Join-Path $env:TEMP ("arcane-ssm-$([guid]::NewGuid().ToString('n')).json")
  try {
    $paramObj = @{ commands = @($ScriptBody); executionTimeout = @("$TimeoutSeconds") }
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
