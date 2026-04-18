# AwsArcanePerHost driver. Every arcane-side process (manager, cluster, driver)
# runs the same pre-built image with a different role command. SpacetimeDB runs
# the same image as `spacetime start`. Redis runs the stock redis:7-alpine.
# No compile, git clone, or `spacetime publish` happens on EC2.
#
# Requires: lib/AwsHelpers.ps1 dot-sourced by the caller.

function Invoke-AwsArcanePerHostRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$ArtifactBucket,
    [string]$ArtifactPrefix = 'benchmark-aws',
    [Parameter(Mandatory)][string]$BenchmarkImage,
    [Parameter(Mandatory)][string]$ContainerConfigPath,
    [int]$SsmDriverBenchmarkTimeoutSeconds = 28800
  )

  if ($State.Environment -ne 'AwsArcanePerHost') {
    throw "Invoke-AwsArcanePerHostRemoteBenchmark: state Environment must be AwsArcanePerHost (got '$($State.Environment)')."
  }
  if ([string]::IsNullOrWhiteSpace($BenchmarkImage)) {
    throw 'BenchmarkImage is required (e.g. ghcr.io/brainy-bots/arcane-benchmark:v0.1.0).'
  }

  $Region = $State.Region
  $redisId = $State.RedisInstanceId
  $spacetimeId = $State.SpacetimeInstanceId
  $managerId = $State.ManagerInstanceId
  $benchId = $State.BenchmarkInstanceId
  $maxN = [int]$State.MaxArcaneClusters
  $clusterIds = @($State.ClusterIds) | ForEach-Object { "$_".Trim() }
  $clusterInstIds = @($State.ClusterInstanceIds) | ForEach-Object { "$_".Trim() }

  if ($maxN -lt 1) { throw 'State MaxArcaneClusters must be >= 1.' }
  if ($clusterIds.Count -ne $maxN -or $clusterInstIds.Count -ne $maxN) {
    throw "State ClusterIds ($($clusterIds.Count)) and ClusterInstanceIds ($($clusterInstIds.Count)) must each have MaxArcaneClusters=$maxN entries."
  }

  $envSeg = 'AwsArcanePerHost'
  $s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/"

  $redisIp = Get-Ec2PrivateIp -Region $Region -InstanceId $redisId
  $stIp = Get-Ec2PrivateIp -Region $Region -InstanceId $spacetimeId
  $mgrIp = Get-Ec2PrivateIp -Region $Region -InstanceId $managerId
  $clusterIps = @()
  foreach ($cid in $clusterInstIds) {
    $clusterIps += Get-Ec2PrivateIp -Region $Region -InstanceId $cid
  }

  Write-Host "Private IPs: Redis=$redisIp SpacetimeDB=$stIp Manager=$mgrIp Clusters=$($clusterIps -join ', '). Image=$BenchmarkImage" -ForegroundColor DarkGray

  # ── 1. Redis (stock upstream image — no benchmark code involved) ───────────
  $redisScript = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker rm -f arcane-bench-redis 2>/dev/null || true
docker pull redis:7-alpine
docker run -d --name arcane-bench-redis -p 0.0.0.0:6379:6379 redis:7-alpine redis-server --appendonly yes
for i in $(seq 1 90); do docker exec arcane-bench-redis redis-cli ping 2>/dev/null | grep -q PONG && exit 0; sleep 1; done
exit 1
'@

  # ── 2. SpacetimeDB (our image, spacetime-start role + Persist module publish) ─
  $stTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker pull "$IMG"
