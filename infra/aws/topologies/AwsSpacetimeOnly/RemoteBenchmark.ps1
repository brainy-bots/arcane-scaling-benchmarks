# SpacetimeDB on a dedicated instance; driver builds swarm, publishes module, runs SpacetimeOnly benchmark.
# Requires: lib/AwsHelpers.ps1 dot-sourced by the caller.

function Invoke-AwsSpacetimeOnlyRemoteBenchmark {
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
    [string]$RemoteProvisionProfile = 'Full',
    [int]$SsmDriverBenchmarkTimeoutSeconds = 28800
  )

  if ($State.Environment -ne 'AwsSpacetimeOnly') {
    throw "Invoke-AwsSpacetimeOnlyRemoteBenchmark: state Environment must be AwsSpacetimeOnly (got '$($State.Environment)')."
  }

  $Region = $State.Region
  $spacetimeId = $State.SpacetimeInstanceId
  $benchId = $State.BenchmarkInstanceId
  $remoteRoot = $State.RemoteRoot
  $envSeg = 'AwsSpacetimeOnly'
  $remoteOutDir = "$remoteRoot/results/runs/$envSeg/$RunId"
  $s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/"

  $stIp = Get-Ec2PrivateIp -Region $Region -InstanceId $spacetimeId
  Write-Host "Private IPs: SpacetimeDB=$stIp (driver=$benchId)" -ForegroundColor DarkGray

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

  $cidS = Send-SsmRunShellScript -Region $Region -InstanceId $spacetimeId -ScriptBody $stScript `
    -Comment "Arcane bench spacetime (st-only) $RunId" -TimeoutSeconds 3600
  $null = Wait-SsmCommandInvocation -Region $Region -InstanceId $spacetimeId -CommandId $cidS -Label 'SpacetimeDB' `
    -PollSeconds 5 -ThrowOnFailure

  $benchB64 = ''
  if (-not [string]::IsNullOrWhiteSpace($BenchmarkPwshArgs)) {
    $benchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BenchmarkPwshArgs.Trim()))
  }
  $ghB64 = if ([string]::IsNullOrWhiteSpace($GithubTokenB64)) { '' } else { $GithubTokenB64.Trim() }

  $driverCheck = @'
echo "=== Verify reachability to SpacetimeDB over VPC ==="
for i in $(seq 1 60); do bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null && break; sleep 2; done
bash -c "echo >/dev/tcp/$ST_IP/3000" 2>/dev/null || { echo "ERROR: cannot reach SpacetimeDB at $ST_IP:3000"; exit 1; }
'@

  $remoteTpl = @'
#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
export REPO_URL="__REPO__"
export BRANCH="__BRANCH__"
export REMOTE_ROOT="__ROOT__"
export REMOTE_OUT="__OUT__"
export S3_DEST="__S3__"
export AWS_REGION="__REGION__"
export BENCH_B64="__BENCH_B64__"
export ST_IP="__ST_IP__"
GITHUB_TOKEN_B64="__GITHUB_TOKEN_B64__"

until command -v pwsh >/dev/null 2>&1 && command -v spacetime >/dev/null 2>&1; do
  echo "waiting for user-data (driver)..."
  sleep 10
done

__DRIVER_ST_CHECK__

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

echo "=== Toolchain + submodules + swarm build ==="
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

(cd arcane_swarm && cargo build -p arcane-swarm --bin arcane-swarm --release)

ST_URL="http://${ST_IP}:3000"
(cd spacetimedb_demo/spacetimedb && spacetime build && spacetime publish arcane --yes --anonymous -s "$ST_URL")

mkdir -p "$REMOTE_OUT"
set +e
if [ -n "$BENCH_B64" ]; then
  EXTRA=$(printf '%s' "$BENCH_B64" | base64 -d)
  pwsh -NoProfile -Command "& \"${REMOTE_ROOT}/scripts/Run-Benchmark.ps1\" -OutDir \"${REMOTE_OUT}\" -SpacetimeHost \"${ST_URL}\" -Environment AwsSpacetimeOnly -BenchmarkMode SpacetimeOnly ${EXTRA}"
else
  pwsh -NoProfile -Command "& \"${REMOTE_ROOT}/scripts/Run-Benchmark.ps1\" -OutDir \"${REMOTE_OUT}\" -SpacetimeHost \"${ST_URL}\" -Environment AwsSpacetimeOnly -BenchmarkMode SpacetimeOnly"
fi
EC=$?
set -e

aws s3 sync "$REMOTE_OUT" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@

  $remoteBash = $remoteTpl.
    Replace('__REPO__', (Escape-BashDoubleQuoted $RepoUrl)).
    Replace('__BRANCH__', (Escape-BashDoubleQuoted $Branch)).
    Replace('__ROOT__', (Escape-BashDoubleQuoted $remoteRoot)).
    Replace('__OUT__', (Escape-BashDoubleQuoted $remoteOutDir)).
    Replace('__S3__', (Escape-BashDoubleQuoted $s3Dest)).
    Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
    Replace('__BENCH_B64__', $benchB64).
    Replace('__DRIVER_ST_CHECK__', $driverCheck.TrimEnd()).
    Replace('__ST_IP__', (Escape-BashDoubleQuoted $stIp)).
    Replace('__GITHUB_TOKEN_B64__', $ghB64)
  $remoteBash = $remoteBash -replace "`r`n", "`n"

  Write-Host 'Sending driver SSM run command (long)...' -ForegroundColor Cyan
  $cmdId = Send-SsmRunShellScript -Region $Region -InstanceId $benchId -ScriptBody $remoteBash `
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
