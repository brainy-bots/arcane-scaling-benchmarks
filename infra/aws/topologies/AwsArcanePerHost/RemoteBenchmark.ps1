# Redis + SpacetimeDB on dedicated instances; arcane-manager + one arcane-cluster per cluster host;
# driver builds binaries, uploads to S3, starts manager/clusters via SSM, then Run-Benchmark.ps1 with -ArcaneExternalProcesses.
# Reuse the same provisioned fleet for multiple runs when ArcaneClusterCount <= MaxArcaneClusters (config / EXTRA).
# Requires: lib/AwsHelpers.ps1 dot-sourced by the caller.

function Invoke-AwsArcanePerHostRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$ArtifactBucket,
    [string]$ArtifactPrefix = 'benchmark-aws',
    [Parameter(Mandatory)][string]$RepoUrl,
    [Parameter(Mandatory)][string]$Branch,
    [string]$BenchmarkPwshArgs = '',
    [string]$GithubTokenB64 = '',
    [ValidateSet('Full', 'SpacetimeOnly')]
    [string]$RemoteProvisionProfile = 'Full',
    [int]$SsmDriverBenchmarkTimeoutSeconds = 28800
  )

  if ($State.Environment -ne 'AwsArcanePerHost') {
    throw "Invoke-AwsArcanePerHostRemoteBenchmark: state Environment must be AwsArcanePerHost (got '$($State.Environment)')."
  }
  if ($RemoteProvisionProfile -ne 'Full') {
    throw 'AwsArcanePerHost requires RemoteProvisionProfile Full (Arcane manager/clusters on separate instances).'
  }

  $Region = $State.Region
  $redisId = $State.RedisInstanceId
  $spacetimeId = $State.SpacetimeInstanceId
  $managerId = $State.ManagerInstanceId
  $benchId = $State.BenchmarkInstanceId
  $remoteRoot = $State.RemoteRoot
  $maxN = [int]$State.MaxArcaneClusters
  $clusterIds = @($State.ClusterIds) | ForEach-Object { "$_".Trim() }
  $clusterInstIds = @($State.ClusterInstanceIds) | ForEach-Object { "$_".Trim() }

  if ($maxN -lt 1) { throw 'State MaxArcaneClusters must be >= 1.' }
  if ($clusterIds.Count -ne $maxN -or $clusterInstIds.Count -ne $maxN) {
    throw "State ClusterIds ($($clusterIds.Count)) and ClusterInstanceIds ($($clusterInstIds.Count)) must each have MaxArcaneClusters=$maxN entries."
  }

  $provRunId = [string]$State.RunId
  if ([string]::IsNullOrWhiteSpace($provRunId)) {
    throw 'State file must include RunId (produced by terraform output benchmark_state) for S3 binary prefix.'
  }

  $envSeg = 'AwsArcanePerHost'
  $remoteOutDir = "$remoteRoot/results/runs/$envSeg/$RunId"
  $s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/"
  $s3BinPrefix = "s3://$ArtifactBucket/$ArtifactPrefix/bench-binaries/$provRunId"

  $redisIp = Get-Ec2PrivateIp -Region $Region -InstanceId $redisId
  $stIp = Get-Ec2PrivateIp -Region $Region -InstanceId $spacetimeId
  $mgrIp = Get-Ec2PrivateIp -Region $Region -InstanceId $managerId
  $clusterIps = @()
  foreach ($cid in $clusterInstIds) {
    $clusterIps += Get-Ec2PrivateIp -Region $Region -InstanceId $cid
  }

  Write-Host "Private IPs: Redis=$redisIp SpacetimeDB=$stIp Manager=$mgrIp Clusters=$($clusterIps -join ', ') Driver=$benchId" -ForegroundColor DarkGray

  $redisScript = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker rm -f arcane-bench-redis 2>/dev/null || true
docker run -d --name arcane-bench-redis -p 0.0.0.0:6379:6379 redis:7-alpine redis-server --appendonly yes
for i in $(seq 1 90); do docker exec arcane-bench-redis redis-cli ping 2>/dev/null | grep -q PONG && exit 0; sleep 1; done
exit 1
'@

  $stScript = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
