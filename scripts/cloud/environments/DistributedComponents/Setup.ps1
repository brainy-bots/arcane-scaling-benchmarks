# Three EC2 instances: Redis (Docker), SpacetimeDB (Docker), benchmark driver (pwsh + Rust builds + swarm + Arcane).
# Same VPC/subnet and one security group; private IPs used for inter-node traffic.
# Requires: Common/AwsHelpers.ps1 dot-sourced by the caller.

function Initialize-DistributedComponentsAwsBenchmarkEnvironment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$InstanceType,
    [Parameter(Mandatory)][int]$RootVolumeGiB,
    [string]$SubnetId = '',
    [string]$SecurityGroupId = '',
    [string]$KeyName = '',
    [Parameter(Mandatory)][string]$IamInstanceProfileName,
    [Parameter(Mandatory)][string]$RunId
  )

  $remoteRoot = '/opt/arcane-scaling-benchmarks'
  $ami = Get-Ubuntu2204Ami $Region
  $rootDev = aws ec2 describe-images --region $Region --image-ids $ami --query 'Images[0].RootDeviceName' --output text
  if ([string]::IsNullOrWhiteSpace($rootDev) -or $rootDev -eq 'None') { $rootDev = '/dev/sda1' }
  $rootDev = $rootDev.Trim()
  $bdmPath = Join-Path $env:TEMP ("arcane-bdm-dist-$RunId.json")
  $bdmBody = @"
[{"DeviceName":"$rootDev","Ebs":{"VolumeSize":$RootVolumeGiB,"VolumeType":"gp3","DeleteOnTermination":true}}]
"@
  [System.IO.File]::WriteAllText($bdmPath, $bdmBody.Trim(), [System.Text.UTF8Encoding]::new($false))
  $bdmUri = Get-AwsCliFileUri $bdmPath

  if ([string]::IsNullOrWhiteSpace($SubnetId)) {
    $SubnetId = Get-DefaultSubnet $Region
  }
  $vpcForSg = aws ec2 describe-subnets --region $Region --subnet-ids $SubnetId --query 'Subnets[0].VpcId' --output text
  $createdSg = $false
  if ([string]::IsNullOrWhiteSpace($SecurityGroupId)) {
    Write-Host "No -SecurityGroupId; creating temporary SG in VPC $vpcForSg" -ForegroundColor Yellow
    $SecurityGroupId = New-BenchmarkSecurityGroup -reg $Region -vpcId $vpcForSg.Trim()
    $createdSg = $true
  }
  else {
    $SecurityGroupId = $SecurityGroupId.Trim()
  }
  Add-BenchmarkDistributedIngressFromSelf -Region $Region -GroupId $SecurityGroupId

  $userDataDockerOnly = @'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
'@

  $userDataBenchmark = @'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git gnupg unzip pkg-config libssl-dev build-essential
curl -sSf https://install.spacetimedb.com | sh -s -- -y
export PATH="/root/.local/bin:$PATH"
curl -LO https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell_7.4.6-1.deb_amd64.deb
dpkg -i powershell_7.4.6-1.deb_amd64.deb || apt-get install -f -y
rm -f powershell_7.4.6-1.deb_amd64.deb
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
'@

  $dataInstanceType = 't3.large'

  function Invoke-LaunchOne {
    param(
      [string]$NameSuffix,
      [string]$UserDataText,
      [string]$InstType
    )
    $udB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UserDataText))
    $runArgs = @(
      'ec2', 'run-instances',
      '--region', $Region,
      '--image-id', $ami,
      '--instance-type', $InstType,
      '--subnet-id', $SubnetId,
      '--security-group-ids', $SecurityGroupId,
      '--iam-instance-profile', "Name=$IamInstanceProfileName",
      '--block-device-mappings', $bdmUri,
      '--user-data', $udB64,
      '--tag-specifications', "ResourceType=instance,Tags=[{Key=Name,Value=arcane-bench-$NameSuffix-$RunId}]",
      '--metadata-options', 'HttpTokens=required',
      '--query', 'Instances[0].InstanceId',
      '--output', 'text'
    )
    if (-not [string]::IsNullOrWhiteSpace($KeyName)) {
      $runArgs += @('--key-name', $KeyName)
    }
    Write-Host "Launching $NameSuffix ($InstType)..." -ForegroundColor Cyan
    $id = (& aws @runArgs).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) { throw "run-instances failed for $NameSuffix" }
    return $id
  }

  $redisId = Invoke-LaunchOne -NameSuffix 'redis' -UserDataText $userDataDockerOnly -InstType $dataInstanceType
  $spacetimeId = Invoke-LaunchOne -NameSuffix 'spacetime' -UserDataText $userDataDockerOnly -InstType $dataInstanceType
  $benchmarkId = Invoke-LaunchOne -NameSuffix 'driver' -UserDataText $userDataBenchmark -InstType $InstanceType

  Remove-Item -LiteralPath $bdmPath -Force -ErrorAction SilentlyContinue

  Write-Host 'Waiting for instances running...' -ForegroundColor Cyan
  aws ec2 wait instance-running --region $Region --instance-ids $redisId $spacetimeId $benchmarkId | Out-Null

  Wait-SsmAgentOnline -Region $Region -InstanceId $redisId
  Wait-SsmAgentOnline -Region $Region -InstanceId $spacetimeId
  Wait-SsmAgentOnline -Region $Region -InstanceId $benchmarkId

  [pscustomobject]@{
    Environment             = 'DistributedComponents'
    Region                  = $Region
    RedisInstanceId         = $redisId
    SpacetimeInstanceId     = $spacetimeId
    BenchmarkInstanceId     = $benchmarkId
    SecurityGroupId         = $SecurityGroupId
    CreatedSecurityGroup    = $createdSg
    RemoteRoot              = $remoteRoot
    SubnetId                = $SubnetId
    IamInstanceProfileName  = $IamInstanceProfileName
  }
}
