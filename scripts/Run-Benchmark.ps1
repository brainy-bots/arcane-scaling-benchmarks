<#
.SYNOPSIS
  Run the Arcane scaling benchmark (incremental player steps, single swarm process per scenario).

.DESCRIPTION
  Prerequisites (you must set these up before invoking this script):
  - Redis reachable at -RedisHost / -RedisPort (Arcane replication).
  - SpacetimeDB reachable at -SpacetimeHost (default http://127.0.0.1:3000) with database -DatabaseName
    and the module already published.
  - arcane-swarm built: default path arcane_swarm/target/release/arcane-swarm(.exe).
  - arcane-manager and arcane-cluster built when -FindArcaneCeiling is used:
    arcane/target/release/arcane-manager(.exe), arcane-cluster(.exe).

  This script does not build binaries, pull container images, or publish modules.

  **Outputs:** If -OutDir is omitted, writes under results/runs/<Environment>/<yyyyMMdd_HHmmss>/ (repo root).
  Use -Environment to separate local runs (default Local) from cloud topologies (e.g. SingleInstance). Each run contains
  spacetimedb_only/ and arcane_plus_spacetimedb/ with benchmark_scenarios_results.csv and stderr/*.log.

  **Pass criteria:** Default -MaxLatencyMs is **250** (workstations often jitter above 200 ms). The published experiment
  report used **200** ms; pass -MaxLatencyMs 200 to match that bar exactly.
#>

param(
  [int] $SpacetimeStep = 250,
  [int] $SpacetimeMaxPlayers = 2000,
  [int] $DurationSeconds = 30,

  [switch] $FindArcaneCeiling = $true,
  [int[]] $ArcaneClusterCounts = @(1, 2, 3, 4, 5, 10),
  [int] $ArcaneCeilingStartPlayers = 1500,
  [int] $ArcaneCeilingStep = 250,
  [int] $ArcaneCeilingMaxPlayers = 6000,

  [int] $PersistBatchSize = 0,

  [double] $MaxErrRate = 0.01,
  [double] $MaxLatencyMs = 250,

  [string] $SpacetimeHost = 'http://127.0.0.1:3000',
  [string] $DatabaseName = 'arcane',

  [string] $RedisHost = '127.0.0.1',
  [int] $RedisPort = 6379,

  [int] $TickRateHz = 10,
  [double] $ActionsPerSec = 2,
  [double] $ReadRateHz = 5,
  [string] $SwarmMode = 'spread',
  [int] $BetweenIncrementsSeconds = 1,
  [int] $SpacetimePersistHz = 1,

  [string] $Environment = 'Local',
  [string] $OutDir = '',
  [string] $SwarmExe = '',
  [string] $ArcaneManagerExe = '',
  [string] $ArcaneClusterExe = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$BenchmarkRoot = Resolve-Path (Join-Path $ScriptDir '..')

function Get-SafeResultsEnvironmentSegment([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return 'Local' }
  $s = $name.Trim() -replace '[<>:"/\\|?*]', '_'
  if ([string]::IsNullOrWhiteSpace($s)) { return 'Local' }
  return $s
}

function Get-ExeSuffix {
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsWindows) { return '.exe' }
    return ''
  }
  if ($env:OS -match 'Windows') { return '.exe' }
  return ''
}

$suffix = Get-ExeSuffix
$SwarmWorkspaceRoot = [System.IO.Path]::Combine($BenchmarkRoot, 'arcane_swarm')
$ArcaneRepo = [System.IO.Path]::Combine($BenchmarkRoot, 'arcane')

if ([string]::IsNullOrWhiteSpace($SwarmExe)) {
  $SwarmExe = [System.IO.Path]::Combine($SwarmWorkspaceRoot, 'target', 'release', "arcane-swarm$suffix")
}
if ([string]::IsNullOrWhiteSpace($ArcaneManagerExe)) {
  $ArcaneManagerExe = [System.IO.Path]::Combine($ArcaneRepo, 'target', 'release', "arcane-manager$suffix")
}
if ([string]::IsNullOrWhiteSpace($ArcaneClusterExe)) {
  $ArcaneClusterExe = [System.IO.Path]::Combine($ArcaneRepo, 'target', 'release', "arcane-cluster$suffix")
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $envSeg = Get-SafeResultsEnvironmentSegment $Environment
  $OutDir = Join-Path $BenchmarkRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $envSeg $runStamp)))
}
$null = New-Item -ItemType Directory -Path $OutDir -Force

function Stop-ArcaneProcesses {
  $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^arcane-' }
  if ($procs) {
    Write-Host "Stopping $($procs.Count) arcane-* process(es)..." -ForegroundColor Yellow
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
  }
}

function Stop-ListenerOnPort([int] $Port) {
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return }
  try {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
      $own = $c.OwningProcess
      if ($own -and $own -gt 0) {
        Stop-Process -Id $own -Force -ErrorAction SilentlyContinue
      }
    }
    Start-Sleep -Milliseconds 500
  } catch { }
}

function Test-TcpPortOpen {
  param([string] $ComputerName, [int] $Port)
  $client = $null
  try {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.ReceiveTimeout = 2000
    $client.SendTimeout = 2000
    $client.Connect($ComputerName, $Port)
    return $true
  } catch {
    return $false
  } finally {
    if ($null -ne $client) { $client.Dispose() }
  }
}

function Wait-TcpOpen([string] $TcpHost, [int] $Port, [int] $TimeoutSeconds) {
  for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
    if (Test-TcpPortOpen -ComputerName $TcpHost -Port $Port) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Assert-ProcessAlive([int[]] $ProcessIds, [string] $What) {
  foreach ($procId in $ProcessIds) {
    if (-not $procId) { continue }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) {
      throw "${What}: process id $procId is not running"
    }
  }
}

function Safe-Kill([int] $ProcessId, [string] $What) {
  if (-not $ProcessId) { return }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) {
      Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 500
    }
  } catch {
    Write-Warning "Failed to stop $What (processId=$ProcessId): $($_.Exception.Message)"
  }
}

function Assert-RedisReachable {
  if (-not (Wait-TcpOpen -TcpHost $RedisHost -Port $RedisPort -TimeoutSeconds 1)) {
    throw "Redis is not reachable at ${RedisHost}:${RedisPort}. Start Redis before running this script."
  }
}

function Assert-SpacetimeReachable {
  $dbHost = '127.0.0.1'
  $port = 3000
  if ($SpacetimeHost -match '^https?://([^:/]+)(?::(\d+))?') {
    $dbHost = $Matches[1]
    if ($Matches[2]) { $port = [int]$Matches[2] }
  }
  if (-not (Wait-TcpOpen -TcpHost $dbHost -Port $port -TimeoutSeconds 2)) {
    throw "SpacetimeDB is not reachable at ${dbHost}:${port}. Start it and publish the module before running this script."
  }
}

function Assert-SwarmBinary {
  if (-not (Test-Path -LiteralPath $SwarmExe)) {
    throw "Swarm binary not found: $SwarmExe. Build arcane-swarm (release) before running this script."
  }
}

function Assert-ArcaneBinaries {
  if (-not (Test-Path -LiteralPath $ArcaneManagerExe)) {
    throw "arcane-manager not found: $ArcaneManagerExe. Build before running this script."
  }
  if (-not (Test-Path -LiteralPath $ArcaneClusterExe)) {
    throw "arcane-cluster not found: $ArcaneClusterExe. Build before running this script."
  }
}

function Send-SwarmCommand([int]$Port, [string]$Line) {
  $client = New-Object System.Net.Sockets.TcpClient
  $client.Connect('127.0.0.1', $Port)
  $stream = $client.GetStream()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Line.TrimEnd() + "`n"))
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
  $client.Close()
}

function Parse-SwarmFinal([string] $Text) {
  $re = 'FINAL:\s*players=(\d+)\s+total_calls=(\d+)\s+total_oks=(\d+)\s+total_errs=(\d+)\s+lat_avg_ms=([\d.]+)'
  $all = [regex]::Matches($Text, $re)
  if ($all.Count -eq 0) { return $null }

  $m = $all[$all.Count - 1]
  return [PSCustomObject]@{
    players      = [int]$m.Groups[1].Value
    total_calls  = [long]$m.Groups[2].Value
    total_oks    = [long]$m.Groups[3].Value
    total_errs   = [long]$m.Groups[4].Value
    lat_avg_ms   = [double]$m.Groups[5].Value
  }
}

function Test-BenchmarkPass([object] $Parsed) {
  if (-not $Parsed) { return $false }
  $errRate = if ($Parsed.total_calls -gt 0) { $Parsed.total_errs / $Parsed.total_calls } else { 1.0 }
  return (($errRate -lt $MaxErrRate) -and ($Parsed.lat_avg_ms -lt $MaxLatencyMs))
}

function Run-Scenario-SpacetimeOnly {
  param(
    [string] $ScenarioOutDir,
    [int] $ControlPort,
    [int] $ScenarioStartPlayers,
    [int] $ScenarioStepPlayers,
    [int] $ScenarioMaxPlayers
  )

  $stdErrDir = Join-Path $ScenarioOutDir 'stderr'
  $null = New-Item -ItemType Directory -Path $stdErrDir -Force
  $stderr = Join-Path $stdErrDir "spacetimedb_only_${ControlPort}_stderr.log"
  if (Test-Path $stderr) { Remove-Item $stderr -Force }

  Write-Host "SpacetimeDB-only scenario (control port $ControlPort)" -ForegroundColor Cyan
  Stop-ListenerOnPort -Port $ControlPort

  $proc = Start-Process -FilePath $SwarmExe -WorkingDirectory $SwarmWorkspaceRoot -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $stdErrDir "spacetimedb_only_${ControlPort}_stdout.log") `
    -RedirectStandardError $stderr `
    -ArgumentList @(
    '--backend', 'spacetimedb',
    '--server-physics',
    '--players', $ScenarioStartPlayers,
    '--max-players', $ScenarioMaxPlayers,
    '--tick-rate', $TickRateHz,
    '--aps', $ActionsPerSec,
    '--mode', $SwarmMode,
    '--read-rate', $ReadRateHz,
    '--duration', '0',
    '--run-forever',
    '--control-port', $ControlPort,
    '--uri', $SpacetimeHost,
    '--db', $DatabaseName
  )

  if (-not (Wait-TcpOpen -TcpHost '127.0.0.1' -Port $ControlPort -TimeoutSeconds 20)) {
    throw "swarm control port $ControlPort was not opened (spacetime-only scenario)"
  }

  $players = $ScenarioStartPlayers
  $ceiling = $null
  try {
    while ($players -le $ScenarioMaxPlayers) {
      Write-Host "  [SpacetimeDB-only] testing players=$players ..." -ForegroundColor Gray
      Send-SwarmCommand -Port $ControlPort -Line "SET_PLAYERS $players"
      Start-Sleep -Seconds 2
      Send-SwarmCommand -Port $ControlPort -Line 'RESET'
      Start-Sleep -Seconds $DurationSeconds
      Send-SwarmCommand -Port $ControlPort -Line 'REPORT'

      Start-Sleep -Seconds $BetweenIncrementsSeconds
      $txt = ''
      if (Test-Path $stderr) { $txt = Get-Content -Path $stderr -Raw -ErrorAction SilentlyContinue }
      $parsed = Parse-SwarmFinal $txt
      $pass = Test-BenchmarkPass $parsed

      if ($pass) {
        $ceiling = $players
        $players += $ScenarioStepPlayers
      } else {
        break
      }
    }
  } finally {
    Send-SwarmCommand -Port $ControlPort -Line 'QUIT'
    Safe-Kill -ProcessId $proc.Id -What 'swarm'
  }

  return $ceiling
}

function Run-Scenario-Arcane {
  param(
    [string] $ScenarioOutDir,
    [int] $NumServers,
    [int] $ControlPort,
    [int] $ScenarioStartPlayers,
    [int] $ScenarioStepPlayers,
    [int] $ScenarioMaxPlayers
  )

  $stdErrDir = Join-Path $ScenarioOutDir 'stderr'
  $null = New-Item -ItemType Directory -Path $stdErrDir -Force

  Stop-ArcaneProcesses

  $clusterBasePort = 8090
  $managerPort = 8081

  $clusterIds = @(for ($i = 0; $i -lt $NumServers; $i++) { [guid]::NewGuid().ToString() })
  $clusterPids = @()

  $managerClusters = @()
  for ($i = 0; $i -lt $NumServers; $i++) {
    $port = $clusterBasePort + $i
    $managerClusters += "${($clusterIds[$i])}:127.0.0.1:${port}"
  }
  $env:MANAGER_CLUSTERS = ($managerClusters -join ',')
  $env:MANAGER_HTTP_PORT = $managerPort

  $managerLog = Join-Path $stdErrDir "manager_${NumServers}_stdout.log"
  $managerErr = Join-Path $stdErrDir "manager_${NumServers}_stderr.log"
  if (Test-Path $managerLog) { Remove-Item $managerLog -Force }
  if (Test-Path $managerErr) { Remove-Item $managerErr -Force }

  Write-Host "Arcane scenario num_servers=$NumServers" -ForegroundColor Cyan
  Stop-ListenerOnPort -Port $ControlPort

  $procManager = Start-Process -FilePath $ArcaneManagerExe -WorkingDirectory $ArcaneRepo -NoNewWindow -PassThru `
    -RedirectStandardOutput $managerLog -RedirectStandardError $managerErr
  Start-Sleep -Seconds 2

  $env:REDIS_URL = "redis://${RedisHost}:${RedisPort}"
  $env:SPACETIMEDB_PERSIST = '1'
  $env:SPACETIMEDB_URI = $SpacetimeHost
  $env:SPACETIMEDB_DATABASE = $DatabaseName
  $env:SPACETIMEDB_PERSIST_HZ = $SpacetimePersistHz.ToString()
  $env:SPACETIMEDB_PERSIST_BATCH_SIZE = $PersistBatchSize.ToString()

  for ($i = 0; $i -lt $NumServers; $i++) {
    $env:CLUSTER_ID = $clusterIds[$i]
    $env:CLUSTER_WS_PORT = ($clusterBasePort + $i).ToString()
    $neighborList = $clusterIds | Where-Object { $_ -ne $clusterIds[$i] }
    $env:NEIGHBOR_IDS = ($neighborList -join ',')

    $clog = Join-Path $stdErrDir "cluster_${NumServers}_${i}_stdout.log"
    $cerr = Join-Path $stdErrDir "cluster_${NumServers}_${i}_stderr.log"
    if (Test-Path $clog) { Remove-Item $clog -Force }
    if (Test-Path $cerr) { Remove-Item $cerr -Force }

    $p = Start-Process -FilePath $ArcaneClusterExe -WorkingDirectory $ArcaneRepo -NoNewWindow -PassThru `
      -RedirectStandardOutput $clog -RedirectStandardError $cerr
    $clusterPids += $p.Id
  }

  Start-Sleep -Seconds 3

  if (-not (Wait-TcpOpen -TcpHost '127.0.0.1' -Port $managerPort -TimeoutSeconds 20)) {
    throw "arcane-manager did not open port $managerPort"
  }
  for ($i = 0; $i -lt $NumServers; $i++) {
    $wsPort = $clusterBasePort + $i
    if (-not (Wait-TcpOpen -TcpHost '127.0.0.1' -Port $wsPort -TimeoutSeconds 20)) {
      throw "arcane-cluster[$i] did not open websocket port $wsPort"
    }
  }
  Assert-ProcessAlive -ProcessIds $clusterPids -What 'cluster'
  Assert-ProcessAlive -ProcessIds @($procManager.Id) -What 'manager'

  $stderr = Join-Path $stdErrDir "arcane_${NumServers}_${ControlPort}_stderr.log"
  $stdout = Join-Path $stdErrDir "arcane_${NumServers}_${ControlPort}_stdout.log"
  if (Test-Path $stderr) { Remove-Item $stderr -Force }
  if (Test-Path $stdout) { Remove-Item $stdout -Force }

  $procSwarm = Start-Process -FilePath $SwarmExe -WorkingDirectory $SwarmWorkspaceRoot -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -ArgumentList @(
    '--backend', 'arcane',
    '--players', $ScenarioStartPlayers,
    '--max-players', $ScenarioMaxPlayers,
    '--tick-rate', $TickRateHz,
    '--aps', $ActionsPerSec,
    '--mode', $SwarmMode,
    '--read-rate', $ReadRateHz,
    '--duration', '0',
    '--run-forever',
    '--control-port', $ControlPort,
    '--arcane-manager', "http://127.0.0.1:$managerPort",
    '--uri', $SpacetimeHost,
    '--db', $DatabaseName
  )

  if (-not (Wait-TcpOpen -TcpHost '127.0.0.1' -Port $ControlPort -TimeoutSeconds 20)) {
    throw "swarm control port $ControlPort was not opened"
  }

  $players = $ScenarioStartPlayers
  $ceiling = $null
  try {
    while ($players -le $ScenarioMaxPlayers) {
      Write-Host "  [Arcane+Spacetime] num_servers=$NumServers testing players=$players ..." -ForegroundColor Gray
      Send-SwarmCommand -Port $ControlPort -Line "SET_PLAYERS $players"
      Start-Sleep -Seconds 2
      Send-SwarmCommand -Port $ControlPort -Line 'RESET'
      Start-Sleep -Seconds $DurationSeconds
      Send-SwarmCommand -Port $ControlPort -Line 'REPORT'

      Start-Sleep -Seconds $BetweenIncrementsSeconds
      $txt = ''
      if (Test-Path $stderr) { $txt = Get-Content -Path $stderr -Raw -ErrorAction SilentlyContinue }
      $parsed = Parse-SwarmFinal $txt
      $pass = Test-BenchmarkPass $parsed

      if ($pass) {
        $ceiling = $players
        $players += $ScenarioStepPlayers
      } else {
        break
      }
    }
  } finally {
    Send-SwarmCommand -Port $ControlPort -Line 'QUIT'
    Safe-Kill -ProcessId $procSwarm.Id -What 'swarm'

    foreach ($cid in $clusterPids) { Safe-Kill -ProcessId $cid -What 'cluster' }
    Safe-Kill -ProcessId $procManager.Id -What 'manager'
  }

  return $ceiling
}

function Invoke-BenchmarkPhase {
  param(
    [string] $PhaseOutDir,
    [int[]] $ArcaneCounts,
    [int] $StartPlayers,
    [int] $StepPlayers,
    [int] $MaxPlayers
  )

  $null = New-Item -ItemType Directory -Path $PhaseOutDir -Force
  $results = @()

  $spControlPort = 9300
  $spCeiling = Run-Scenario-SpacetimeOnly -ScenarioOutDir $PhaseOutDir -ControlPort $spControlPort `
    -ScenarioStartPlayers $StartPlayers -ScenarioStepPlayers $StepPlayers -ScenarioMaxPlayers $MaxPlayers
  $results += [PSCustomObject]@{ backend = 'spacetimedb_only'; num_servers = 0; ceiling_players = $spCeiling }

  foreach ($n in $ArcaneCounts) {
    $controlPort = 9400 + $n
    $ceiling = Run-Scenario-Arcane -ScenarioOutDir $PhaseOutDir -NumServers $n -ControlPort $controlPort `
      -ScenarioStartPlayers $StartPlayers -ScenarioStepPlayers $StepPlayers -ScenarioMaxPlayers $MaxPlayers
    $results += [PSCustomObject]@{ backend = 'arcane_plus_spacetimedb'; num_servers = $n; ceiling_players = $ceiling }
  }

  $csv = Join-Path $PhaseOutDir 'benchmark_scenarios_results.csv'
  $results | Export-Csv -Path $csv -NoTypeInformation
  Write-Host "Results written to: $csv" -ForegroundColor Green

  Write-Host "`n--- Ceiling summary ---" -ForegroundColor Cyan
  $sp = ($results | Where-Object { $_.backend -eq 'spacetimedb_only' } | Select-Object -First 1).ceiling_players
  Write-Host "  SpacetimeDB only: ceiling = $sp players"
  foreach ($r in ($results | Where-Object { $_.backend -eq 'arcane_plus_spacetimedb' } | Sort-Object { $_.num_servers })) {
    Write-Host "  Arcane + SpacetimeDB ($($r.num_servers) cluster(s)): ceiling = $($r.ceiling_players) players"
  }
  Write-Host '---' -ForegroundColor Cyan
}

# --- Preconditions only (no builds / publish / image pulls) ---
Assert-RedisReachable
Assert-SpacetimeReachable
Assert-SwarmBinary
if ($FindArcaneCeiling -and ($null -ne $ArcaneClusterCounts) -and ($ArcaneClusterCounts.Count -gt 0)) {
  Assert-ArcaneBinaries
}

Write-Host "`n=== Run-Benchmark (incremental) ===" -ForegroundColor Cyan
Write-Host "Environment (results subfolder): $(Get-SafeResultsEnvironmentSegment $Environment)" -ForegroundColor Gray
Write-Host "Base OutDir: $OutDir" -ForegroundColor Gray

$spOnlyDir = Join-Path $OutDir 'spacetimedb_only'
Invoke-BenchmarkPhase -PhaseOutDir $spOnlyDir -ArcaneCounts @() `
  -StartPlayers $SpacetimeStep -StepPlayers $SpacetimeStep -MaxPlayers $SpacetimeMaxPlayers

if ($FindArcaneCeiling) {
  $arcDir = Join-Path $OutDir 'arcane_plus_spacetimedb'
  Invoke-BenchmarkPhase -PhaseOutDir $arcDir -ArcaneCounts $ArcaneClusterCounts `
    -StartPlayers $ArcaneCeilingStartPlayers -StepPlayers $ArcaneCeilingStep -MaxPlayers $ArcaneCeilingMaxPlayers
}

Stop-ArcaneProcesses
Write-Host "`nDone." -ForegroundColor Green
