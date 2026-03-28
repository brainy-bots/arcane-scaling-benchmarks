<#
.SYNOPSIS
  Launch an EC2 instance, run Benchmark v2 via SSM, upload results to S3, optionally terminate.

.DESCRIPTION
  Requires: AWS CLI configured, an instance profile with AmazonSSMManagedInstanceCore + s3:PutObject on -ArtifactBucket.

  Reproducible mode only: uses published images via -UsePublishedImages.
  -InfraImage / -SwarmImage must be **publicly** pullable (no registry auth on the instance).

  This script lives under scripts\cloud. Run from that directory or any path; it does not depend on PSScriptRoot for AWS calls.

.PARAMETER ArtifactBucket
  S3 bucket to sync the remote output directory into (prefix includes run id).

.PARAMETER IamInstanceProfileName
  EC2 instance profile name (not ARN) with SSM + S3 permissions.

.PARAMETER InfraImage
  Full image ref for infra/manager/cluster (e.g. ghcr.io/brainy-bots/arcane-benchmark-infra:v1.0.0).

.PARAMETER SwarmImage
  Full image ref for swarm client (e.g. ghcr.io/brainy-bots/arcane-benchmark-swarm:v1.0.0).
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactBucket,

  [string]$Region = 'us-east-1',
  [string]$InstanceType = 'c7i.2xlarge',
  # Default Ubuntu root EBS is too small for Spacetime + Rust + Docker layers.
  [int]$RootVolumeGiB = 100,
  [string]$ArtifactPrefix = 'benchmark-v2-aws',

  [Parameter(Mandatory = $true)]
  [string]$IamInstanceProfileName,

  [string]$RepoUrl = 'https://github.com/brainy-bots/arcane-scaling-benchmarks.git',
  [string]$Branch = 'master',

  [string]$InfraImage = 'ghcr.io/brainy-bots/arcane-benchmark-infra:v1.0.0',
  [string]$SwarmImage = 'ghcr.io/brainy-bots/arcane-benchmark-swarm:v1.0.0',

  [string]$SubnetId = '',
  [string]$SecurityGroupId = '',
  [string]$KeyName = '',

  [switch]$TerminateOnExit,

  # Skip local `docker pull` check for GHCR images (use when Docker is unavailable locally).
  [switch]$SkipLocalPublicImageCheck,

  # Extra arguments passed to Run-Benchmark-V2.ps1 on the instance (quoted string, e.g. '-MaxPlayers 2000 -StartPlayers 250')
  [string]$BenchmarkPwshArgs = ''
)

$ErrorActionPreference = 'Stop'

function Assert-AwsCli {
  $v = aws --version 2>&1
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI not found or not working: $v" }
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
  $sn = aws ec2 describe-subnets --region $reg --filters Name=vpc-id,Values=$vpcId --query 'Subnets[0].SubnetId' --output text
  if ([string]::IsNullOrWhiteSpace($sn) -or $sn -eq 'None') { throw 'No subnet in default VPC; pass -SubnetId.' }
  return $sn.Trim()
}

# Windows AWS CLI v2 expects file://C:\Path\file.json (NOT file:///C:/... which breaks).
function Get-AwsCliFileUri([string]$path) {
  $full = [System.IO.Path]::GetFullPath($path)
  if ($full -match '^[A-Za-z]:\\') {
    return 'file://' + $full
  }
  return 'file:///' + ($full -replace '\\', '/')
}

function New-BenchmarkSecurityGroup([string]$reg, [string]$vpcId) {
  $sg = aws ec2 create-security-group --region $reg --group-name "arcane-bench-$(Get-Random)" --description 'Arcane benchmark v2' --vpc-id $vpcId --query 'GroupId' --output text
  if ($LASTEXITCODE -ne 0) { throw 'create-security-group failed' }
  # New custom SGs default to allow all outbound (IPv4); no extra egress rule needed.
  return $sg.Trim()
}

function Assert-PublicBenchmarkImages([string]$infra, [string]$swarm) {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    Write-Host 'docker not on PATH: skipping local anonymous pull check. Ensure images are public or EC2 pull will fail.' -ForegroundColor Yellow
    return
  }
  foreach ($img in @($infra, $swarm)) {
    & docker pull $img
    if ($LASTEXITCODE -ne 0) {
      throw @"
Anonymous docker pull failed for '$img'.
This runner does not log in to GHCR. Make the package public (GitHub Packages settings) or mirror to a public registry and pass -InfraImage / -SwarmImage.
"@
    }
  }
  Write-Host 'Local anonymous docker pull OK for infra and swarm images.' -ForegroundColor DarkGray
}

