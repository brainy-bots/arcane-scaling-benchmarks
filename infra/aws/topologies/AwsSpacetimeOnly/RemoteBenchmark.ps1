# AwsSpacetimeOnly driver. Pulls the pre-built benchmark image on the SpacetimeDB
# node and the driver node; runs the image with different role commands. No
# cargo, git clone, or `spacetime publish` happens on EC2.
#
# Requires: lib/AwsHelpers.ps1 dot-sourced by the caller.

function Invoke-AwsSpacetimeOnlyRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$ArtifactBucket,
    [string]$ArtifactPrefix = 'benchmark-aws',
    [Parameter(Mandatory)][string]$BenchmarkImage,
    [string]$ContainerConfigPath = '/opt/benchmark/configs/spacetimedb_only.json',
    [int]$SsmDriverBenchmarkTimeoutSeconds = 28800
  )

  if ($State.Environment -ne 'AwsSpacetimeOnly') {
    throw "Invoke-AwsSpacetimeOnlyRemoteBenchmark: state Environment must be AwsSpacetimeOnly (got '$($State.Environment)')."
  }
  if ([string]::IsNullOrWhiteSpace($BenchmarkImage)) {
    throw 'BenchmarkImage is required (e.g. ghcr.io/brainy-bots/arcane-benchmark:v0.1.0). No pulls happen at runtime without a pinned tag.'
  }

  $Region = $State.Region
  $spacetimeId = $State.SpacetimeInstanceId
  $benchId = $State.BenchmarkInstanceId
  $envSeg = 'AwsSpacetimeOnly'
  $s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/"

  $stIp = Get-Ec2PrivateIp -Region $Region -InstanceId $spacetimeId
  Write-Host "Private IPs: SpacetimeDB=$stIp (driver=$benchId). Image=$BenchmarkImage" -ForegroundColor DarkGray

  # ── 1. Spacetime node: start SpacetimeDB container and publish the Full module ─
  $stTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"

# Docker ready?
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done

docker pull "$IMG"

# SpacetimeDB server container
docker rm -f arcane-bench-spacetime 2>/dev/null || true
docker run -d --name arcane-bench-spacetime --ulimit nofile=65536:65536 -p 0.0.0.0:3000:3000 "$IMG" spacetime start

# Wait for port 3000
for i in $(seq 1 120); do bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null || { echo "ERROR: SpacetimeDB not listening on 3000"; exit 1; }

# Publish the Full benchmark module into the running SpacetimeDB.
docker run --rm --network host "$IMG" benchmark-publish-module \
  --mode Full --host http://127.0.0.1:3000
'@
  $stScript = $stTpl.Replace('__IMG__', (Escape-BashDoubleQuoted $BenchmarkImage))
  $stScript = $stScript -replace "`r`n", "`n"

  $cidS = Send-SsmRunShellScript -Region $Region -InstanceId $spacetimeId -ScriptBody $stScript `
    -Comment "Arcane bench spacetime (st-only) $RunId" -TimeoutSeconds 3600
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $spacetimeId -CommandId $cidS -Label 'SpacetimeDB' `
    -PollSeconds 5 -ThrowOnFailure

  # ── 2. Driver node: pull image, run sweep, upload results to S3 ────────────
  $drvTpl = @'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
IMG="__IMG__"
ST_IP="__ST_IP__"
CONFIG_PATH="__CONFIG_PATH__"
S3_DEST="__S3__"
AWS_REGION="__REGION__"

# Docker + AWS CLI ready?
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && command -v aws >/dev/null 2>&1 && break; sleep 5; done

# Verify reachability to SpacetimeDB over VPC.
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null \
  || { echo "ERROR: cannot reach SpacetimeDB at $ST_IP:3000"; exit 1; }

docker pull "$IMG"

OUT_DIR="/var/arcane-benchmark-out"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"

docker run --rm \
  --ulimit nofile=65536:65536 \
  -v "$OUT_DIR:/var/benchmark/out" \
  "$IMG" run-benchmark \
    --config "$CONFIG_PATH" \
    --spacetime-host "http://${ST_IP}:3000" \
    --environment AwsSpacetimeOnly
EC=$?

aws s3 sync "$OUT_DIR" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@
  $drvScript = $drvTpl.
    Replace('__IMG__',         (Escape-BashDoubleQuoted $BenchmarkImage)).
    Replace('__ST_IP__',       (Escape-BashDoubleQuoted $stIp)).
    Replace('__CONFIG_PATH__', (Escape-BashDoubleQuoted $ContainerConfigPath)).
    Replace('__S3__',          (Escape-BashDoubleQuoted $s3Dest)).
    Replace('__REGION__',      (Escape-BashDoubleQuoted $Region))
  $drvScript = $drvScript -replace "`r`n", "`n"

  Write-Host 'Sending driver SSM run command...' -ForegroundColor Cyan
  $cmdId = Send-SsmRunShellScript -Region $Region -InstanceId $benchId -ScriptBody $drvScript `
    -Comment "Arcane AWS AwsSpacetimeOnly benchmark $RunId" -TimeoutSeconds $SsmDriverBenchmarkTimeoutSeconds

  $inv = Wait-SsmCommandInvocation -Region $Region -InstanceId $benchId -CommandId $cmdId -Label 'Driver SSM' -PollSeconds 10
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
