# Run clone + deps + build + Run-Benchmark.ps1 on the instance via SSM, then sync results to S3.
# Requires: Common/AwsHelpers.ps1 dot-sourced by the caller.

function Invoke-SingleInstanceAwsRemoteBenchmark {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$ArtifactBucket,
    [string]$ArtifactPrefix = 'benchmark-aws',
    [Parameter(Mandatory)][string]$RepoUrl,
    [Parameter(Mandatory)][string]$Branch,
    [string]$BenchmarkPwshArgs = '',
    [string]$GithubTokenB64 = ''
  )

  if ($State.Environment -ne 'SingleInstance') {
    throw "Invoke-SingleInstanceAwsRemoteBenchmark: state Environment must be SingleInstance (got '$($State.Environment)')."
  }

  $Region = $State.Region
  $instanceId = $State.InstanceId
  $remoteRoot = $State.RemoteRoot
  $envSeg = $State.Environment
  if ([string]::IsNullOrWhiteSpace($envSeg)) { $envSeg = 'SingleInstance' }
  # Same layout as local default: <repo>/results/runs/<Environment>/<RunId>/
  $remoteOutDir = "$remoteRoot/results/runs/$envSeg/$RunId"
  $s3Dest = "s3://$ArtifactBucket/$ArtifactPrefix/$envSeg/$RunId/"

  $benchB64 = ''
  if (-not [string]::IsNullOrWhiteSpace($BenchmarkPwshArgs)) {
    $benchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BenchmarkPwshArgs.Trim()))
  }

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
GITHUB_TOKEN_B64="__GITHUB_TOKEN_B64__"

until docker info >/dev/null 2>&1 && command -v pwsh >/dev/null 2>&1 && command -v spacetime >/dev/null 2>&1; do
  echo "waiting for user-data..."
  sleep 10
done

echo "=== Clone repository (shared deps script + source) ==="
mkdir -p "$(dirname "$REMOTE_ROOT")"
if [ ! -d "$REMOTE_ROOT/.git" ]; then
  git clone "$REPO_URL" "$REMOTE_ROOT"
fi
cd "$REMOTE_ROOT"
git fetch origin
if ! git checkout "$BRANCH"; then
  git checkout master || git checkout main
fi
git pull --ff-only || git pull

echo "=== Fail-fast: Redis + SpacetimeDB (same as local: scripts/start-benchmark-deps.sh) ==="
bash "$REMOTE_ROOT/scripts/start-benchmark-deps.sh"

echo "=== Toolchain + submodules + builds ==="
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
(cd arcane && cargo build -p arcane-infra --bin arcane-manager --features manager --release)
(cd arcane && cargo build -p arcane-infra --bin arcane-cluster --features cluster-ws --release)

(cd spacetimedb_demo/spacetimedb && spacetime build && spacetime publish arcane --yes --anonymous -s http://127.0.0.1:3000)

mkdir -p "$REMOTE_OUT"
set +e
if [ -n "$BENCH_B64" ]; then
  EXTRA=$(printf '%s' "$BENCH_B64" | base64 -d)
  pwsh -NoProfile -Command "& \"$REMOTE_ROOT/scripts/Run-Benchmark.ps1\" -OutDir \"$REMOTE_OUT\" $EXTRA"
else
  pwsh -NoProfile -File "$REMOTE_ROOT/scripts/Run-Benchmark.ps1" -OutDir "$REMOTE_OUT"
fi
EC=$?
set -e

aws s3 sync "$REMOTE_OUT" "$S3_DEST" --region "$AWS_REGION"
echo "Benchmark exit code: $EC"
exit $EC
'@

  $ghB64 = if ([string]::IsNullOrWhiteSpace($GithubTokenB64)) { '' } else { $GithubTokenB64.Trim() }

  $remoteBash = $remoteTpl.Replace('__REPO__', (Escape-BashDoubleQuoted $RepoUrl)).
    Replace('__BRANCH__', (Escape-BashDoubleQuoted $Branch)).
    Replace('__ROOT__', (Escape-BashDoubleQuoted $remoteRoot)).
    Replace('__OUT__', (Escape-BashDoubleQuoted $remoteOutDir)).
    Replace('__S3__', (Escape-BashDoubleQuoted $s3Dest)).
    Replace('__REGION__', (Escape-BashDoubleQuoted $Region)).
    Replace('__BENCH_B64__', $benchB64).
    Replace('__GITHUB_TOKEN_B64__', $ghB64)
  $remoteBash = $remoteBash -replace "`r`n", "`n"

  $paramsPath = Join-Path $env:TEMP "arcane-ssm-params-$RunId.json"
  # AWS-RunShellScript defaults to executionTimeout 3600000 ms (1 h); full benchmark + cold build needs longer.
  $paramObj = @{
    commands           = @($remoteBash)
    executionTimeout   = @('28800000')
  }
  $jsonParams = $paramObj | ConvertTo-Json -Depth 10 -Compress
  [System.IO.File]::WriteAllText($paramsPath, $jsonParams, [System.Text.UTF8Encoding]::new($false))

  $fileUri = Get-AwsCliFileUri $paramsPath

  Write-Host 'Sending SSM run command...' -ForegroundColor Cyan
  $sendRaw = aws ssm send-command --region $Region `
    --instance-ids $instanceId `
    --document-name 'AWS-RunShellScript' `
    --comment "Arcane benchmark $RunId" `
    --timeout-seconds 28800 `
    --parameters "$fileUri" `
    --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $paramsPath -Force -ErrorAction SilentlyContinue
    throw "send-command failed: $sendRaw"
  }
  $sendOut = $sendRaw | ConvertFrom-Json

  $cmdId = $sendOut.Command.CommandId
  Remove-Item -LiteralPath $paramsPath -Force -ErrorAction SilentlyContinue

  if ([string]::IsNullOrWhiteSpace($cmdId)) { throw 'send-command returned no CommandId' }

  Write-Host "CommandId=$cmdId (waiting)..." -ForegroundColor Cyan
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

  Write-Host "Staged to S3 (orchestrator downloads to local results dir): $s3Dest" -ForegroundColor Green

  [pscustomobject]@{
    Invocation = $inv
    S3Dest     = $s3Dest
    RunId      = $RunId
  }
}