docker rm -f arcane-bench-spacetime 2>/dev/null || true
docker run -d --name arcane-bench-spacetime -p 0.0.0.0:3000:3000 "$IMG" spacetime start
for i in $(seq 1 120); do bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null || { echo "ERROR: SpacetimeDB not listening"; exit 1; }
docker run --rm --network host "$IMG" benchmark-publish-module --mode Persist --host http://127.0.0.1:3000
'@
  $stScript = $stTpl.Replace('__IMG__', (Escape-BashDoubleQuoted $BenchmarkImage)) -replace "`r`n", "`n"

  $cidR = Send-SsmRunShellScript -Region $Region -InstanceId $redisId -ScriptBody $redisScript `
    -Comment "Arcane bench redis (arph) $RunId" -TimeoutSeconds 1200
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $redisId -CommandId $cidR -Label 'Redis' `
    -PollSeconds 5 -ThrowOnFailure

  $cidS = Send-SsmRunShellScript -Region $Region -InstanceId $spacetimeId -ScriptBody $stScript `
    -Comment "Arcane bench spacetime (arph) $RunId" -TimeoutSeconds 1800
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $spacetimeId -CommandId $cidS -Label 'SpacetimeDB' `
    -PollSeconds 5 -ThrowOnFailure

  # ── 3. arcane-manager — same image, manager role ──────────────────────────
  $mcParts = @()
  for ($i = 0; $i -lt $maxN; $i++) {
    $mcParts += "$($clusterIds[$i]):$($clusterIps[$i]):8090"
  }
  $managerClustersLine = $mcParts -join ','

  $mgrTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker pull "$IMG"
docker rm -f arcane-bench-manager 2>/dev/null || true
docker run -d --name arcane-bench-manager --network host \
  -e MANAGER_HTTP_PORT=8081 \
  -e MANAGER_CLUSTERS="__MC__" \
  "$IMG" arcane-manager
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/127.0.0.1/8081" 2>/dev/null && exit 0; sleep 1; done
echo "ERROR: manager did not open 8081"; docker logs arcane-bench-manager --tail 50 || true; exit 1
'@
  $mgrScript = $mgrTpl.
    Replace('__IMG__', (Escape-BashDoubleQuoted $BenchmarkImage)).
    Replace('__MC__', (Escape-BashDoubleQuoted $managerClustersLine))
  $mgrScript = $mgrScript -replace "`r`n", "`n"

  Write-Host 'Starting arcane-manager container on manager instance...' -ForegroundColor Cyan
  $cidM = Send-SsmRunShellScript -Region $Region -InstanceId $managerId -ScriptBody $mgrScript `
    -Comment "Arcane arph manager $RunId" -TimeoutSeconds 600
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $managerId -CommandId $cidM -Label 'Manager' `
    -PollSeconds 5 -ThrowOnFailure

  # ── 4. benchmark-cluster on each cluster node ─────────────────────────────
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
IMG="__IMG__"
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker pull "$IMG"
docker rm -f arcane-bench-cluster 2>/dev/null || true
docker run -d --name arcane-bench-cluster --network host \
  -e CLUSTER_ID="__CLUSTER_ID__" \
  -e REDIS_URL="redis://__REDIS_IP__:6379" \
  -e NEIGHBOR_IDS="__NEIGHBORS__" \
  -e CLUSTER_WS_PORT=8090 \
  -e SPACETIMEDB_URI="http://__ST_IP__:3000" \
  -e SPACETIMEDB_DATABASE=arcane \
  -e SPACETIMEDB_PERSIST=1 \
  -e SPACETIMEDB_PERSIST_HZ=1 \
  "$IMG" benchmark-cluster
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/127.0.0.1/8090" 2>/dev/null && exit 0; sleep 1; done
echo "ERROR: cluster WS not listening on 8090"; docker logs arcane-bench-cluster --tail 80 || true; exit 1
'@
    $clScript = $clTpl.
      Replace('__IMG__',        (Escape-BashDoubleQuoted $BenchmarkImage)).
      Replace('__REDIS_IP__',   (Escape-BashDoubleQuoted $redisIp)).
      Replace('__ST_IP__',      (Escape-BashDoubleQuoted $stIp)).
      Replace('__CLUSTER_ID__', (Escape-BashDoubleQuoted $cidCluster)).
      Replace('__NEIGHBORS__',  (Escape-BashDoubleQuoted $neighborLine))
    $clScript = $clScript -replace "`r`n", "`n"

    $instId = $clusterInstIds[$i]
    Write-Host "Starting benchmark-cluster container on $instId (cluster $i)..." -ForegroundColor Cyan
    $cidC = Send-SsmRunShellScript -Region $Region -InstanceId $instId -ScriptBody $clScript `
      -Comment "Arcane arph cluster $i $RunId" -TimeoutSeconds 600
    $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $instId -CommandId $cidC -Label "Cluster $i" `
      -PollSeconds 5 -ThrowOnFailure
  }

  # ── 5. Driver — image + run-benchmark-sweep + aws s3 sync ─────────────────
  # run-benchmark-sweep invokes pwsh with -Command, so the tail is parsed as
  # PowerShell. Emit a PS array literal for -ArcaneClusterHosts.
  $achInner = ($clusterIps | ForEach-Object { "'$_'" }) -join ','
  $pwshClusterHostsArg = "-ArcaneClusterHosts $achInner"

  $drvTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"
