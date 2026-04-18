<#
.SYNOPSIS
  Run the Arcane scaling benchmark (incremental player steps, single swarm process per scenario).

.DESCRIPTION
  Prerequisites (you must set these up before invoking this script):
  - Redis reachable at -RedisHost / -RedisPort (Arcane replication).
  - SpacetimeDB reachable at -SpacetimeHost (default http://127.0.0.1:3000) with database -DatabaseName
    and the module already published.
  - arcane-swarm built: default path arcane_swarm/target/release/arcane-swarm(.exe).
  - arcane-manager built when -FindArcaneCeiling is used: arcane/target/release/arcane-manager(.exe).
  - benchmark-cluster built when -FindArcaneCeiling is used:
    crates/benchmark-cluster/target/release/benchmark-cluster(.exe).
    This binary includes BenchmarkSimulation (kinematic physics matching SpacetimeDB's physics_tick).

  This script does not build binaries, pull container images, or publish modules.

  **Outputs:** If -OutDir is omitted, writes under results/runs/<Environment>/<yyyyMMdd_HHmmss>/ (repo root).
  Use -Environment to separate local runs (default Local) from cloud topologies (e.g. SingleInstance). Each run contains
  **benchmark_run_manifest.json** (effective parameters, pass criteria, binary hashes, host/git metadata) plus
  spacetimedb_only/ and arcane_plus_spacetimedb/ with benchmark_scenarios_results.csv and stderr/*.log.

  **Pass criteria:** Default -MaxLatencyMs is **250** (workstations often jitter above 200 ms). The published experiment
  report used **200** ms; pass -MaxLatencyMs 200 to match that bar exactly.
#>

param(
  [string] $ConfigFile = '',
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
  [switch] $BurstEnabled = $true,
  [int] $BurstPeriodSecs = 30,
  [int] $BurstCohortPercent = 20,
  [int] $BurstActionsPerPlayer = 10,
  [int] $BurstWindowMs = 500,
  [int] $ZoneEventPeriodSecs = 30,
  [int] $ZoneEventWindowMs = 500,

  [int] $BetweenIncrementsSeconds = 1,
  [int] $SpacetimePersistHz = 1,

  [string] $Environment = 'Local',
  [string] $OutDir = '',
  [string] $SwarmExe = '',
  [string] $ArcaneManagerExe = '',
  [string] $ArcaneClusterExe = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'BenchmarkHarnessHelpers.ps1')

Merge-ConfigFileParameters -Path $ConfigFile

# Best-effort: text of the command line as PowerShell saw it (often empty with -File from some hosts).
$BenchmarkHostInvocationLine = $null
if ($MyInvocation.Line -and $MyInvocation.Line.Trim()) {
  $BenchmarkHostInvocationLine = $MyInvocation.Line.Trim()
}

$ScriptDir = $PSScriptRoot
$BenchmarkRoot = Resolve-Path (Join-Path $ScriptDir '..')

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
if (-not (Test-Path -LiteralPath $SwarmWorkspaceRoot)) { $SwarmWorkspaceRoot = [string]$BenchmarkRoot }
$ArcaneRepo = [System.IO.Path]::Combine($BenchmarkRoot, 'arcane')
if (-not (Test-Path -LiteralPath $ArcaneRepo)) { $ArcaneRepo = [string]$BenchmarkRoot }

if ([string]::IsNullOrWhiteSpace($SwarmExe)) {
  $SwarmExe = [System.IO.Path]::Combine($SwarmWorkspaceRoot, 'target', 'release', "arcane-swarm$suffix")
}
if ([string]::IsNullOrWhiteSpace($ArcaneManagerExe)) {
  $ArcaneManagerExe = [System.IO.Path]::Combine($ArcaneRepo, 'target', 'release', "arcane-manager$suffix")
}
# Default to benchmark-cluster (with BenchmarkSimulation) instead of arcane-cluster (no simulation).
# benchmark-cluster lives in crates/benchmark-cluster/ in the benchmark repo, not in the arcane submodule.
$BenchmarkClusterRoot = [System.IO.Path]::Combine($BenchmarkRoot, 'crates', 'benchmark-cluster')
if ([string]::IsNullOrWhiteSpace($ArcaneClusterExe)) {
  $ArcaneClusterExe = [System.IO.Path]::Combine($BenchmarkClusterRoot, 'target', 'release', "benchmark-cluster$suffix")
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $envSeg = Get-SafeResultsEnvironmentSegment $Environment
  $OutDir = Join-Path $BenchmarkRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $envSeg $runStamp)))
}
$null = New-Item -ItemType Directory -Path $OutDir -Force
$runStartedUtc = [datetime]::UtcNow
$runSucceeded = $false
$runErr = $null

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

function Get-GitHeadOptional([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { return $null }
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) { return $null }
  Push-Location $RepoRoot
  try {
    $h = & git rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $h) { return ($h | Out-String).Trim() }
  } finally {
    Pop-Location
  }
  return $null
}

function Get-FileSha256Optional([string]$LiteralPath) {
  if (-not (Test-Path -LiteralPath $LiteralPath)) { return $null }
  try {
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
  } catch {
    return $null
  }
}

function Get-BinaryInfo([string]$LiteralPath) {
  if (-not (Test-Path -LiteralPath $LiteralPath)) {
    return @{ path = $LiteralPath; sha256 = $null; length_bytes = $null }
  }
  $fi = Get-Item -LiteralPath $LiteralPath
  return @{
    path         = $LiteralPath
    sha256       = (Get-FileSha256Optional -LiteralPath $LiteralPath)
    length_bytes = $fi.Length
    last_write_utc = $fi.LastWriteTimeUtc.ToString('o')
  }
}

function Escape-SingleQuotedPwsh([string]$Text) {
  if ($null -eq $Text) { return "''" }
  return "'" + ($Text.Replace("'", "''")) + "'"
}

function Build-BenchmarkReproCommandLine {
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  $parts = [System.Collections.Generic.List[string]]::new()
  $null = $parts.Add('pwsh')
  $null = $parts.Add('-NoProfile')
  $null = $parts.Add('-File')
  $null = $parts.Add((Escape-SingleQuotedPwsh $PSCommandPath))
  if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
    $null = $parts.Add('-ConfigFile')
    $null = $parts.Add((Escape-SingleQuotedPwsh $ConfigFile))
  }

  $ap = {
    param([string]$Name, $Value)
    $null = $parts.Add("-$Name")
    if ($null -eq $Value) {
      $null = $parts.Add("''")
      return
    }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
      $null = $parts.Add([Convert]::ToDouble($Value).ToString($inv))
      return
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or $Value -is [short]) {
      $null = $parts.Add($Value.ToString($inv))
      return
    }
    if ($Value -is [string]) {
      $null = $parts.Add((Escape-SingleQuotedPwsh $Value))
      return
    }
    if ($Value -is [System.Array]) {
      $null = $parts.Add(($Value -join ','))
      return
    }
    $null = $parts.Add((Escape-SingleQuotedPwsh ([string]$Value)))
  }

  & $ap 'SpacetimeStep' $SpacetimeStep
  & $ap 'SpacetimeMaxPlayers' $SpacetimeMaxPlayers
  & $ap 'DurationSeconds' $DurationSeconds
  $null = $parts.Add($(if ($FindArcaneCeiling) { '-FindArcaneCeiling' } else { '-FindArcaneCeiling:$false' }))
  & $ap 'ArcaneClusterCounts' $ArcaneClusterCounts
  & $ap 'ArcaneCeilingStartPlayers' $ArcaneCeilingStartPlayers
  & $ap 'ArcaneCeilingStep' $ArcaneCeilingStep
  & $ap 'ArcaneCeilingMaxPlayers' $ArcaneCeilingMaxPlayers
  & $ap 'PersistBatchSize' $PersistBatchSize
  & $ap 'MaxErrRate' $MaxErrRate
  & $ap 'MaxLatencyMs' $MaxLatencyMs
  & $ap 'SpacetimeHost' $SpacetimeHost
  & $ap 'DatabaseName' $DatabaseName
  & $ap 'RedisHost' $RedisHost
  & $ap 'RedisPort' $RedisPort
  & $ap 'TickRateHz' $TickRateHz
  & $ap 'ActionsPerSec' $ActionsPerSec
  & $ap 'ReadRateHz' $ReadRateHz
  & $ap 'SwarmMode' $SwarmMode
  $null = $parts.Add($(if ($BurstEnabled) { '-BurstEnabled' } else { '-BurstEnabled:$false' }))
  & $ap 'BurstPeriodSecs' $BurstPeriodSecs
  & $ap 'BurstCohortPercent' $BurstCohortPercent
  & $ap 'BurstActionsPerPlayer' $BurstActionsPerPlayer
  & $ap 'BurstWindowMs' $BurstWindowMs
  & $ap 'ZoneEventPeriodSecs' $ZoneEventPeriodSecs
  & $ap 'ZoneEventWindowMs' $ZoneEventWindowMs
  & $ap 'BetweenIncrementsSeconds' $BetweenIncrementsSeconds
  & $ap 'SpacetimePersistHz' $SpacetimePersistHz
  & $ap 'Environment' $Environment
  & $ap 'OutDir' $OutDir
  & $ap 'SwarmExe' $SwarmExe
  & $ap 'ArcaneManagerExe' $ArcaneManagerExe
  & $ap 'ArcaneClusterExe' $ArcaneClusterExe

  return ($parts -join ' ')
}

function Export-BenchmarkRunManifest {
  param(
    [string]$ManifestPath,
    [bool]$Succeeded,
    [string]$ErrorMessage,
    [datetime]$StartedUtc,
    [datetime]$FinishedUtc
  )

  $os = if ($PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.OS) {
    $PSVersionTable.OS
  } else {
    [System.Environment]::OSVersion.VersionString
  }

  $arcSweep = if ($FindArcaneCeiling) {
    @{
      enabled            = $true
      cluster_counts     = @($ArcaneClusterCounts)
      start_players      = $ArcaneCeilingStartPlayers
      step_players       = $ArcaneCeilingStep
      max_players        = $ArcaneCeilingMaxPlayers
      duration_seconds_per_tier = $DurationSeconds
    }
  } else {
    @{ enabled = $false }
  }

  $bin = @{
    arcane_swarm = (Get-BinaryInfo -LiteralPath $SwarmExe)
  }
  if ($FindArcaneCeiling -and ($null -ne $ArcaneClusterCounts) -and ($ArcaneClusterCounts.Count -gt 0)) {
    $bin.arcane_manager = Get-BinaryInfo -LiteralPath $ArcaneManagerExe
    $bin.arcane_cluster = Get-BinaryInfo -LiteralPath $ArcaneClusterExe
  }

  $manifest = [ordered]@{
    schema_version       = 3
    find_arcane_ceiling  = [bool]$FindArcaneCeiling
    run_started_utc  = $StartedUtc.ToString('o')
    run_finished_utc = $FinishedUtc.ToString('o')
    run_succeeded    = $Succeeded
    run_error        = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
    harness          = @{
      script               = 'Run-Benchmark.ps1'
      benchmark_repo_root  = [string]$BenchmarkRoot
      out_dir              = $OutDir
      pwsh_version         = $PSVersionTable.PSVersion.ToString()
    }
    invocation       = @{
      script_path                  = $PSCommandPath
      host_powershell_line         = $BenchmarkHostInvocationLine
      config_file                  = $(if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $null } else { (Resolve-Path -LiteralPath $ConfigFile).Path })
      repro_command_pwsh_no_profile = (Build-BenchmarkReproCommandLine)
    }
    environment_label = (Get-SafeResultsEnvironmentSegment $Environment)
    pass_criteria     = @{
      max_err_rate         = $MaxErrRate
      max_latency_avg_ms   = $MaxLatencyMs
    }
    connectivity      = @{
      spacetime_host = $SpacetimeHost
      database_name  = $DatabaseName
      redis_host     = $RedisHost
      redis_port     = $RedisPort
    }
    swarm_client      = @{
      simulation_rates = @{
        tick_rate_hz        = $TickRateHz
        tick_rate_cli_flag  = '--tick-rate'
        actions_per_second  = $ActionsPerSec
        actions_cli_flag    = '--aps'
        read_refresh_rate_hz = $ReadRateHz
        read_rate_cli_flag  = '--read-rate'
        movement_mode       = $SwarmMode
        mode_cli_flag       = '--mode'
        burst_profile       = @{
          enabled = [bool]$BurstEnabled
          burst_period_secs = $BurstPeriodSecs
          burst_cohort_percent = $BurstCohortPercent
          burst_actions_per_player = $BurstActionsPerPlayer
          burst_window_ms = $BurstWindowMs
          zone_event_period_secs = $ZoneEventPeriodSecs
          zone_event_window_ms = $ZoneEventWindowMs
        }
      }
      process_flags     = @{
        duration_seconds_cli = 0
        duration_cli_flag    = '--duration'
        run_forever          = $true
        run_forever_cli_flag = '--run-forever'
      }
      harness_timing_seconds = @{
        after_set_players_before_reset = 2
        steady_state_per_player_tier   = $DurationSeconds
        between_player_tiers           = $BetweenIncrementsSeconds
      }
      backends          = @{
        spacetimedb_only = @{
          backend              = 'spacetimedb'
          server_physics       = $true
          server_physics_flag  = '--server-physics'
        }
        arcane_plus_spacetimedb = @{
          backend                 = 'arcane'
          arcane_manager_base_url = 'http://127.0.0.1:8081'
          arcane_manager_cli_flag = '--arcane-manager'
        }
      }
    }
    arcane_persist    = @{
      spacetimedb_persist_hz        = $SpacetimePersistHz
      spacetimedb_persist_batch_size = $PersistBatchSize
    }
    spacetimedb_only_sweep = @{
      start_players               = $SpacetimeStep
      step_players                = $SpacetimeStep
      max_players                 = $SpacetimeMaxPlayers
      duration_seconds_per_tier   = $DurationSeconds
    }
    arcane_plus_spacetimedb_sweep = $arcSweep
    binaries          = $bin
    host              = @{
      machine_name = [System.Environment]::MachineName
      os           = $os
    }
    git               = @{
      benchmark_repo_head = (Get-GitHeadOptional -RepoRoot ([string]$BenchmarkRoot))
      arcane_swarm_head   = (Get-GitHeadOptional -RepoRoot (Join-Path ([string]$BenchmarkRoot) 'arcane_swarm'))
    }
  }

  $json = $manifest | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $ManifestPath -Value $json -Encoding utf8
  Write-Host "Run manifest: $ManifestPath" -ForegroundColor DarkGray
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
  $re = 'FINAL:\s*players=(\d+)\s+total_calls=(\d+)\s+total_oks=(\d+)\s+total_errs=(\d+)\s+lat_avg_ms=([\d.]+)(?:\s+err_json=(\{.*?\}))?'
  $all = [regex]::Matches($Text, $re)
  if ($all.Count -eq 0) { return $null }

  $m = $all[$all.Count - 1]
  return [PSCustomObject]@{
    players      = [int]$m.Groups[1].Value
    total_calls  = [long]$m.Groups[2].Value
    total_oks    = [long]$m.Groups[3].Value
    total_errs   = [long]$m.Groups[4].Value
    lat_avg_ms   = [double]$m.Groups[5].Value
    err_json     = $m.Groups[6].Value
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

  $swarmArgs = @(
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
  if ($BurstEnabled) {
    $swarmArgs += @(
      '--burst-enabled',
      '--burst-period-secs', $BurstPeriodSecs,
      '--burst-cohort-percent', $BurstCohortPercent,
      '--burst-actions-per-player', $BurstActionsPerPlayer,
      '--burst-window-ms', $BurstWindowMs,
      '--zone-event-period-secs', $ZoneEventPeriodSecs,
      '--zone-event-window-ms', $ZoneEventWindowMs
    )
  } else {
    $swarmArgs += @('--burst-disabled')
  }
  $proc = Start-Process -FilePath $SwarmExe -WorkingDirectory $SwarmWorkspaceRoot -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $stdErrDir "spacetimedb_only_${ControlPort}_stdout.log") `
    -RedirectStandardError $stderr `
    -ArgumentList $swarmArgs

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

  $swarmArgs = @(
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
  if ($BurstEnabled) {
    $swarmArgs += @(
      '--burst-enabled',
      '--burst-period-secs', $BurstPeriodSecs,
      '--burst-cohort-percent', $BurstCohortPercent,
      '--burst-actions-per-player', $BurstActionsPerPlayer,
      '--burst-window-ms', $BurstWindowMs,
      '--zone-event-period-secs', $ZoneEventPeriodSecs,
      '--zone-event-window-ms', $ZoneEventWindowMs
    )
  } else {
    $swarmArgs += @('--burst-disabled')
  }
  $procSwarm = Start-Process -FilePath $SwarmExe -WorkingDirectory $SwarmWorkspaceRoot -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -ArgumentList $swarmArgs

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
  $spLabel = if ($null -eq $sp) { 'none (no passing tier in this sweep)' } else { "$sp" }
  Write-Host "  SpacetimeDB only: ceiling = $spLabel players"
  foreach ($r in ($results | Where-Object { $_.backend -eq 'arcane_plus_spacetimedb' } | Sort-Object { $_.num_servers })) {
    Write-Host "  Arcane + SpacetimeDB ($($r.num_servers) cluster(s)): ceiling = $($r.ceiling_players) players"
  }
  Write-Host '---' -ForegroundColor Cyan
}

# --- Preconditions only (no builds / publish / image pulls) ---
try {
  Assert-SpacetimeReachable
  Assert-SwarmBinary
  if ($FindArcaneCeiling -and ($null -ne $ArcaneClusterCounts) -and ($ArcaneClusterCounts.Count -gt 0)) {
    # Redis is only used by the Arcane phase (cluster replication). SpacetimeOnly runs never touch it.
    Assert-RedisReachable
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

  $runSucceeded = $true
} catch {
  $runErr = $_.Exception.Message
  throw
} finally {
  $manifestPath = Join-Path $OutDir 'benchmark_run_manifest.json'
  Export-BenchmarkRunManifest `
    -ManifestPath $manifestPath `
    -Succeeded $runSucceeded `
    -ErrorMessage $runErr `
    -StartedUtc $runStartedUtc `
    -FinishedUtc ([datetime]::UtcNow)
  Stop-ArcaneProcesses
}

Write-Host "`nDone." -ForegroundColor Green
