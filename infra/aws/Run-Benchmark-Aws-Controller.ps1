<#
.SYNOPSIS
  Run the benchmark via the new controller path on AWS. Starts the support
  fleet (Redis, SpacetimeDB, manager, clusters), starts the orchestrator on
  the manager EC2, starts drivers in orchestrated mode, runs the local
  benchmark-controller against the orchestrator's public HTTP API, then
  stops everything.

.DESCRIPTION
  Two-phase lifecycle: this script handles the *run* phase only.

    1. terraform apply  (in infra/terraform/aws_benchmark) — provisions the
       fleet. Pass var.benchmark_image (the dev tag) and
       var.operator_cidr_blocks (your laptop's public IP /32).
    2. THIS SCRIPT      — drives the run via SSM + the local controller.
    3. terraform destroy — tear down.

  Differences from Run-Benchmark-Aws.ps1:
  - No per-tier PowerShell loop; the local benchmark-controller drives the
    schedule against the orchestrator's HTTP API.
  - Drivers run with --orchestrator-url instead of being driven via per-driver
    SSM RunCommand fan-out.
  - The orchestrator container runs alongside arcane-manager on the
    manager EC2.

.PARAMETER StatePath
  JSON produced by `terraform output -json benchmark_state` in
  infra/terraform/aws_benchmark.

.PARAMETER PlanFile
  Path to a TOML test plan. Sample: plans/headline-13500.toml.

.PARAMETER BenchmarkImage
  Pre-built benchmark image reference, e.g.
  ghcr.io/brainy-bots/arcane-benchmark:dev-2026-05-02. Must include the
  arcane-swarm-orchestrator + benchmark-controller binaries.

.PARAMETER ControllerBinary
  Path to the benchmark-controller binary. Defaults to looking for
  target/release/benchmark-controller in this repo.

.PARAMETER ResultsDir
  Local directory to write phase_*.json + manifest.json. Defaults to
  results/runs/<Environment>/<RunId>/.

.PARAMETER S3UploadResults
  Switch — if set, the controller uploads phase + manifest files to the
  Terraform-created S3 artifact bucket under the same prefix the
  Terraform run uses.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $PlanFile,
    [Parameter(Mandatory)] [string] $BenchmarkImage,
    [string] $ControllerBinary,
    [string] $ResultsDir,
    [switch] $S3UploadResults
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $StatePath)) { throw "Terraform state file not found: $StatePath" }
if (-not (Test-Path $PlanFile))  { throw "Plan file not found: $PlanFile" }

# Resolve controller binary.
if (-not $ControllerBinary) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $candidate = Join-Path $repoRoot 'target/release/benchmark-controller'
    if (-not (Test-Path $candidate)) {
        $candidate = Join-Path $repoRoot 'target/debug/benchmark-controller'
    }
    if (-not (Test-Path $candidate)) {
        throw "benchmark-controller binary not found. Build it with: cargo build -p benchmark-controller --release"
    }
    $ControllerBinary = $candidate
}

# Read Terraform state.
$state = Get-Content -Raw $StatePath | ConvertFrom-Json
$envName = $state.Environment
$region  = $state.Region
$bucket  = $state.ArtifactBucket
$prefix  = $state.ArtifactPrefix
$runId   = (Get-Date -Format 'yyyyMMdd_HHmmss')

$managerInstanceId   = $state.ManagerInstanceId
$managerPrivateIp    = $state.ManagerPrivateIp
$managerPublicDns    = $state.ManagerPublicDns
$orchHttpPort        = if ($state.OrchestratorHttpPort)   { [int]$state.OrchestratorHttpPort }   else { 8090 }
$orchDriverPort      = if ($state.OrchestratorDriverPort) { [int]$state.OrchestratorDriverPort } else { 8088 }
$clusterIds          = @($state.ClusterIds)
$clusterPrivateIps   = @($state.ClusterPrivateIps)
$clusterInstanceIds  = @($state.ClusterInstanceIds)
$driverInstanceIds   = @($state.BenchmarkInstanceIds)
$spacetimeInstanceId = $state.SpacetimeInstanceId
$redisInstanceId     = $state.RedisInstanceId

if (-not $managerInstanceId)   { throw "State missing ManagerInstanceId — provision with arcane_per_host topology" }
if (-not $managerPublicDns)    { throw "State missing ManagerPublicDns — bump Terraform module to expose it" }
if ($driverInstanceIds.Count -lt 1) { throw "State has no driver instances" }

if (-not $ResultsDir) {
    $ResultsDir = Join-Path $PSScriptRoot "../../results/runs/$envName/$runId"
}
if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}
$ResultsDir = (Resolve-Path $ResultsDir).Path

Write-Host "==> environment:        $envName"
Write-Host "==> manager:            $managerInstanceId ($managerPublicDns / $managerPrivateIp)"
Write-Host "==> clusters:           $($clusterInstanceIds.Count)"
Write-Host "==> drivers:            $($driverInstanceIds.Count)"
Write-Host "==> image:              $BenchmarkImage"
Write-Host "==> orchestrator URL:   http://${managerPublicDns}:${orchHttpPort}"
Write-Host "==> results dir:        $ResultsDir"