Assert-AwsCli

if ($IamInstanceProfileName -eq 'YourInstanceProfileName') {
  throw 'Replace -IamInstanceProfileName with a real EC2 instance profile name (not the README placeholder). Example: aws iam list-instance-profiles --query "InstanceProfiles[*].InstanceProfileName" --output text'
}

aws iam get-instance-profile --instance-profile-name $IamInstanceProfileName --output json 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "IAM instance profile not found in this account: '$IamInstanceProfileName'. List: aws iam list-instance-profiles --query ""InstanceProfiles[*].InstanceProfileName"" --output text"
}

if (-not $SkipLocalPublicImageCheck) {
  Assert-PublicBenchmarkImages -infra $InfraImage -swarm $SwarmImage
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$remoteRoot = '/opt/arcane-scaling-benchmarks'
$remoteOutParent = '/opt/arcane-benchmark-out'
$remoteOutDir = "$remoteOutParent/aws_runs_$runId"
$s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$runId/"

$ami = Get-Ubuntu2204Ami $Region
$rootDev = aws ec2 describe-images --region $Region --image-ids $ami --query 'Images[0].RootDeviceName' --output text
if ([string]::IsNullOrWhiteSpace($rootDev) -or $rootDev -eq 'None') { $rootDev = '/dev/sda1' }
$rootDev = $rootDev.Trim()
$bdmPath = Join-Path $env:TEMP ("arcane-bdm-{0}.json" -f $runId)
$bdmBody = @"
[{"DeviceName":"$rootDev","Ebs":{"VolumeSize":$RootVolumeGiB,"VolumeType":"gp3","DeleteOnTermination":true}}]
"@
[System.IO.File]::WriteAllText($bdmPath, $bdmBody.Trim(), [System.Text.UTF8Encoding]::new($false))
$bdmUri = Get-AwsCliFileUri $bdmPath
Write-Host "Root EBS: $RootVolumeGiB GiB on $rootDev" -ForegroundColor DarkGray

if ([string]::IsNullOrWhiteSpace($SubnetId)) {
  $SubnetId = Get-DefaultSubnet $Region
}
$vpcForSg = aws ec2 describe-subnets --region $Region --subnet-ids $SubnetId --query 'Subnets[0].VpcId' --output text
if ([string]::IsNullOrWhiteSpace($SecurityGroupId)) {
  Write-Host "No -SecurityGroupId; creating temporary SG in VPC $vpcForSg" -ForegroundColor Yellow
  $SecurityGroupId = New-BenchmarkSecurityGroup -reg $Region -vpcId $vpcForSg.Trim()
}

$userData = @'
#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/root}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
curl -sSf https://install.spacetimedb.com | sh -s -- -y
export PATH="/root/.local/bin:$PATH"
curl -LO https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell_7.4.6-1.deb_amd64.deb
dpkg -i powershell_7.4.6-1.deb_amd64.deb || apt-get install -f -y
rm -f powershell_7.4.6-1.deb_amd64.deb
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
apt-get install -y unzip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
'@

$udB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))

$runArgs = @(
  'ec2', 'run-instances',
  '--region', $Region,
  '--image-id', $ami,
  '--instance-type', $InstanceType,
  '--subnet-id', $SubnetId,
  '--security-group-ids', $SecurityGroupId,
  '--iam-instance-profile', "Name=$IamInstanceProfileName",
  '--block-device-mappings', $bdmUri,
  '--user-data', $udB64,
  '--tag-specifications', "ResourceType=instance,Tags=[{Key=Name,Value=arcane-benchmark-v2-$runId}]",
  '--metadata-options', 'HttpTokens=required',
  '--query', 'Instances[0].InstanceId',
  '--output', 'text'
)
if (-not [string]::IsNullOrWhiteSpace($KeyName)) {
  $runArgs += @('--key-name', $KeyName)
}

