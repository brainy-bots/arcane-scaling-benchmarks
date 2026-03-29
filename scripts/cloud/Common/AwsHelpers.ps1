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

function Escape-BashDoubleQuoted([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
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