ST_IMAGE="${ST_IMAGE:-clockworklabs/spacetime:latest}"
docker rm -f arcane-bench-spacetime 2>/dev/null || true
docker pull "$ST_IMAGE"
docker run -d --name arcane-bench-spacetime -p 0.0.0.0:3000:3000 "$ST_IMAGE" start
for i in $(seq 1 120); do bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null && exit 0; sleep 2; done
exit 1
'@

  $cidR = Send-SsmRunShellScript -Region $Region -InstanceId $redisId -ScriptBody $redisScript `
    -Comment "Arcane bench redis (arph) $RunId" -TimeoutSeconds 1200
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $redisId -CommandId $cidR -Label 'Redis' `
    -PollSeconds 5 -ThrowOnFailure

  $cidS = Send-SsmRunShellScript -Region $Region -InstanceId $spacetimeId -ScriptBody $stScript `
    -Comment "Arcane bench spacetime (arph) $RunId" -TimeoutSeconds 3600
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $spacetimeId -CommandId $cidS -Label 'SpacetimeDB' `
    -PollSeconds 5 -ThrowOnFailure

  $benchB64 = ''
  if (-not [string]::IsNullOrWhiteSpace($BenchmarkPwshArgs)) {
    $benchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BenchmarkPwshArgs.Trim()))
  }
  $ghB64 = if ([string]::IsNullOrWhiteSpace($GithubTokenB64)) { '' } else { $GithubTokenB64.Trim() }

  $mcParts = @()
  for ($i = 0; $i -lt $maxN; $i++) {
    $mcParts += "$($clusterIds[$i]):$($clusterIps[$i]):8090"
  }
  $managerClustersLine = $mcParts -join ','

  $driverPhase1Tpl = @'
#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
export REPO_URL="__REPO__"
export BRANCH="__BRANCH__"
export REMOTE_ROOT="__ROOT__"
export AWS_REGION="__REGION__"
export S3_BIN_PREFIX="__S3_BIN_PREFIX__"
GITHUB_TOKEN_B64="__GITHUB_TOKEN_B64__"

until command -v pwsh >/dev/null 2>&1 && command -v spacetime >/dev/null 2>&1; do
  echo "waiting for user-data (driver)..."
  sleep 10
done

echo "=== Clone repository ==="
mkdir -p "$(dirname "$REMOTE_ROOT")"
if [ ! -d "$REMOTE_ROOT/.git" ]; then
  git clone "$REPO_URL" "$REMOTE_ROOT"
fi
cd "$REMOTE_ROOT"
git fetch origin
if ! git checkout "$BRANCH"; then
  git checkout main || git checkout master
fi
git pull --ff-only || git pull

echo "=== Toolchain + submodules ==="
apt-get update -y
apt-get install -y binaryen pkg-config libssl-dev build-essential || true
if ! command -v rustc >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
rustup target add wasm32-unknown-unknown || true
export PATH="$HOME/.cargo/bin:/root/.local/bin:$PATH"

if [ -n "$GITHUB_TOKEN_B64" ]; then
  _GH_TOKEN=$(printf '%s' "$GITHUB_TOKEN_B64" | base64 -d)
  git config --global url."https://x-access-token:${_GH_TOKEN}@github.com/".insteadOf "https://github.com/"
  unset _GH_TOKEN
fi
git submodule update --init --recursive

echo "=== Build arcane-manager + arcane-cluster (release) ==="
(cd arcane && cargo build -p arcane-infra --bin arcane-manager --features manager --release)
(cd arcane && cargo build -p arcane-infra --bin arcane-cluster --features cluster-ws --release)

echo "=== Upload binaries to S3 ==="
aws s3 cp arcane/target/release/arcane-manager "${S3_BIN_PREFIX}/arcane-manager" --region "$AWS_REGION"
aws s3 cp arcane/target/release/arcane-cluster "${S3_BIN_PREFIX}/arcane-cluster" --region "$AWS_REGION"
echo "Done phase1 upload."
'@

  $driverPhase1 = $driverPhase1Tpl.
    Replace('__REPO__', (Escape-BashDoubleQuoted $RepoUrl)).
    Replace('__BRANCH__', (Escape-BashDoubleQuoted $Branch)).
    Replace('__ROOT__', (Escape-BashDoubleQuoted $remoteRoot)).
    Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
    Replace('__S3_BIN_PREFIX__', (Escape-BashDoubleQuoted $s3BinPrefix)).
    Replace('__GITHUB_TOKEN_B64__', $ghB64)
  $driverPhase1 = $driverPhase1 -replace "`r`n", "`n"

  Write-Host 'Driver SSM phase 1: clone + build + S3 upload...' -ForegroundColor Cyan
  $cidP1 = Send-SsmRunShellScript -Region $Region -InstanceId $benchId -ScriptBody $driverPhase1 `
    -Comment "Arcane arph driver build $RunId" -TimeoutSeconds 14400
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $benchId -CommandId $cidP1 -Label 'Driver build/upload' `
    -PollSeconds 10 -ThrowOnFailure

  $mgrScriptTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