Write-Host "Launching instance (AMI $ami)..." -ForegroundColor Cyan
$instanceId = & aws @runArgs
$runInstExit = $LASTEXITCODE
Remove-Item -LiteralPath $bdmPath -Force -ErrorAction SilentlyContinue
if ($runInstExit -ne 0) { throw "run-instances failed (aws exit $runInstExit)" }
if ([string]::IsNullOrWhiteSpace($instanceId)) { throw 'run-instances did not return InstanceId' }
$instanceId = $instanceId.Trim()
Write-Host "InstanceId=$instanceId" -ForegroundColor Green

Write-Host 'Waiting for instance running...' -ForegroundColor Cyan
aws ec2 wait instance-running --region $Region --instance-ids $instanceId | Out-Null

Write-Host 'Waiting for SSM agent (can take several minutes after user-data)...' -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(20)
do {
  Start-Sleep -Seconds 15
  $ping = aws ssm describe-instance-information --region $Region --filters "Key=InstanceIds,Values=$instanceId" --query 'InstanceInformationList[0].PingStatus' --output text 2>$null
  if ($ping -eq 'Online') { break }
  if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for SSM Online. Check IAM instance profile (AmazonSSMManagedInstanceCore) and VPC endpoints / public egress.' }
} while ($true)

function Escape-BashDoubleQuoted([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
}

$benchArgsEffective = $BenchmarkPwshArgs
if ($benchArgsEffective -notmatch '(^|\s)-UsePublishedImages(\s|$)') {
  if ([string]::IsNullOrWhiteSpace($benchArgsEffective)) {
    $benchArgsEffective = '-UsePublishedImages'
  } else {
    $benchArgsEffective = "-UsePublishedImages $benchArgsEffective"
  }
}
$benchB64 = ''
if (-not [string]::IsNullOrWhiteSpace($benchArgsEffective)) {
  $benchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($benchArgsEffective))
}

$remoteTpl = @'
#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
export REPO_URL="__REPO__"
export BRANCH="__BRANCH__"
export INFRA_IMAGE="__INFRA__"
export SWARM_IMAGE="__SWARM__"
export ARCANE_INFRA_IMAGE="$INFRA_IMAGE"
export ARCANE_SWARM_IMAGE="$SWARM_IMAGE"
export REMOTE_ROOT="__ROOT__"
export REMOTE_OUT="__OUT__"
export S3_DEST="__S3__"
export AWS_REGION="__REGION__"
export BENCH_B64="__BENCH_B64__"

until docker info >/dev/null 2>&1 && command -v pwsh >/dev/null 2>&1 && command -v spacetime >/dev/null 2>&1; do
  echo "waiting for user-data (docker, pwsh, spacetime)..."
  sleep 10
done

# Rust + wasm + wasm-opt for host `spacetime build` (keep out of user-data so SSM is not racing cloud-init).
export HOME="${HOME:-/root}"
apt-get update -y
apt-get install -y binaryen pkg-config libssl-dev build-essential || true
if ! command -v rustc >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
rustup target add wasm32-unknown-unknown || true
export PATH="$HOME/.cargo/bin:/root/.local/bin:$PATH"

# Pre-pull Spacetime (large image); avoid many retries on small disks (fills overlay).
echo "Pre-pulling SpacetimeDB image..."
if ! docker pull clockworklabs/spacetime:latest; then
  docker system prune -af 2>/dev/null || true
  docker pull clockworklabs/spacetime:latest || true
fi
docker image inspect clockworklabs/spacetime:latest >/dev/null 2>&1 || { echo "WARN: spacetime image missing; compose will try to pull"; }

echo "Starting SpacetimeDB on 127.0.0.1:3000 (Run-Benchmark-V2 requirement)..."
docker rm -f arcane-v2-spacetimedb 2>/dev/null || true
docker run -d --name arcane-v2-spacetimedb -p 127.0.0.1:3000:3000 clockworklabs/spacetime:latest start
for i in $(seq 1 90); do
  if ss -Htan 2>/dev/null | grep -qE ':(3000)\s'; then break; fi
  if netstat -ltn 2>/dev/null | grep -q ':3000 '; then break; fi
  sleep 2
done

mkdir -p "$REMOTE_ROOT"
if [ ! -d "$REMOTE_ROOT/.git" ]; then
  git clone "$REPO_URL" "$REMOTE_ROOT"
fi
cd "$REMOTE_ROOT"
git fetch origin
if ! git checkout "$BRANCH"; then
  echo "Branch $BRANCH missing; trying master then main"
  git checkout master || git checkout main
