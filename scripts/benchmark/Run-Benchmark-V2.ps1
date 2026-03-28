<#
.SYNOPSIS
  Run benchmark v2 (containerized, resource-limited) and write ceiling CSV.

.DESCRIPTION
  Uses docker compose for core services and launches Arcane cluster containers dynamically.
  This is a new benchmark profile (v2), not directly comparable to legacy/native numbers.
#>
param(
  [int]$StartPlayers = 250,
  [int]$StepPlayers = 250,
  [int]$MaxPlayers = 6000,
  [int]$DurationSeconds = 30,
  [double]$MaxErrRate = 0.01,
  [double]$MaxLatencyMs = 200,
  [int[]]$ArcaneClusterCounts = @(1,2,3,4,5,10),
  [string]$DatabaseName = 'arcane',
  [string]$SpacetimeHost = 'http://127.0.0.1:3000',
  [string]$OutDir = '',
  # When set, skip `docker compose build` and use existing local tags (e.g. arcane-v2/infra:latest from GHCR on EC2).
  [switch]$SkipImageBuild,
  # Default is physics ON (game-server-like behavior). Set this switch only for synthetic/network-only profiling.
  [switch]$NoServerPhysics
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..\..')
$parsingModule = Join-Path $RepoRoot 'scripts\common\BenchmarkParsing.psm1'
$scenarioModule = Join-Path $RepoRoot 'scripts\common\BenchmarkScenario.psm1'
$runtimeModule = Join-Path $RepoRoot 'scripts\common\BenchmarkRuntime.psm1'
Import-Module $parsingModule -Force
Import-Module $scenarioModule -Force
Import-Module $runtimeModule -Force
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $ScriptDir ('v2_runs_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$null = New-Item -ItemType Directory -Path $OutDir -Force
$compose = Join-Path $RepoRoot 'docker-compose.v2.yml'
$modulePath = Join-Path $RepoRoot 'spacetimedb_demo\spacetimedb'
$envFile = Join-Path $OutDir '.env.v2'
$metricsDir = Join-Path $OutDir 'metrics'
$logsDir = Join-Path $OutDir 'logs'
$null = New-Item -ItemType Directory -Path $metricsDir -Force
$null = New-Item -ItemType Directory -Path $logsDir -Force

function Remove-DockerContainerIfPresent([string]$Name) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try { docker rm -f $Name 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
}

function Invoke-Compose([string]$ComposeArgs) {
  $prefix = @('compose', '-f', $compose, '--env-file', $envFile)
  $extra = @($ComposeArgs.Trim() -split '\s+')
  & docker @prefix @extra
  if ($LASTEXITCODE -ne 0) { throw "docker compose failed: $ComposeArgs" }
}

function Invoke-SwarmV2Run {
  param(
    [Parameter(Mandatory)][ValidateSet('spacetimedb', 'arcane')][string]$Backend,
    [Parameter(Mandatory)][int]$Players,
    [Parameter(Mandatory)][int]$DurationSeconds,
    [Parameter(Mandatory)][string]$DatabaseName,
    [string]$ServerPhysicsArg = ''
  )
  $args = @(
    'compose', '-f', $compose, '--env-file', $envFile,
    'run', '--rm', '--no-deps', '--entrypoint', 'arcane-swarm', 'swarm',
    '--backend', $Backend
  )
  if (-not [string]::IsNullOrWhiteSpace($ServerPhysicsArg)) { $args += $ServerPhysicsArg }
  $args += @(
    '--players', "$Players",
    '--tick-rate', '10',
    '--aps', '2',
    '--read-rate', '5',
    '--mode', 'spread',
    '--duration', "$DurationSeconds"
  )
  if ($Backend -eq 'arcane') { $args += @('--arcane-manager', 'http://manager:8081') }
  $args += @('--uri', 'http://host.docker.internal:3000', '--db', $DatabaseName)
  & docker @args 2>&1
}

function Write-EnvForManager([string]$ManagerClusters) {
  New-ManagerEnvLines -ManagerClusters $ManagerClusters | Set-Content $envFile
}

function Start-ClusterContainers([string[]]$Ids, [int]$NumServers) {
  $names = @()
  for($i=0; $i -lt $NumServers; $i++) {
    $name = "arcane-v2-cluster-$i"
    $neighbors = @()
    for($j=0; $j -lt $NumServers; $j++) {
      if ($j -ne $i) { $neighbors += $Ids[$j] }
    }
    $neighborStr = ($neighbors -join ',')
    docker rm -f $name 2>$null | Out-Null
    & docker run -d --name $name --network arcane-v2-net --cpus 1 --memory 2g `
      -e "CLUSTER_ID=$($Ids[$i])" -e "CLUSTER_WS_PORT=$([int](8090+$i))" -e 'REDIS_URL=redis://redis:6379' `
      -e "NEIGHBOR_IDS=$neighborStr" arcane-v2/infra:latest arcane-cluster
    if ($LASTEXITCODE -ne 0) { throw "failed to start cluster container $name" }
    $names += $name
  }
  return $names
}

function Stop-ClusterContainers([string[]]$Names) {
  foreach($n in $Names) {
    Remove-DockerContainerIfPresent -Name $n
  }
}

function Write-StatsSnapshot([string]$ScenarioTag, [int]$Players, [int]$NumServers) {
  $outPath = Join-Path $metricsDir "docker_stats.csv"
  $rows = Get-DockerStatsRows
  Write-DockerStatsCsv -OutPath $outPath -ScenarioTag $ScenarioTag -Players $Players -NumServers $NumServers -Rows $rows
}

function Export-ScenarioLogs([string]$ScenarioTag, [string[]]$ClusterNames) {
  $base = Get-LogContainerNames -ClusterNames $ClusterNames
  foreach($c in $base) {
    $p = Join-Path $logsDir ("$ScenarioTag`_$c.log")
    docker logs $c 2>&1 | Set-Content $p
  }
}

try {
  $serverPhysicsArg = if ($NoServerPhysics) { '' } else { '--server-physics' }

  $spOk = (Test-NetConnection -ComputerName 127.0.0.1 -Port 3000 -WarningAction SilentlyContinue).TcpTestSucceeded
  if (-not $spOk) { throw "SpacetimeDB host service not reachable on 127.0.0.1:3000. Start it before running v2." }

  # initial env + images (build locally, or use pre-tagged images e.g. after docker pull on cloud)
  Write-EnvForManager ''
  if ($SkipImageBuild) {
    Write-Host 'SkipImageBuild: using existing arcane-v2/infra:latest and arcane-v2/swarm:latest' -ForegroundColor Yellow
  } else {
    Invoke-Compose 'build manager swarm'
  }

  # Spacetime-only infra
  Invoke-Compose 'up -d redis'

  # publish module from host CLI to host SpacetimeDB
  Push-Location $modulePath
  try {
    & spacetime build
    if ($LASTEXITCODE -ne 0) { throw 'spacetime build failed' }
    & spacetime publish $DatabaseName --yes
    if ($LASTEXITCODE -ne 0) { throw 'spacetime publish failed' }
  } finally { Pop-Location }

  $results = @()

  # SpacetimeDB-only ceiling
  $ceil = $null
  for($p=$StartPlayers; $p -le $MaxPlayers; $p += $StepPlayers){
    Write-Host "[v2 spacetimedb] players=$p" -ForegroundColor Gray
    $out = Invoke-SwarmV2Run -Backend spacetimedb -Players $p -DurationSeconds $DurationSeconds -DatabaseName $DatabaseName -ServerPhysicsArg $serverPhysicsArg
    ($out | Out-String) | Set-Content (Join-Path $logsDir ("spacetimedb_only_swarm_players_$p.log"))
    $parsed = Get-SwarmFinal ($out | Out-String)
    Write-StatsSnapshot -ScenarioTag 'spacetimedb_only' -Players $p -NumServers 0
    if (Test-BenchmarkPass -ParsedFinal $parsed -MaxErrRate $MaxErrRate -MaxLatencyMs $MaxLatencyMs) { $ceil = $p } else { break }
  }
  Export-ScenarioLogs -ScenarioTag 'spacetimedb_only' -ClusterNames @()
  $results += [PSCustomObject]@{ backend='spacetimedb_only'; num_servers=0; ceiling_players=$ceil }

  foreach($n in $ArcaneClusterCounts) {
    Write-Host "Running Arcane+Spacetime v2 for clusters=$n" -ForegroundColor Cyan
    $cfg = New-ClusterConfig -ClusterCount $n
    Write-EnvForManager $cfg.ManagerClusters

    Invoke-Compose 'down --remove-orphans'
    Invoke-Compose 'up -d redis manager'

    $clusterNames = Start-ClusterContainers -Ids $cfg.Ids -NumServers $n

    $ceilA = $null
    for($p=$StartPlayers; $p -le $MaxPlayers; $p += $StepPlayers){
      Write-Host "[v2 arcane n=$n] players=$p" -ForegroundColor Gray
      $out = Invoke-SwarmV2Run -Backend arcane -Players $p -DurationSeconds $DurationSeconds -DatabaseName $DatabaseName -ServerPhysicsArg $serverPhysicsArg
      ($out | Out-String) | Set-Content (Join-Path $logsDir ("arcane_n${n}_swarm_players_$p.log"))
      $parsed = Get-SwarmFinal ($out | Out-String)
      Write-StatsSnapshot -ScenarioTag 'arcane_plus_spacetimedb' -Players $p -NumServers $n
      if (Test-BenchmarkPass -ParsedFinal $parsed -MaxErrRate $MaxErrRate -MaxLatencyMs $MaxLatencyMs) { $ceilA = $p } else { break }
    }

    Export-ScenarioLogs -ScenarioTag ("arcane_n$n") -ClusterNames $clusterNames
    Stop-ClusterContainers -Names $clusterNames
    $results += [PSCustomObject]@{ backend='arcane_plus_spacetimedb'; num_servers=$n; ceiling_players=$ceilA }
  }

  $csv = Join-Path $OutDir 'benchmark_v2_results.csv'
  $results | Export-Csv -NoTypeInformation -Path $csv
  Write-Host "v2 results written: $csv" -ForegroundColor Green
  $results | Format-Table -AutoSize
}
finally {
  try { Invoke-Compose 'down --remove-orphans' } catch {}
  for ($i = 0; $i -lt 12; $i++) {
    Remove-DockerContainerIfPresent -Name "arcane-v2-cluster-$i"
  }
}