export AWS_DEFAULT_REGION="__REGION__"
BIN_PREFIX="__S3_BIN_PREFIX__"
pkill -f '/opt/arcane-manager' 2>/dev/null || true
sleep 1
aws s3 cp "${BIN_PREFIX}/arcane-manager" /opt/arcane-manager
chmod +x /opt/arcane-manager
export MANAGER_CLUSTERS="__MC__"
export MANAGER_HTTP_PORT=8081
nohup /opt/arcane-manager >> /var/log/arcane-manager.log 2>&1 &
sleep 3
bash -c "echo >/dev/tcp/127.0.0.1/8081" 2>/dev/null || { echo "manager did not open 8081"; exit 1; }
echo "arcane-manager up."
'@

  $mgrScript = $mgrScriptTpl.
    Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
    Replace('__S3_BIN_PREFIX__', (Escape-BashDoubleQuoted $s3BinPrefix)).
    Replace('__MC__', (Escape-BashDoubleQuoted $managerClustersLine))
  $mgrScript = $mgrScript -replace "`r`n", "`n"

  Write-Host 'Starting arcane-manager on manager instance...' -ForegroundColor Cyan
  $cidM = Send-SsmRunShellScript -Region $Region -InstanceId $managerId -ScriptBody $mgrScript `
    -Comment "Arcane arph manager $RunId" -TimeoutSeconds 600
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $managerId -CommandId $cidM -Label 'Manager' `
    -PollSeconds 5 -ThrowOnFailure

  for ($i = 0; $i -lt $maxN; $i++) {
    $cidCluster = $clusterIds[$i]
    $others = @()
    for ($j = 0; $j -lt $maxN; $j++) {
      if ($j -ne $i) { $others += $clusterIds[$j] }
    }
    $neighborLine = $others -join ','

    $clTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
export AWS_DEFAULT_REGION="__REGION__"
BIN_PREFIX="__S3_BIN_PREFIX__"
pkill -f '/opt/arcane-cluster' 2>/dev/null || true
sleep 1
aws s3 cp "${BIN_PREFIX}/arcane-cluster" /opt/arcane-cluster
chmod +x /opt/arcane-cluster
export REDIS_URL="redis://__REDIS_IP__:6379"
export CLUSTER_ID="__CLUSTER_ID__"
export CLUSTER_WS_PORT=8090
export NEIGHBOR_IDS="__NEIGHBORS__"
nohup /opt/arcane-cluster >> /var/log/arcane-cluster.log 2>&1 &
sleep 3
bash -c "echo >/dev/tcp/127.0.0.1/8090" 2>/dev/null || { echo "cluster WS not listening"; exit 1; }
echo "arcane-cluster __CLUSTER_ID__ up."
'@

    $clScript = $clTpl.
      Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
      Replace('__S3_BIN_PREFIX__', (Escape-BashDoubleQuoted $s3BinPrefix)).
      Replace('__REDIS_IP__', (Escape-BashDoubleQuoted $redisIp)).
      Replace('__CLUSTER_ID__', (Escape-BashDoubleQuoted $cidCluster)).
      Replace('__NEIGHBORS__', (Escape-BashDoubleQuoted $neighborLine))
    $clScript = $clScript -replace "`r`n", "`n"

    $instId = $clusterInstIds[$i]
    Write-Host "Starting arcane-cluster on instance $instId (cluster $i)..." -ForegroundColor Cyan
    $cidC = Send-SsmRunShellScript -Region $Region -InstanceId $instId -ScriptBody $clScript `
      -Comment "Arcane arph cluster $i $RunId" -TimeoutSeconds 600
    $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $instId -CommandId $cidC -Label "Cluster $i" `
      -PollSeconds 5 -ThrowOnFailure
  }

  $achInner = ($clusterIps | ForEach-Object { "'$_'" }) -join ','
  $pwshClusterHostsArg = "@($achInner)"

  $driverPhase2Tpl = @'
#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
export REMOTE_ROOT="__ROOT__"
export REMOTE_OUT="__OUT__"
export S3_DEST="__S3__"
export AWS_REGION="__REGION__"
export BENCH_B64="__BENCH_B64__"
export REDIS_IP="__REDIS_IP__"
export ST_IP="__ST_IP__"
export MGR_IP="__MGR_IP__"
ST_URL="http://${ST_IP}:3000"

cd "$REMOTE_ROOT"