fi
git pull --ff-only || git pull

mkdir -p "$REMOTE_OUT"
# SpacetimeDB runs in Docker (Run-Benchmark-V2); do not run `spacetime start` on the host or port 3000 conflicts.

set +e
if [ -n "$BENCH_B64" ]; then
  EXTRA=$(printf '%s' "$BENCH_B64" | base64 -d)
  pwsh -NoProfile -Command "& \"$REMOTE_ROOT/scripts/benchmark/Run-Benchmark-V2.ps1\" -OutDir \"$REMOTE_OUT\" $EXTRA"
else
  pwsh -NoProfile -File "$REMOTE_ROOT/scripts/benchmark/Run-Benchmark-V2.ps1" -OutDir "$REMOTE_OUT"
fi
EC=$?
set -e

aws s3 sync "$REMOTE_OUT" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@

$remoteBash = $remoteTpl.Replace('__REPO__', (Escape-BashDoubleQuoted $RepoUrl)).
  Replace('__BRANCH__', (Escape-BashDoubleQuoted $Branch)).
  Replace('__INFRA__', (Escape-BashDoubleQuoted $InfraImage)).
  Replace('__SWARM__', (Escape-BashDoubleQuoted $SwarmImage)).
  Replace('__ROOT__', (Escape-BashDoubleQuoted $remoteRoot)).
  Replace('__OUT__', (Escape-BashDoubleQuoted $remoteOutDir)).
  Replace('__S3__', (Escape-BashDoubleQuoted $s3Dest)).
  Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
  Replace('__BENCH_B64__', $benchB64)
# CRLF breaks #!/bin/bash on Linux (interpreter /bin/bash\r not found)
$remoteBash = $remoteBash -replace "`r`n", "`n"

$paramsPath = Join-Path $env:TEMP "arcane-ssm-params-$runId.json"
# One commands[] entry: per-line arrays break env persistence and can split long tokens across invocations.
$paramObj = @{ commands = @($remoteBash) }
$jsonParams = $paramObj | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($paramsPath, $jsonParams, [System.Text.UTF8Encoding]::new($false))

$fileUri = Get-AwsCliFileUri $paramsPath

Write-Host 'Sending SSM run command...' -ForegroundColor Cyan
$sendRaw = aws ssm send-command --region $Region `
  --instance-ids $instanceId `
  --document-name 'AWS-RunShellScript' `
  --comment "Arcane benchmark v2 $runId" `
  --timeout-seconds 28800 `
  --parameters "$fileUri" `
  --output json 2>&1
if ($LASTEXITCODE -ne 0) {
  Remove-Item -LiteralPath $paramsPath -Force -ErrorAction SilentlyContinue
  throw "send-command failed (aws exit $LASTEXITCODE): $sendRaw"
}
$sendOut = $sendRaw | ConvertFrom-Json

$cmdId = $sendOut.Command.CommandId
Remove-Item -LiteralPath $paramsPath -Force -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($cmdId)) { throw 'send-command returned no CommandId' }

Write-Host "CommandId=$cmdId (waiting for completion)..." -ForegroundColor Cyan
do {
  Start-Sleep -Seconds 10
  $invRaw = aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $instanceId --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "get-command-invocation failed: $invRaw" }
  $inv = $invRaw | ConvertFrom-Json
} while ($inv.Status -in 'Pending', 'InProgress', 'Delayed')

Write-Host "SSM Status: $($inv.Status)" -ForegroundColor $(if ($inv.Status -eq 'Success') { 'Green' } else { 'Yellow' })
Write-Host '--- stdout (tail) ---' -ForegroundColor DarkGray
($inv.StandardOutputContent -split "`n" | Select-Object -Last 80) -join "`n"
Write-Host '--- stderr (tail) ---' -ForegroundColor DarkGray
($inv.StandardErrorContent -split "`n" | Select-Object -Last 40) -join "`n"

if ($TerminateOnExit) {
  Write-Host "Terminating $instanceId ..." -ForegroundColor Cyan
  aws ec2 terminate-instances --region $Region --instance-ids $instanceId | Out-Null
}

Write-Host "Artifacts: $s3Dest" -ForegroundColor Green
if ($inv.Status -ne 'Success') { exit 1 }
