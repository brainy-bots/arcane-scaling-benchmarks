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
    [Parameter(Mandatory)][string]$S3ConfigUri,
    [int]$ClusterTickRateHz = 20,
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
  # Multi-driver: BenchmarkInstanceIds (plural list) is the authoritative set.
  # Older state files only had BenchmarkInstanceId (singular) — fall back to
  # wrapping that into a 1-element list so single-driver paths keep working.
  $driverInstIds = @()
  if ($State.PSObject.Properties.Name -contains 'BenchmarkInstanceIds' -and $State.BenchmarkInstanceIds) {
    $driverInstIds = @($State.BenchmarkInstanceIds) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
  }
  if ($driverInstIds.Count -eq 0 -and $benchId) { $driverInstIds = @("$benchId") }
  $driverCount = $driverInstIds.Count
  $maxN = [int]$State.MaxArcaneClusters
  $clusterIds = @($State.ClusterIds) | ForEach-Object { "$_".Trim() }
  $clusterInstIds = @($State.ClusterInstanceIds) | ForEach-Object { "$_".Trim() }

  if ($maxN -lt 1) { throw 'State MaxArcaneClusters must be >= 1.' }
  if ($driverCount -lt 1) { throw 'State BenchmarkInstanceIds must contain >= 1 driver.' }
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
$redisScript = $redisScript -replace "`r`n", "`n"

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
  --ulimit nofile=65536:65536 \
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
# --ulimit nofile lifts the container's file-descriptor ceiling above the
# host default (1024) so the cluster's accept loop doesn't hit EMFILE at
# roughly one socket per connected client. At 6000-player sweep ceiling ÷
# 2 clusters, each cluster holds ~3000 client sockets, well under 65536.
docker run -d --name arcane-bench-cluster --network host \
  --ulimit nofile=65536:65536 \
  -e NODE_ID="__CLUSTER_ID__" \
  -e REDIS_URL="redis://__REDIS_IP__:6379" \
  -e NEIGHBOR_IDS="__NEIGHBORS__" \
  -e NODE_WS_PORT=8090 \
  -e SPACETIMEDB_URI="http://__ST_IP__:3000" \
  -e SPACETIMEDB_DATABASE=arcane \
  -e SPACETIMEDB_PERSIST=1 \
  -e SPACETIMEDB_PERSIST_HZ=1 \
  -e BENCHMARK_TICK_RATE_HZ="__TICK_RATE_HZ__" \
  -e ARCANE_BROADCAST_CHANNEL_CAP=256 \
  "$IMG" benchmark-cluster
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/127.0.0.1/8090" 2>/dev/null && exit 0; sleep 1; done
echo "ERROR: cluster WS not listening on 8090"; docker logs arcane-bench-cluster --tail 80 || true; exit 1
'@
    $clScript = $clTpl.
      Replace('__IMG__',           (Escape-BashDoubleQuoted $BenchmarkImage)).
      Replace('__REDIS_IP__',      (Escape-BashDoubleQuoted $redisIp)).
      Replace('__ST_IP__',         (Escape-BashDoubleQuoted $stIp)).
      Replace('__CLUSTER_ID__',    (Escape-BashDoubleQuoted $cidCluster)).
      Replace('__NEIGHBORS__',     (Escape-BashDoubleQuoted $neighborLine)).
      Replace('__TICK_RATE_HZ__',  (Escape-BashDoubleQuoted ([string]$ClusterTickRateHz)))
    $clScript = $clScript -replace "`r`n", "`n"

    $instId = $clusterInstIds[$i]
    Write-Host "Starting benchmark-cluster container on $instId (cluster $i)..." -ForegroundColor Cyan
    $cidC = Send-SsmRunShellScript -Region $Region -InstanceId $instId -ScriptBody $clScript `
      -Comment "Arcane arph cluster $i $RunId" -TimeoutSeconds 600
    $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $instId -CommandId $cidC -Label "Cluster $i" `
      -PollSeconds 5 -ThrowOnFailure
  }

  # ── 5. Driver — image + run-benchmark + aws s3 sync ───────────────────────
  # run-benchmark invokes pwsh with -Command, so the tail is parsed as
  # PowerShell. Emit a PS array literal for -ArcaneClusterHosts.
  $achInner = ($clusterIps | ForEach-Object { "'$_'" }) -join ','
  $pwshClusterHostsArg = "-ArcaneClusterHosts $achInner"

  $drvTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"