CONFIG_PATH="__CONFIG_PATH__"
S3_DEST="__S3__"
AWS_REGION="__REGION__"
REDIS_IP="__REDIS_IP__"
ST_IP="__ST_IP__"
MGR_IP="__MGR_IP__"

for i in $(seq 1 90); do docker info >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && break; sleep 5; done

# Reachability checks from the driver.
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$REDIS_IP/6379" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$REDIS_IP/6379" 2>/dev/null || { echo "ERROR: Redis"; exit 1; }
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$ST_IP/3000"  2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$ST_IP/3000"  2>/dev/null || { echo "ERROR: SpacetimeDB"; exit 1; }
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$MGR_IP/8081" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$MGR_IP/8081" 2>/dev/null || { echo "ERROR: manager"; exit 1; }
__CLUSTER_TCP_CHECKS__

docker pull "$IMG"

OUT_DIR="/var/arcane-benchmark-out"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"

set +e
docker run --rm \
  -v "$OUT_DIR:/var/benchmark/out" \
  "$IMG" run-benchmark-sweep \
    --config "$CONFIG_PATH" \
    --spacetime-host "http://${ST_IP}:3000" \
    --environment AwsArcanePerHost \
    -- \
    -RedisHost "${REDIS_IP}" -RedisPort 6379 \
    -ArcaneExternalProcesses \
    -ArcaneManagerHost "${MGR_IP}" -ArcaneManagerPort 8081 \
    -ArcaneClusterPortStride 0 \
    __ACH__
EC=$?
set -e

aws s3 sync "$OUT_DIR" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@

  $tcpChecks = [System.Collections.Generic.List[string]]::new()
  foreach ($ip in $clusterIps) {
    [void]$tcpChecks.Add(('for i in $(seq 1 60); do bash -c "echo >/dev/tcp/{0}/8090" 2>/dev/null && break; sleep 2; done' -f $ip))
    [void]$tcpChecks.Add(('bash -c "echo >/dev/tcp/{0}/8090" 2>/dev/null || {{ echo "ERROR: cluster {0}:8090"; exit 1; }}' -f $ip))
  }
  $clusterTcpBlock = $tcpChecks -join "`n"

  $drvScript = $drvTpl.
    Replace('__IMG__',         (Escape-BashDoubleQuoted $BenchmarkImage)).
    Replace('__CONFIG_PATH__', (Escape-BashDoubleQuoted $ContainerConfigPath)).
    Replace('__S3__',          (Escape-BashDoubleQuoted $s3Dest)).
    Replace('__REGION__',      (Escape-BashDoubleQuoted $Region)).
    Replace('__REDIS_IP__',    (Escape-BashDoubleQuoted $redisIp)).
    Replace('__ST_IP__',       (Escape-BashDoubleQuoted $stIp)).
    Replace('__MGR_IP__',      (Escape-BashDoubleQuoted $mgrIp)).
    Replace('__CLUSTER_TCP_CHECKS__', $clusterTcpBlock).
    Replace('__ACH__',         $pwshClusterHostsArg)
  $drvScript = $drvScript -replace "`r`n", "`n"

  Write-Host 'Sending driver SSM run command...' -ForegroundColor Cyan
  $cmdId = Send-SsmRunShellScript -Region $Region -InstanceId $benchId -ScriptBody $drvScript `
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
