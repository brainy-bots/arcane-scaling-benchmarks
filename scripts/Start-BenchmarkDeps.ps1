<#
.SYNOPSIS
  Start Redis + SpacetimeDB in Docker on 127.0.0.1 (same containers/ports as start-benchmark-deps.sh / EC2).

.DESCRIPTION
  Use this on Windows before Run-Benchmark.ps1 when you want parity with the cloud path (Docker for both
  services). Requires Docker Desktop (or Docker Engine) on PATH.

  Optional environment variables: SPACETIME_IMAGE, REDIS_CONTAINER, SPACETIME_CONTAINER — same as the shell script.
#>
$ErrorActionPreference = 'Stop'

function Test-TcpPortOpen {
  param([string]$ComputerName, [int]$Port)
  $c = $null
  try {
    $c = [System.Net.Sockets.TcpClient]::new()
    $c.ReceiveTimeout = 2000
    $c.SendTimeout = 2000
    $c.Connect($ComputerName, $Port)
    return $true
  } catch { return $false } finally { if ($null -ne $c) { $c.Dispose() } }
}

$ScriptDir = $PSScriptRoot

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'docker not on PATH. Install Docker Desktop or run start-benchmark-deps.sh from Git Bash/WSL.'
}

$gitBash = @(
  'C:\Program Files\Git\bin\bash.exe',
  'C:\Program Files (x86)\Git\bin\bash.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($gitBash) {
  $exports = @()
  if ($env:SPACETIME_IMAGE) { $exports += "export SPACETIME_IMAGE=`"$($env:SPACETIME_IMAGE -replace '"','\"')`"" }
  if ($env:REDIS_CONTAINER) { $exports += "export REDIS_CONTAINER=`"$($env:REDIS_CONTAINER -replace '"','\"')`"" }
  if ($env:SPACETIME_CONTAINER) { $exports += "export SPACETIME_CONTAINER=`"$($env:SPACETIME_CONTAINER -replace '"','\"')`"" }
  $exportLine = ($exports -join '; ')
  $bashDir = ($ScriptDir -replace '\\', '/')
  if ($exportLine) {
    & $gitBash -lc "$exportLine; cd `"$bashDir`" && bash ./start-benchmark-deps.sh"
  } else {
    & $gitBash -lc "cd `"$bashDir`" && bash ./start-benchmark-deps.sh"
  }
  if ($LASTEXITCODE -ne 0) { throw "start-benchmark-deps.sh failed (exit $LASTEXITCODE)" }
  return
}

$redisName = if ($env:REDIS_CONTAINER) { $env:REDIS_CONTAINER } else { 'arcane-bench-redis' }
$stName = if ($env:SPACETIME_CONTAINER) { $env:SPACETIME_CONTAINER } else { 'arcane-bench-spacetime' }
$stImage = if ($env:SPACETIME_IMAGE) { $env:SPACETIME_IMAGE } else { 'clockworklabs/spacetime:latest' }

Write-Host '=== Benchmark deps: Redis (Docker) on 127.0.0.1:6379 ===' -ForegroundColor Cyan
# docker rm prints to stderr when the container is missing; do not fail the script
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
docker rm -f $redisName 2>&1 | Out-Null
$ErrorActionPreference = $prevEap
& docker run -d --name $redisName -p 127.0.0.1:6379:6379 redis:7-alpine redis-server --appendonly yes
if ($LASTEXITCODE -ne 0) { throw 'docker run redis failed' }

$redisOk = $false
for ($i = 0; $i -lt 60; $i++) {
  $pong = docker exec $redisName redis-cli ping 2>$null
  if ($pong -match 'PONG') { $redisOk = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $redisOk) {
  docker logs $redisName 2>&1 | Write-Host
  throw 'Redis did not respond to PING in time.'
}

Write-Host "=== Benchmark deps: SpacetimeDB (Docker) on 127.0.0.1:3000 image=$stImage ===" -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
docker rm -f $stName 2>&1 | Out-Null
$ErrorActionPreference = $prevEap
& docker pull $stImage
if ($LASTEXITCODE -ne 0) { throw "docker pull $stImage failed" }
& docker run -d --name $stName -p 127.0.0.1:3000:3000 $stImage start
if ($LASTEXITCODE -ne 0) { throw 'docker run spacetime failed' }

$stOk = $false
for ($i = 0; $i -lt 120; $i++) {
  if (Test-TcpPortOpen -ComputerName '127.0.0.1' -Port 3000) { $stOk = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $stOk) {
  docker logs $stName 2>&1 | Write-Host
  throw 'SpacetimeDB did not accept TCP on 127.0.0.1:3000 in time.'
}

Write-Host '=== Redis + SpacetimeDB ready (same recipe as cloud benchmark) ===' -ForegroundColor Green