echo "=== Reachability from driver ==="
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$REDIS_IP/6379" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$REDIS_IP/6379" 2>/dev/null || { echo "ERROR: Redis"; exit 1; }
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null || { echo "ERROR: SpacetimeDB"; exit 1; }
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$MGR_IP/8081" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$MGR_IP/8081" 2>/dev/null || { echo "ERROR: manager"; exit 1; }
__CLUSTER_TCP_CHECKS__

echo "=== Publish module ==="
(cd spacetimedb_demo/spacetimedb && spacetime build && spacetime publish arcane --yes --anonymous -s "$ST_URL")

mkdir -p "$REMOTE_OUT"
set +e
if [ -n "$BENCH_B64" ]; then
  EXTRA=$(printf '%s' "$BENCH_B64" | base64 -d)
  pwsh -NoProfile -Command "& \"${REMOTE_ROOT}/scripts/Run-Benchmark.ps1\" -OutDir \"${REMOTE_OUT}\" -RedisHost \"${REDIS_IP}\" -RedisPort 6379 -SpacetimeHost \"${ST_URL}\" -Environment AwsArcanePerHost -ArcaneExternalProcesses -ArcaneManagerHost \"${MGR_IP}\" -ArcaneManagerPort 8081 -ArcaneClusterPortStride 0 -ArcaneClusterHosts __ACH__ ${EXTRA}"
else
  pwsh -NoProfile -Command "& \"${REMOTE_ROOT}/scripts/Run-Benchmark.ps1\" -OutDir \"${REMOTE_OUT}\" -RedisHost \"${REDIS_IP}\" -RedisPort 6379 -SpacetimeHost \"${ST_URL}\" -Environment AwsArcanePerHost -ArcaneExternalProcesses -ArcaneManagerHost \"${MGR_IP}\" -ArcaneManagerPort 8081 -ArcaneClusterPortStride 0 -ArcaneClusterHosts __ACH__"
fi
EC=$?
set -e

aws s3 sync "$REMOTE_OUT" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@

  $tcpChecks = [System.Collections.Generic.List[string]]::new()
  foreach ($ip in $clusterIps) {
    [void]$tcpChecks.Add(('for i in $(seq 1 60); do bash -c "echo >/dev/tcp/{0}/8090" 2>/dev/null && break; sleep 2; done' -f $ip))
    [void]$tcpChecks.Add(('bash -c "echo >/dev/tcp/{0}/8090" 2>/dev/null || {{ echo "ERROR: cluster {0}:8090"; exit 1; }}' -f $ip))
  }
  $clusterTcpBlock = $tcpChecks -join "`n"

  $driverPhase2 = $driverPhase2Tpl.
    Replace('__ROOT__', (Escape-BashDoubleQuoted $remoteRoot)).
    Replace('__OUT__', (Escape-BashDoubleQuoted $remoteOutDir)).
    Replace('__S3__', (Escape-BashDoubleQuoted $s3Dest)).
    Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
    Replace('__BENCH_B64__', $benchB64).
    Replace('__REDIS_IP__', (Escape-BashDoubleQuoted $redisIp)).
    Replace('__ST_IP__', (Escape-BashDoubleQuoted $stIp)).
    Replace('__MGR_IP__', (Escape-BashDoubleQuoted $mgrIp)).
    Replace('__CLUSTER_TCP_CHECKS__', $clusterTcpBlock).
    Replace('__ACH__', $pwshClusterHostsArg)
  $driverPhase2 = $driverPhase2 -replace "`r`n", "`n"

  Write-Host 'Driver SSM phase 2: publish + Run-Benchmark.ps1...' -ForegroundColor Cyan
  $cmdId = Send-SsmRunShellScript -Region $Region -InstanceId $benchId -ScriptBody $driverPhase2 `
    -Comment "Arcane arph driver benchmark $RunId" -TimeoutSeconds $SsmDriverBenchmarkTimeoutSeconds

  $inv = Wait-SsmCommandInvocation -Region $Region -InstanceId $benchId -CommandId $cmdId -Label 'Driver benchmark' -PollSeconds 10
  Write-Host '--- stdout (tail) ---' -ForegroundColor DarkGray
  ($inv.StandardOutputContent -split "`n" | Select-Object -Last 80) -join "`n"
  Write-Host '--- stderr (tail) ---' -ForegroundColor DarkGray
  ($inv.StandardErrorContent -split "`n" | Select-Object -Last 40) -join "`n"

  Write-Host "Staged to S3: $s3Dest" -ForegroundColor Green

  [pscustomobject]@{
    Invocation = $inv
    S3Dest     = $s3Dest
    RunId      = $RunId
  }
}