function Invoke-Ssm {
    param(
        [Parameter(Mandatory)] [string]   $InstanceId,
        [Parameter(Mandatory)] [string[]] $Commands,
        [string] $Comment = ""
    )
    $cmdJson = ($Commands | ConvertTo-Json -Compress)
    $resp = aws ssm send-command `
        --region $region `
        --instance-ids $InstanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$cmdJson" `
        --comment $Comment `
        --output json
    if ($LASTEXITCODE -ne 0) { throw "ssm send-command failed for $InstanceId" }
    $cmdId = ($resp | ConvertFrom-Json).Command.CommandId
    return $cmdId
}

function Wait-Ssm {
    param(
        [Parameter(Mandatory)] [string] $CommandId,
        [Parameter(Mandatory)] [string] $InstanceId,
        [int] $TimeoutSec = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = aws ssm get-command-invocation --region $region --command-id $CommandId --instance-id $InstanceId --output json 2>$null | ConvertFrom-Json
        if ($r -and $r.Status -in @('Success','Failed','Cancelled','TimedOut')) {
            return $r
        }
        Start-Sleep -Seconds 3
    }
    throw "SSM command $CommandId on $InstanceId timed out after ${TimeoutSec}s"
}

# ── 1. Pull image on every node + start support containers ───────────────────
$startSupport = @"
set -euo pipefail
docker pull $BenchmarkImage
"@

Write-Host "==> pulling image on all nodes"
$pullCmds = @{}
foreach ($id in @($managerInstanceId) + $clusterInstanceIds + $driverInstanceIds + @($spacetimeInstanceId, $redisInstanceId)) {
    if (-not $id) { continue }
    $pullCmds[$id] = Invoke-Ssm -InstanceId $id -Commands @($startSupport) -Comment "docker pull $BenchmarkImage"
}
foreach ($id in $pullCmds.Keys) { Wait-Ssm -CommandId $pullCmds[$id] -InstanceId $id -TimeoutSec 600 | Out-Null }

# ── 2. Start Redis + SpacetimeDB + publish module ────────────────────────────
Write-Host "==> starting Redis"
$redisStart = @"
set -euo pipefail
docker rm -f bench-redis 2>/dev/null || true
docker run -d --name bench-redis --restart unless-stopped --network host redis:7-alpine redis-server --appendonly yes
"@
Wait-Ssm -CommandId (Invoke-Ssm -InstanceId $redisInstanceId -Commands @($redisStart) -Comment "redis") -InstanceId $redisInstanceId | Out-Null

Write-Host "==> starting SpacetimeDB + publishing module"
$stStart = @"
set -euo pipefail
docker rm -f bench-spacetime 2>/dev/null || true
docker run -d --name bench-spacetime --restart unless-stopped --network host $BenchmarkImage spacetime start
for i in {1..60}; do bash -c 'echo > /dev/tcp/127.0.0.1/3000' 2>/dev/null && break; sleep 2; done
docker run --rm --network host $BenchmarkImage benchmark-publish-module --mode Persist --host http://127.0.0.1:3000
"@
Wait-Ssm -CommandId (Invoke-Ssm -InstanceId $spacetimeInstanceId -Commands @($stStart) -Comment "spacetime+publish") -InstanceId $spacetimeInstanceId -TimeoutSec 600 | Out-Null

# ── 3. Start cluster fleet ───────────────────────────────────────────────────
$redisHost     = (aws ec2 describe-instances --region $region --instance-ids $redisInstanceId --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>$null)
$spacetimeHost = (aws ec2 describe-instances --region $region --instance-ids $spacetimeInstanceId --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>$null)

Write-Host "==> starting clusters (Redis=$redisHost, SpacetimeDB=$spacetimeHost)"
for ($i = 0; $i -lt $clusterInstanceIds.Count; $i++) {
    $cid     = $clusterInstanceIds[$i]
    $cuid    = $clusterIds[$i]
    $clusPort = 8090
    $clStart = @"
set -euo pipefail
docker rm -f bench-cluster 2>/dev/null || true
docker run -d --name bench-cluster --restart unless-stopped --network host \
  -e CLUSTER_ID=$cuid \
  -e REDIS_URL=redis://${redisHost}:6379 \
  -e CLUSTER_WS_PORT=$clusPort \
  -e SPACETIMEDB_URI=http://${spacetimeHost}:3000 \
  -e SPACETIMEDB_DATABASE=arcane \
  -e SPACETIMEDB_PERSIST=1 \
  -e SPACETIMEDB_PERSIST_HZ=1 \
  $BenchmarkImage benchmark-cluster
"@
    $cmdId = Invoke-Ssm -InstanceId $cid -Commands @($clStart) -Comment "cluster $i"
    Wait-Ssm -CommandId $cmdId -InstanceId $cid | Out-Null
}

# ── 4. Start manager + orchestrator on the manager EC2 ───────────────────────
Write-Host "==> starting manager + orchestrator on $managerInstanceId"

# Build MANAGER_CLUSTERS string (uuid:host:port) for arcane-manager.
$managerClusters = @()
for ($i = 0; $i -lt $clusterIds.Count; $i++) {
    $managerClusters += ("{0}:{1}:8090" -f $clusterIds[$i], $clusterPrivateIps[$i])
}
$managerClustersStr = ($managerClusters -join ',')
# Stats URL list for the orchestrator.
$statsUrls = @($clusterPrivateIps | ForEach-Object { "http://${_}:8091/stats" })
$statsArgs = ($statsUrls | ForEach-Object { "--cluster-stats-url $_" }) -join ' '

$mgrStart = @"
set -euo pipefail
docker rm -f bench-manager bench-orchestrator 2>/dev/null || true

docker run -d --name bench-manager --restart unless-stopped --network host \
  -e MANAGER_HTTP_PORT=8081 \
  -e MANAGER_CLUSTERS='$managerClustersStr' \
  $BenchmarkImage arcane-manager

mkdir -p /var/orchestrator
docker run -d --name bench-orchestrator --restart unless-stopped --network host \
  -v /var/orchestrator:/var/orchestrator \
  $BenchmarkImage arcane-swarm-orchestrator \
    --driver-port $orchDriverPort \
    --http-port $orchHttpPort \
    --archive-dir /var/orchestrator/snapshots \
    --max-drivers 32 \
    $statsArgs
"@
Wait-Ssm -CommandId (Invoke-Ssm -InstanceId $managerInstanceId -Commands @($mgrStart) -Comment "manager+orchestrator") -InstanceId $managerInstanceId | Out-Null

# ── 5. Start drivers in orchestrated mode ────────────────────────────────────
Write-Host "==> starting $($driverInstanceIds.Count) drivers in orchestrated mode"
$orchUrlInternal = "ws://${managerPrivateIp}:${orchDriverPort}"
foreach ($did in $driverInstanceIds) {
    $drvStart = @"
set -euo pipefail
docker rm -f bench-driver 2>/dev/null || true
docker run -d --name bench-driver --restart unless-stopped --network host \
  -e ORCHESTRATOR_URL=$orchUrlInternal \
  $BenchmarkImage arcane-swarm \
    --backend arcane \
    --arcane-manager http://${managerPrivateIp}:8081 \
    --orchestrator-url $orchUrlInternal \
    --tick-rate 60 \
    --max-players 4000 \
    --user-data-bytes 1000 \
    --inter-spawn-delay-ms 8 \
    --max-players-per-driver 4000 \
    --burst-enabled --burst-period-secs 30 --burst-cohort-percent 20 \
    --burst-actions-per-player 10 --burst-window-ms 500 \
    --zone-event-period-secs 30 --zone-event-window-ms 500 \
    --actions-per-sec 2 --read-rate 5 \
    --run-forever
"@
    Wait-Ssm -CommandId (Invoke-Ssm -InstanceId $did -Commands @($drvStart) -Comment "driver") -InstanceId $did | Out-Null
}

# Give drivers a moment to register with the orchestrator.
Start-Sleep -Seconds 8

# ── 6. Run the controller from the operator's laptop ─────────────────────────
$orchUrlPublic = "http://${managerPublicDns}:${orchHttpPort}"
Write-Host "==> running controller against $orchUrlPublic"

$ctlArgs = @(
    '--plan',             $PlanFile,
    '--orchestrator-url', $orchUrlPublic,
    '--results-dir',      $ResultsDir,
    '--submitter',        "operator-$env:USERNAME"
)
if ($S3UploadResults) {
    $ctlArgs += '--s3-bucket', $bucket
    $ctlArgs += '--s3-prefix', "${prefix}/${envName}/${runId}/"
}

& $ControllerBinary @ctlArgs
$ctlExit = $LASTEXITCODE

# ── 7. Stop driver + orchestrator + cluster + support containers ─────────────
Write-Host "==> stopping all containers"
$stopAll = "docker rm -f bench-driver bench-orchestrator bench-manager bench-cluster bench-spacetime bench-redis 2>/dev/null || true"
$allInstances = @($managerInstanceId) + $clusterInstanceIds + $driverInstanceIds + @($spacetimeInstanceId, $redisInstanceId) | Where-Object { $_ }
foreach ($id in $allInstances) {
    $null = Invoke-Ssm -InstanceId $id -Commands @($stopAll) -Comment "stop"
}

Write-Host ""
if ($ctlExit -eq 0) {
    Write-Host "==> controller exited 0 (overall PASS)" -ForegroundColor Green
} else {
    Write-Host "==> controller exited $ctlExit (overall FAIL or error)" -ForegroundColor Red
}
exit $ctlExit