CONFIG_PATH="__CONFIG_PATH__"
S3_CONFIG="__S3_CONFIG__"
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

# Stage the run's config from S3 onto the driver host, then bind-mount it into
# the container at /opt/benchmark/runtime-configs. Configs are no longer baked
# into the image; the host orchestrator uploaded the selected file before SSM.
RUNTIME_CFG_DIR="/var/arcane-benchmark-runtime-config"
rm -rf "$RUNTIME_CFG_DIR" && mkdir -p "$RUNTIME_CFG_DIR"
aws s3 cp "$S3_CONFIG" "$RUNTIME_CFG_DIR/" --region "$AWS_REGION" \
  || { echo "ERROR: failed to download config from $S3_CONFIG"; exit 1; }

set +e
docker rm -f arcane-bench-driver 2>/dev/null || true
docker run --rm --name arcane-bench-driver \
  --ulimit nofile=65536:65536 \
  -v "$OUT_DIR:/var/benchmark/out" \
  -v "$RUNTIME_CFG_DIR:/opt/benchmark/runtime-configs:ro" \
  "$IMG" run-benchmark \
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

  # Per-driver SSM fan-out. Each driver runs the same bash script with a
  # per-driver S3 destination subpath (driver-N/) so their outputs don't
  # collide. send-command happens N times sequentially (each is an API call,
  # not the benchmark itself). The benchmark workloads run in parallel inside
  # AWS — we wait for all invocations together below.
  $driverInvocations = New-Object System.Collections.Generic.List[object]
  $driverFailures = 0
  Write-Host "Multi-driver fan-out: $driverCount driver(s) on the manager." -ForegroundColor Cyan

  try {
    for ($di = 0; $di -lt $driverCount; $di++) {
      $thisDriverInstanceId = $driverInstIds[$di]
      # driverCount==1 keeps the historical single-driver path: outputs land
      # at $s3Dest (no driver-N/ subdir) so existing analysis scripts and the
      # validity-gate code path stay backward-compatible.
      $perDriverS3 = if ($driverCount -eq 1) { $s3Dest } else { "$s3Dest" + "driver-$di/" }

      $drvScript = $drvTpl.
        Replace('__IMG__',         (Escape-BashDoubleQuoted $BenchmarkImage)).
        Replace('__CONFIG_PATH__', (Escape-BashDoubleQuoted $ContainerConfigPath)).
        Replace('__S3_CONFIG__',   (Escape-BashDoubleQuoted $S3ConfigUri)).
        Replace('__S3__',          (Escape-BashDoubleQuoted $perDriverS3)).
        Replace('__REGION__',      (Escape-BashDoubleQuoted $Region)).
        Replace('__REDIS_IP__',    (Escape-BashDoubleQuoted $redisIp)).
        Replace('__ST_IP__',       (Escape-BashDoubleQuoted $stIp)).
        Replace('__MGR_IP__',      (Escape-BashDoubleQuoted $mgrIp)).
        Replace('__CLUSTER_TCP_CHECKS__', $clusterTcpBlock).
        Replace('__ACH__',         $pwshClusterHostsArg)
      $drvScript = $drvScript -replace "`r`n", "`n"

      Write-Host "  driver-$di SSM send → $thisDriverInstanceId (S3 → $perDriverS3)" -ForegroundColor DarkGray
      $cmdId = Send-SsmRunShellScript -Region $Region -InstanceId $thisDriverInstanceId -ScriptBody $drvScript `
        -Comment "Arcane arph driver-$di benchmark $RunId" -TimeoutSeconds $SsmDriverBenchmarkTimeoutSeconds
      $driverInvocations.Add([pscustomobject]@{
          Index      = $di
          InstanceId = $thisDriverInstanceId
          CommandId  = $cmdId
          S3Dest     = $perDriverS3
          Inv        = $null
        })
    }

    # Wait for ALL driver invocations in parallel. Same sequential-poll loop
    # the single-driver path uses, just iterated across the open invocations.
    # Each driver is independent — any driver failing does NOT abort others;
    # final pass/fail aggregation happens in the post-process aggregator.
    #
    # Transient AWS API failures (throttle, network blip, non-JSON output)
    # are tolerated up to MaxConsecutivePollFailures per driver; the driver
    # stays in $pending and we retry next iteration. If a driver hits the
    # cap we mark it failed with a synthetic Inv so downstream tail-output
    # code doesn't null-deref.
    $maxConsecutivePollFailures = 6
    foreach ($e in $driverInvocations) {
      $e | Add-Member -NotePropertyName ConsecutiveFailures -NotePropertyValue 0 -Force
    }
    $pending = [System.Collections.Generic.List[object]]::new($driverInvocations)
    while ($pending.Count -gt 0) {
      Start-Sleep -Seconds 10
      $stillPending = New-Object System.Collections.Generic.List[object]
      foreach ($e in $pending) {
        $invRaw = aws ssm get-command-invocation --region $Region --command-id $e.CommandId --instance-id $e.InstanceId --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
          $e.ConsecutiveFailures++
          Write-Host "  driver-$($e.Index) get-command-invocation failed (consecutive=$($e.ConsecutiveFailures)/$maxConsecutivePollFailures): $invRaw" -ForegroundColor Yellow
          if ($e.ConsecutiveFailures -ge $maxConsecutivePollFailures) {
            Write-Host "  driver-$($e.Index) giving up after $maxConsecutivePollFailures consecutive poll failures" -ForegroundColor Red
            $e.Inv = [pscustomobject]@{
              Status                = 'PollFailed'
              StandardOutputContent = ''
              StandardErrorContent  = "orchestrator gave up after $maxConsecutivePollFailures consecutive get-command-invocation failures"
            }
            $driverFailures++
          } else {
            $stillPending.Add($e)
          }
          continue
        }
        $inv = $null
        try {
          $inv = $invRaw | ConvertFrom-Json -ErrorAction Stop
        } catch {
          $e.ConsecutiveFailures++
          Write-Host "  driver-$($e.Index) ConvertFrom-Json failed (consecutive=$($e.ConsecutiveFailures)/$maxConsecutivePollFailures): $_" -ForegroundColor Yellow
          if ($e.ConsecutiveFailures -ge $maxConsecutivePollFailures) {
            Write-Host "  driver-$($e.Index) giving up after $maxConsecutivePollFailures consecutive parse failures" -ForegroundColor Red
            $e.Inv = [pscustomobject]@{
              Status                = 'ParseFailed'
              StandardOutputContent = ''
              StandardErrorContent  = "orchestrator gave up after $maxConsecutivePollFailures consecutive ConvertFrom-Json failures"
            }
            $driverFailures++
          } else {
            $stillPending.Add($e)
          }
          continue
        }
        # Successful poll resets the consecutive-failure counter.
        $e.ConsecutiveFailures = 0
        if ($inv.Status -in 'Pending', 'InProgress', 'Delayed') {
          $stillPending.Add($e)
        } else {
          $e.Inv = $inv
          $color = if ($inv.Status -eq 'Success') { 'Green' } else { 'Yellow' }
          Write-Host "  driver-$($e.Index) Status=$($inv.Status)" -ForegroundColor $color
          if ($inv.Status -ne 'Success') { $driverFailures++ }
        }
      }
      $pending = $stillPending
    }

    foreach ($e in $driverInvocations) {
      Write-Host "--- driver-$($e.Index) stdout (tail) ---" -ForegroundColor DarkGray
      ($e.Inv.StandardOutputContent -split "`n" | Select-Object -Last 60) -join "`n"
      Write-Host "--- driver-$($e.Index) stderr (tail) ---" -ForegroundColor DarkGray
      ($e.Inv.StandardErrorContent -split "`n" | Select-Object -Last 30) -join "`n"
      Write-Host "Driver-$($e.Index) staged to S3: $($e.S3Dest)" -ForegroundColor Green
    }

    if ($driverFailures -gt 0) {
      Write-Host "WARNING: $driverFailures of $driverCount driver(s) reported non-Success SSM status; check S3 outputs and per-driver tails above." -ForegroundColor Yellow
    }
  } finally {
    # Always capture per-node container logs so we can diagnose failures like
    # "swarm WS closed mid-sweep" where the driver's CSV says nothing useful.
    $diagRoot = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/diag"
    Write-Host "Capturing node logs to $diagRoot ..." -ForegroundColor Cyan

    $nodes = @(
      [pscustomobject]@{ Label = 'redis';     InstanceId = $redisId }
      [pscustomobject]@{ Label = 'spacetime'; InstanceId = $spacetimeId }
      [pscustomobject]@{ Label = 'manager';   InstanceId = $managerId }
    )
    for ($i = 0; $i -lt $maxN; $i++) {
      $nodes += [pscustomobject]@{ Label = "cluster$i"; InstanceId = $clusterInstIds[$i] }
    }
    # Multi-driver: capture each driver instance too. Single-driver runs keep
    # the historical Label='driver' so existing diag-walking scripts that hard-
    # code that name continue to find it.
    if ($driverCount -eq 1) {
      $nodes += [pscustomobject]@{ Label = 'driver'; InstanceId = $driverInstIds[0] }
    } else {
      for ($i = 0; $i -lt $driverCount; $i++) {
        $nodes += [pscustomobject]@{ Label = "driver$i"; InstanceId = $driverInstIds[$i] }
      }
    }

    $diagTpl = @'
#!/bin/bash
set -uo pipefail
LABEL="__LABEL__"
DIAG="/tmp/arph-diag-$LABEL"
rm -rf "$DIAG" && mkdir -p "$DIAG"

docker ps -a > "$DIAG/docker_ps.txt" 2>&1 || true

for c in arcane-bench-redis arcane-bench-spacetime arcane-bench-manager arcane-bench-cluster arcane-bench-driver; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker logs --tail 20000 --timestamps "$c" > "$DIAG/$c.log" 2>&1 || true
    docker inspect "$c" > "$DIAG/$c.inspect.json" 2>&1 || true
  fi
done

dmesg --ctime 2>/dev/null | tail -500 > "$DIAG/dmesg.log" 2>/dev/null || \
  dmesg 2>/dev/null | tail -500 > "$DIAG/dmesg.log" 2>/dev/null || true

aws s3 cp "$DIAG" "__DIAG_ROOT__/$LABEL/" --recursive --region "__REGION__" || exit 1
echo "diag uploaded to __DIAG_ROOT__/$LABEL/"
'@

    foreach ($n in $nodes) {
      try {
        $script = $diagTpl.
          Replace('__LABEL__',     (Escape-BashDoubleQuoted $n.Label)).
          Replace('__DIAG_ROOT__', (Escape-BashDoubleQuoted $diagRoot)).
          Replace('__REGION__',    (Escape-BashDoubleQuoted $Region))
        $script = $script -replace "`r`n", "`n"
        $dcId = Send-SsmRunShellScript -Region $Region -InstanceId $n.InstanceId -ScriptBody $script `
          -Comment "Arcane arph diag $($n.Label) $RunId" -TimeoutSeconds 300
        $diagInv = Wait-SsmCommandInvocation -Region $Region -InstanceId $n.InstanceId -CommandId $dcId `
          -Label "Diag $($n.Label)" -PollSeconds 3
        # Wait-SsmCommandInvocation returns without throwing even on Status=Failed
        # (diag is best-effort, so we don't want one failure to abort teardown).
        # Surface the on-host stderr tail when the script fails so future diag
        # breakages are self-diagnosing instead of appearing as a silent "5/5 Failed".
        if ($diagInv.Status -ne 'Success') {
          $errTail = ($diagInv.StandardErrorContent -split "`n" | Select-Object -Last 20) -join "`n"
          $outTail = ($diagInv.StandardOutputContent -split "`n" | Select-Object -Last 10) -join "`n"
          Write-Warning "Diag capture for $($n.Label) ($($n.InstanceId)) Status=$($diagInv.Status)."
          Write-Host "--- diag stderr tail ---" -ForegroundColor DarkGray
          Write-Host $errTail
          Write-Host "--- diag stdout tail ---" -ForegroundColor DarkGray
          Write-Host $outTail
        }
      } catch {
        Write-Warning "Diag capture for $($n.Label) ($($n.InstanceId)) failed: $($_.Exception.Message). Continuing with remaining nodes."
      }
    }

    Write-Host "Diagnostic logs at: $diagRoot" -ForegroundColor Green
  }

  [pscustomobject]@{
    Invocation = $inv
    S3Dest     = $s3Dest
    DiagRoot   = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/diag"
    RunId      = $RunId
  }
}
