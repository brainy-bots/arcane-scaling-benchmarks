# Shared helpers for Run-Benchmark.ps1 (dot-source from that script so Merge-ConfigFileParameters
# and the Invoke-*ScenarioRun wrappers can Set-Variable -Scope Script into, and read from, the
# entry script's scope via dynamic scope lookup).

# JSONC reader (used by Merge-ConfigFileParameters and by the AWS pre-SSM validator).
. (Join-Path $PSScriptRoot 'BenchmarkConfigJsonc.ps1')

# Poll one cluster's /stats endpoint exposed by arcane-infra (CLUSTER_STATS_PORT,
# default CLUSTER_WS_PORT + 1). Returns the parsed JSON object or $null on any
# failure. Intentionally forgiving — callers decide whether a null result is fatal.
function Get-ArcaneClusterStatsJson {
  param(
    [Parameter(Mandatory)][string]$ClusterHost,
    [int]$ClusterStatsPort = 8091,
    [int]$TimeoutSec = 5
  )
  try {
    $resp = Invoke-WebRequest -Uri ("http://{0}:{1}/stats" -f $ClusterHost, $ClusterStatsPort) `
      -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    return ($resp.Content | ConvertFrom-Json)
  } catch {
    return $null
  }
}

# Poll each cluster's /stats until the total entity count reaches a target
# ratio of the expected player count, or until timeout. This is the "ramp
# completed" signal before starting the measurement window — at scale
# (1500+ players) the swarm takes 30-60s to fully connect on AWS, which is
# longer than the tier's DurationSeconds. Starting the measurement mid-ramp
# produces meaningless numbers.
#
# Uses per-host base port + (index * stride) so it matches the cluster layout
# used elsewhere (stride 1 for local, stride 0 for AwsArcanePerHost).
#
# Returns a hashtable:
#   @{ Ready = $bool; FinalTotal = int; ElapsedSec = double; Detail = string }
function Wait-ArcaneClustersReachEntityCount {
  param(
    [Parameter(Mandatory)][string[]]$ClusterHosts,
    [int]$ClusterBasePort = 8090,
    [int]$ClusterPortStride = 1,
    [Parameter(Mandatory)][int]$TargetTotalEntities,
    [double]$ReachedRatioMin = 0.95,
    [int]$TimeoutSeconds = 180,
    [int]$PollIntervalSeconds = 2
  )
  $required = [int][Math]::Ceiling($TargetTotalEntities * $ReachedRatioMin)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $started = Get-Date
  $lastTotal = -1
  $lastDetail = ''
  while ((Get-Date) -lt $deadline) {
    $total = 0
    $pollOk = $true
    $detail = @()
    for ($i = 0; $i -lt $ClusterHosts.Count; $i++) {
      $h = $ClusterHosts[$i]
      $statsPort = $ClusterBasePort + ($i * $ClusterPortStride) + 1
      $json = Get-ArcaneClusterStatsJson -ClusterHost $h -ClusterStatsPort $statsPort -TimeoutSec 5
      if ($null -eq $json) {
        $pollOk = $false
        $detail += "cluster[$i] $h`:$statsPort UNREACHABLE"
      } else {
        $total += [int]$json.entities_current
        $detail += "cluster[$i] $h`:$statsPort entities=$($json.entities_current) msgs_ps=$($json.msgs_player_state)"
      }
    }
    $lastTotal = $total
    $lastDetail = $detail -join '; '
    if ($pollOk -and $total -ge $required) {
      return @{
        Ready      = $true
        FinalTotal = $total
        ElapsedSec = ((Get-Date) - $started).TotalSeconds
        Detail     = $lastDetail
      }
    }
    Start-Sleep -Seconds $PollIntervalSeconds
  }
  return @{
    Ready      = $false
    FinalTotal = $lastTotal
    ElapsedSec = ((Get-Date) - $started).TotalSeconds
    Detail     = "ramp timed out after ${TimeoutSeconds}s: reached $lastTotal / $required required (target $TargetTotalEntities). $lastDetail"
  }
}

# POST a COUNT query to SpacetimeDB's HTTP SQL endpoint and return the number.
# SpacetimeDB 2.x exposes `POST /v1/database/{name}/sql` with the SQL text as body.
# Anonymous access works when the module was published with --anonymous (which
# docker/benchmark-publish-module.sh does). Returns $null on any failure —
# callers treat null as "couldn't verify", not "0 entities".
function Invoke-SpacetimeDbEntityCountQuery {
  param(
    [Parameter(Mandatory)][string]$SpacetimeHost,
    [Parameter(Mandatory)][string]$Database,
    [string]$Table = 'entity',
    [int]$TimeoutSec = 5
  )
  $uri = ('{0}/v1/database/{1}/sql' -f $SpacetimeHost.TrimEnd('/'), $Database)
  # SpacetimeDB's SQL engine rejects aggregate expressions without a column alias
  # ("Aggregate expressions must have column aliases"), so `AS n` is required.
  $body = "SELECT COUNT(*) AS n FROM $Table"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method Post -Body $body -ContentType 'text/plain' `
      -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    # Only accept the structured SpacetimeDB SQL result shape: array with .rows = [[N]].
    # Any other shape (including error bodies that happen to contain integers) returns
    # $null so the caller keeps polling instead of accepting a bogus count.
    $parsed = $null
    try { $parsed = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    foreach ($entry in @($parsed)) {
      if ($null -ne $entry.rows) {
        foreach ($r in @($entry.rows)) {
          $vals = @($r)
          if ($vals.Count -gt 0) {
            $n = 0L
            if ([int64]::TryParse([string]$vals[0], [ref]$n)) { return [int64]$n }
          }
        }
      }
    }
    return $null
  } catch {
    return $null
  }
}

# Poll SpacetimeDB's entity table row count until it reaches the target ratio
# of the swarm's declared player count, or until timeout. Mirrors
# Wait-ArcaneClustersReachEntityCount for the SpacetimeDB-only scenario.
# Returns the same @{ Ready; FinalTotal; ElapsedSec; Detail } hashtable.
function Wait-SpacetimeDbReachEntityCount {
  param(
    [Parameter(Mandatory)][string]$SpacetimeHost,
    [Parameter(Mandatory)][string]$Database,
    [string]$Table = 'entity',
    [Parameter(Mandatory)][int]$TargetEntities,
    [double]$ReachedRatioMin = 0.95,
    [int]$TimeoutSeconds = 180,
    [int]$PollIntervalSeconds = 2
  )
  $required = [int][Math]::Ceiling($TargetEntities * $ReachedRatioMin)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $started = Get-Date
  $lastTotal = -1
  $lastDetail = ''
  while ((Get-Date) -lt $deadline) {
    $n = Invoke-SpacetimeDbEntityCountQuery -SpacetimeHost $SpacetimeHost -Database $Database -Table $Table -TimeoutSec 5
    if ($null -eq $n) {
      $lastDetail = "spacetime $SpacetimeHost/$Database UNREACHABLE"
    } else {
      $lastTotal = [int]$n
      $lastDetail = "spacetime $SpacetimeHost/$Database entities=$lastTotal"
      if ($lastTotal -ge $required) {
        return @{
          Ready      = $true
          FinalTotal = $lastTotal
          ElapsedSec = ((Get-Date) - $started).TotalSeconds
          Detail     = $lastDetail
        }
      }
    }
    Start-Sleep -Seconds $PollIntervalSeconds
  }
  return @{
    Ready      = $false
    FinalTotal = $lastTotal
    ElapsedSec = ((Get-Date) - $started).TotalSeconds
    Detail     = "ramp timed out after ${TimeoutSeconds}s: reached $lastTotal / $required required (target $TargetEntities). $lastDetail"
  }
}

function Test-IsLocalLoopbackHostName([string]$TargetHost) {
  if ([string]::IsNullOrWhiteSpace($TargetHost)) { return $true }
  $x = $TargetHost.Trim().ToLowerInvariant()
  return ($x -eq '127.0.0.1' -or $x -eq 'localhost' -or $x -eq '::1')
}

function Assert-ArcaneTopologyForSweep {
  param(
    $ArcaneClusterCounts,
    [AllowEmptyCollection()][string[]]$ArcaneClusterHosts,
    [int]$ArcaneClusterPortStride,
    [bool]$ArcaneExternalProcesses,
    [string]$ArcaneManagerHost
  )

  if ($null -eq $ArcaneClusterCounts -or $ArcaneClusterCounts.Count -eq 0) { return }
  $maxN = ($ArcaneClusterCounts | Measure-Object -Maximum).Maximum
  if ($maxN -lt 1) { return }

  $hostCount = if ($null -eq $ArcaneClusterHosts) { 0 } else { $ArcaneClusterHosts.Count }
  if ($hostCount -gt 0 -and $hostCount -lt $maxN) {
    throw "ArcaneClusterHosts has $hostCount entries but max(ArcaneClusterCounts) is $maxN. Provide at least $maxN hostnames (index i = cluster i), or omit ArcaneClusterHosts for all-localhost."
  }

  if ($ArcaneClusterPortStride -eq 0 -and $maxN -gt 1 -and $hostCount -eq 0) {
    throw "ArcaneClusterPortStride 0 targets one cluster per machine (same WS port on each host). Set ArcaneClusterHosts with $maxN distinct hosts, or use -ArcaneClusterPortStride 1 for multiple clusters on localhost."
  }

  if ($ArcaneClusterPortStride -eq 0 -and $maxN -gt 1) {
    $slice = @(for ($i = 0; $i -lt $maxN; $i++) { [string]$ArcaneClusterHosts[$i] })
    $unique = $slice | Select-Object -Unique
    if ($unique.Count -ne $slice.Count) {
      throw "ArcaneClusterPortStride 0 requires distinct ArcaneClusterHosts for indices 0..$($maxN - 1) (duplicate host would share the same websocket port)."
    }
  }

  if (-not $ArcaneExternalProcesses) {
    if (-not (Test-IsLocalLoopbackHostName $ArcaneManagerHost)) {
      throw "ArcaneManagerHost '$ArcaneManagerHost' is not loopback. Use -ArcaneExternalProcesses when the manager runs on another machine (this script will not start it locally)."
    }
    foreach ($h in $ArcaneClusterHosts) {
      if (-not (Test-IsLocalLoopbackHostName $h)) {
        throw "ArcaneClusterHosts contains '$h' (non-loopback). Use -ArcaneExternalProcesses when clusters run on remote hosts."
      }
    }
  }
}

function Get-SafeResultsEnvironmentSegment([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return 'Local' }
  $s = $name.Trim() -replace '[<>:"/\\|?*]', '_'
  if ([string]::IsNullOrWhiteSpace($s)) { return 'Local' }
  return $s
}

function Merge-ConfigFileParameters {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Config file not found: $Path"
  }

  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $cfg = ConvertFrom-BenchmarkConfigJsonc -Text $raw
  if ($null -eq $cfg) { return }

  $supported = @(
    'SpacetimeStep',
    'SpacetimeMaxPlayers',
    'DurationSeconds',
    'ArcaneClusterCounts',
    'ArcaneCeilingStartPlayers',
    'ArcaneCeilingStep',
    'ArcaneCeilingMaxPlayers',
    'PersistBatchSize',
    'MaxErrRate',
    'MaxLatencyMs',
    'SpacetimeHost',
    'DatabaseName',
    'RedisHost',
    'RedisPort',
    'TickRateHz',
    'ActionsPerSec',
    'ReadRateHz',
    'SwarmMode',
    'BurstEnabled',
    'BurstPeriodSecs',
    'BurstCohortPercent',
    'BurstActionsPerPlayer',
    'BurstWindowMs',
    'ZoneEventPeriodSecs',
    'ZoneEventWindowMs',
    'BetweenIncrementsSeconds',
    'SpacetimePersistHz',
    'Environment',
    'OutDir',
    'SwarmExe',
    'ArcaneManagerExe',
    'ArcaneClusterExe',
    'ArcaneManagerHost',
    'ArcaneManagerPort',
    'ArcaneClusterHosts',
    'ArcaneClusterBasePort',
    'ArcaneClusterPortStride',
    'ArcaneExternalProcesses',
    # Validity-gate tuning knobs. Not normally in the config — changing them invalidates
    # cross-run comparisons. Accepted here so a power-user override is still possible;
    # each Invoke-*ScenarioRun wrapper provides a hardcoded fallback when unset.
    'ArcaneRampTimeoutSeconds',
    'ArcaneRampReachedRatio',
    'ArcaneEntityObservedRatioMin',
    # Per-tick swarm payload size (bytes). 0 = lean baseline. > 0 fills
    # PlayerStatePayload.user_data with deterministic-but-varied bytes for the
    # realistic-state benchmark. Arcane backend only.
    'UserDataBytes',
    # Multi-driver join-rate pacing. Sleep N ms between consecutive player
    # spawns inside the swarm. Default 0 = burst-spawn (single-driver). Set
    # > 0 in multi-driver configs to keep aggregate manager /join load
    # constant as driver count scales. See tasks #79–#82.
    'InterSpawnDelayMs',
    # Multi-driver: how many drivers are running this same config. The
    # validity gate (cluster entity count check) waits for cluster total
    # = $players * $DriverCount, since each driver only spawns its slice.
    # Default 1 = single-driver semantics unchanged.
    'DriverCount',
    # Hard safety cap on simultaneously-active players per driver. The
    # tier-sweep refuses to advance to a tier where per-driver $players
    # > $MaxPlayersPerDriver and marks that tier INVALID with reason
    # "would-exceed-driver-cap". Forces the operator to provision more
    # drivers instead of silently entering the tokio-saturation zone.
    # Default 0 = no cap. Threaded to the swarm via --max-players-per-driver.
    'MaxPlayersPerDriver',
    # Metadata keys — consumed by the AWS run validator / docs, not by Run-Benchmark.ps1. Accepted here so the
    # same config file works for both the local harness and the AWS-side topology validator.
    'BenchmarkMode',
    'SpacetimeModule',
    'PhysicsEngine',
    # Cluster simulation tick rate (consumed by AWS orchestrator → cluster
    # container env BENCHMARK_TICK_RATE_HZ). Accepted here so the validator
    # tolerates the field.
    'ClusterTickRateHz',
    # Scalar alias for ArcaneClusterCounts. The AWS validator needs the scalar;
    # the harness runs a sweep over ArcaneClusterCounts. Translated below.
    'ArcaneClusterCount'
  )
  $supportedSet = @{}
  foreach ($k in $supported) { $supportedSet[$k] = $true }

  foreach ($prop in $cfg.PSObject.Properties) {
    if (-not $supportedSet.ContainsKey($prop.Name)) {
      throw "Unsupported config key '$($prop.Name)' in $Path"
    }
    Set-Variable -Name $prop.Name -Value $prop.Value -Scope Script
  }

  # Translate the scalar ArcaneClusterCount (AWS validator spelling) into the
  # ArcaneClusterCounts array the harness iterates. Only fires when the config
  # explicitly supplied the scalar AND the config did NOT also supply the array.
  # We can't use Get-Variable existence as the signal because PS defaults make
  # both variables always present — we check whether the config itself set them.
  $cfgHasScalar = $cfg.PSObject.Properties.Name -contains 'ArcaneClusterCount'
  $cfgHasArray  = $cfg.PSObject.Properties.Name -contains 'ArcaneClusterCounts'
  if ($cfgHasScalar -and -not $cfgHasArray) {
    Set-Variable -Name 'ArcaneClusterCounts' -Value @([int]$cfg.ArcaneClusterCount) -Scope Script
  }

  # Tick-rate single source of truth: when the config sets ClusterTickRateHz,
  # the swarm's TickRateHz derives from it so the cluster sees fresh input on
  # every tick. Otherwise a 30 Hz cluster paired with 10 Hz swarm only refreshes
  # entity velocity once every 3 cluster ticks — undersupplying the inbound
  # workload and understating the "30 Hz" claim. Real-game pattern is
  # client send rate >= server tick rate.
  #
  # Escape hatch: configs without ClusterTickRateHz fall through to the
  # legacy TickRateHz field as before. A config that wants the rates
  # genuinely decoupled today has to either (a) drop ClusterTickRateHz, or
  # (b) accept the harness-derived match — we do not currently support
  # "set both to different values" since it has been a footgun every time.
  if ($cfg.PSObject.Properties.Name -contains 'ClusterTickRateHz') {
    Set-Variable -Name 'TickRateHz' -Value ([int]$cfg.ClusterTickRateHz) -Scope Script
  }
}

# ──────────────────────────────────────────────────────────────────────────
# Process / TCP / binary helpers. These were inline in Run-Benchmark.ps1 before
# that script was split into scenario-specific entry points; they read
# script-scope variables (e.g. $SwarmExe) through PowerShell's dynamic-scope
# lookup, so each entry point must dot-source this file *after* its param block.
# ──────────────────────────────────────────────────────────────────────────

function Get-ExeSuffix {
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsWindows) { return '.exe' }
    return ''
  }
  if ($env:OS -match 'Windows') { return '.exe' }
  return ''
}

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
  if ($ArcaneExternalProcesses) { return }
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
  # `lat_avg_ms` on the swarm's FINAL line is **client-perceived latency** —
  # the wall-clock gap between a player's outbound write and the moment that
  # player's own entity state is echoed back by the server (Arcane broadcast
  # frame or SpacetimeDB `on_update` subscription). It is NOT the time around
  # the client's send call — that would be ~0 ms on both backends because
  # both are fire-and-forget. See REPRODUCIBILITY.md "What the benchmark
  # actually measures" and arcane_swarm's backends_*.rs for the full detail.
  # The wire field name is kept for back-compat with historical parsers.
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

# ──────────────────────────────────────────────────────────────────────────
# Scenario runners. Each one runs one scenario end-to-end for a single entry
# point — SpacetimeDB-only or Arcane+SpacetimeDB. They populate
# $script:SpacetimeOnlyRunEvidence / $script:ArcaneRunEvidence on the calling
# script scope.
# ──────────────────────────────────────────────────────────────────────────

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

      # Mirror the Arcane-mode validity gate: wait for SpacetimeDB's entity table to
      # reflect the swarm's declared count before starting the measurement window.
      # Without this, an empty or broken SpacetimeDB would silently "pass" the tier
      # on swarm-side metrics alone, the way the pre-gate Arcane path used to.
      $ramp = Wait-SpacetimeDbReachEntityCount -SpacetimeHost $SpacetimeHost -Database $DatabaseName `
        -TargetEntities $players -ReachedRatioMin $ArcaneRampReachedRatio `
        -TimeoutSeconds $ArcaneRampTimeoutSeconds -PollIntervalSeconds 2
      Write-Host ("    [ramp] reached={0} target~{1} elapsed={2:N1}s ready={3}" `
          -f $ramp.FinalTotal, $players, $ramp.ElapsedSec, $ramp.Ready) -ForegroundColor DarkGray
      if (-not $ramp.Ready) {
        Write-Host ("    [invalid] tier players=$players RAMP FAILED: $($ramp.Detail)") -ForegroundColor Yellow
        $script:SpacetimeOnlyRunEvidence += [PSCustomObject]@{
          scenario           = 'spacetimedb_only'
          players            = $players
          swarm_pass         = $false
          entities_observed  = $ramp.FinalTotal
          entities_required  = [int][Math]::Ceiling($players * $ArcaneRampReachedRatio)
          tier_valid         = $false
          validity_reason    = "ramp timeout: $($ramp.Detail)"
        }
        break
      }

      Send-SwarmCommand -Port $ControlPort -Line 'RESET'
      Start-Sleep -Seconds $DurationSeconds
      Send-SwarmCommand -Port $ControlPort -Line 'REPORT'

      Start-Sleep -Seconds $BetweenIncrementsSeconds
      $txt = ''
      if (Test-Path $stderr) { $txt = Get-Content -Path $stderr -Raw -ErrorAction SilentlyContinue }
      $parsed = Parse-SwarmFinal $txt
      $pass = Test-BenchmarkPass $parsed

      $script:SpacetimeOnlyRunEvidence += [PSCustomObject]@{
        scenario           = 'spacetimedb_only'
        players            = $players
        swarm_pass         = [bool]$pass
        entities_observed  = $ramp.FinalTotal
        entities_required  = [int][Math]::Ceiling($players * $ArcaneRampReachedRatio)
        tier_valid         = [bool]$pass
        validity_reason    = $(if ($pass) { '' } else { 'swarm pass criteria not met (err_rate/latency)' })
      }

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

  $managerPort = $ArcaneManagerPort
  $clusterBasePort = $ArcaneClusterBasePort

  $clusterIds = @(for ($i = 0; $i -lt $NumServers; $i++) { [guid]::NewGuid().ToString() })
  $clusterPids = @()
  $procManager = $null

  $managerClusters = @()
  for ($i = 0; $i -lt $NumServers; $i++) {
    $ch = if ($ArcaneClusterHosts.Count -eq 0) { '127.0.0.1' } else { $ArcaneClusterHosts[$i] }
    $wsPort = $clusterBasePort + ($i * $ArcaneClusterPortStride)
    $managerClusters += "${($clusterIds[$i])}:${ch}:${wsPort}"
  }
  $env:MANAGER_CLUSTERS = ($managerClusters -join ',')
  $env:MANAGER_HTTP_PORT = $managerPort.ToString()

  $managerLog = Join-Path $stdErrDir "manager_${NumServers}_stdout.log"
  $managerErr = Join-Path $stdErrDir "manager_${NumServers}_stderr.log"
  if (Test-Path $managerLog) { Remove-Item $managerLog -Force }
  if (Test-Path $managerErr) { Remove-Item $managerErr -Force }

  Write-Host "Arcane scenario num_servers=$NumServers (manager ${ArcaneManagerHost}:${managerPort}, external=$ArcaneExternalProcesses)" -ForegroundColor Cyan
  Stop-ListenerOnPort -Port $ControlPort

  if (-not $ArcaneExternalProcesses) {
    Stop-ArcaneProcesses

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
      $wsPort = $clusterBasePort + ($i * $ArcaneClusterPortStride)
      $env:CLUSTER_WS_PORT = $wsPort.ToString()
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
  } else {
    Write-Host '  External Arcane: waiting for manager / clusters (no local spawn)...' -ForegroundColor DarkGray
  }

  if (-not (Wait-TcpOpen -TcpHost $ArcaneManagerHost -Port $managerPort -TimeoutSeconds 20)) {
    throw "arcane-manager did not open port ${ArcaneManagerHost}:${managerPort}"
  }
  for ($i = 0; $i -lt $NumServers; $i++) {
    $ch = if ($ArcaneClusterHosts.Count -eq 0) { '127.0.0.1' } else { $ArcaneClusterHosts[$i] }
    $wsPort = $clusterBasePort + ($i * $ArcaneClusterPortStride)
    if (-not (Wait-TcpOpen -TcpHost $ch -Port $wsPort -TimeoutSeconds 20)) {
      throw "arcane-cluster[$i] did not open websocket ${ch}:${wsPort}"
    }
  }

  if (-not $ArcaneExternalProcesses) {
    Assert-ProcessAlive -ProcessIds $clusterPids -What 'cluster'
    Assert-ProcessAlive -ProcessIds @($procManager.Id) -What 'manager'
  }

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
    '--arcane-manager', "http://${ArcaneManagerHost}:${managerPort}",
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
  # UserDataBytes is promoted from the config JSON by Merge-ConfigFileParameters
  # into script scope; absent ⇒ $null ⇒ [int] coerces to 0 ⇒ no flag added.
  # Set > 0 in a config to fill the per-tick PLAYER_STATE.user_data with
  # deterministic bytes for the realistic-state benchmark.
  if ([int]$UserDataBytes -gt 0) {
    $swarmArgs += @('--user-data-bytes', [int]$UserDataBytes)
  }
  # InterSpawnDelayMs paces multi-driver runs so aggregate manager /join load
  # stays at single-driver baseline regardless of driver count. Same null →
  # int(0) → no flag pattern as UserDataBytes.
  if ([int]$InterSpawnDelayMs -gt 0) {
    $swarmArgs += @('--inter-spawn-delay-ms', [int]$InterSpawnDelayMs)
  }
  # MaxPlayersPerDriver is the hard safety cap enforced inside the swarm —
  # SET_PLAYERS values above the cap get clamped + a [cap] line goes to
  # stderr. Defense-in-depth alongside the harness-side tier-stop logic.
  if ([int]$MaxPlayersPerDriver -gt 0) {
    $swarmArgs += @('--max-players-per-driver', [int]$MaxPlayersPerDriver)
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
  # Multi-driver: each driver only spawns its own slice ($players), but the
  # cluster's `entities_current` reflects the ACROSS-DRIVERS total. Default
  # 1 keeps single-driver semantics (cluster total == per-driver target).
  $effectiveDriverCount = if ($null -ne $DriverCount -and [int]$DriverCount -gt 0) { [int]$DriverCount } else { 1 }
  $effectiveDriverCap   = if ($null -ne $MaxPlayersPerDriver -and [int]$MaxPlayersPerDriver -gt 0) { [int]$MaxPlayersPerDriver } else { 0 }
  try {
    while ($players -le $ScenarioMaxPlayers) {
      # Driver-cap safety net: refuse to advance to a tier where per-driver
      # players would exceed the cap. Marks the tier INVALID with a clear
      # "would-exceed-driver-cap" reason so the operator knows to provision
      # more drivers rather than trust the next tier's number.
      if ($effectiveDriverCap -gt 0 -and $players -gt $effectiveDriverCap) {
        Write-Host ("  [invalid] tier players=$players would-exceed-driver-cap=$effectiveDriverCap — provision more drivers (current driver_count=$effectiveDriverCount, total=$($players * $effectiveDriverCount))") -ForegroundColor Yellow
        $script:ArcaneRunEvidence += [PSCustomObject]@{
          backend                   = 'arcane'
          num_servers               = $NumServers
          players                   = $players
          tier_valid                = $false
          tier_pass                 = $false
          driver_count              = $effectiveDriverCount
          total_players_aggregate   = $players * $effectiveDriverCount
          ceiling_driver_cap        = $effectiveDriverCap
          most_overloaded           = 'driver-cap'
          most_overloaded_detail    = "per-driver players=$players exceeds MaxPlayersPerDriver=$effectiveDriverCap"
        }
        break
      }
      $clusterTotalTarget = $players * $effectiveDriverCount
      Write-Host "  [Arcane+Spacetime] num_servers=$NumServers testing players=$players (cluster_total=$clusterTotalTarget across $effectiveDriverCount driver(s)) ..." -ForegroundColor Gray
      Send-SwarmCommand -Port $ControlPort -Line "SET_PLAYERS $players"

      # Wait for the swarm's connects to reach the cluster's /stats before we
      # start the measurement window. Starting RESET mid-ramp produces numbers
      # that are dominated by the cluster's still-empty minutes, not steady
      # state. If ramp times out (cluster genuinely can't accept the connects
      # in time), this tier is marked INVALID and the sweep stops.
      $clusterHostsForRamp = @()
      for ($i = 0; $i -lt $NumServers; $i++) {
        $clusterHostsForRamp += if ($ArcaneClusterHosts.Count -eq 0) { '127.0.0.1' } else { $ArcaneClusterHosts[$i] }
      }
      $ramp = Wait-ArcaneClustersReachEntityCount -ClusterHosts $clusterHostsForRamp `
        -ClusterBasePort $ArcaneClusterBasePort -ClusterPortStride $ArcaneClusterPortStride `
        -TargetTotalEntities $clusterTotalTarget -ReachedRatioMin $ArcaneRampReachedRatio `
        -TimeoutSeconds $ArcaneRampTimeoutSeconds -PollIntervalSeconds 2
      Write-Host ("    [ramp] reached={0} target~{1} elapsed={2:N1}s ready={3}" `
          -f $ramp.FinalTotal, $players, $ramp.ElapsedSec, $ramp.Ready) -ForegroundColor DarkGray
      if (-not $ramp.Ready) {
        Write-Host ("    [invalid] tier players=$players RAMP FAILED: $($ramp.Detail)") -ForegroundColor Yellow
        # Take a final snapshot so the failed tier carries the same saturation
        # counters the pass path records, then classify the most-overloaded
        # component. This is how ramp-timeout tiers get attribution.
        $rampSnapshots = @()
        for ($i = 0; $i -lt $clusterHostsForRamp.Count; $i++) {
          $ch = $clusterHostsForRamp[$i]
          $wsPort = $ArcaneClusterBasePort + ($i * $ArcaneClusterPortStride)
          $statsPort = $wsPort + 1
          $json = Get-ArcaneClusterStatsJson -ClusterHost $ch -ClusterStatsPort $statsPort -TimeoutSec 5
          if ($null -eq $json) {
            $rampSnapshots += [PSCustomObject]@{ cluster_index = $i; host = $ch; stats_port = $statsPort; reachable = $false }
          } else {
            $rampSnapshots += [PSCustomObject]@{
              cluster_index           = $i
              host                    = $ch
              stats_port              = $statsPort
              reachable               = $true
              entities_current        = [int64]$json.entities_current
              msgs_player_state       = [int64]$json.msgs_player_state
              msgs_game_action        = [int64]$json.msgs_game_action
              parse_failures          = [int64]$json.parse_failures
              bytes_in                = [int64]$json.bytes_in
              bytes_out               = if ($null -ne $json.bytes_out) { [int64]$json.bytes_out } else { 0 }
              broadcast_lagged_events = if ($null -ne $json.broadcast_lagged_events) { [int64]$json.broadcast_lagged_events } else { 0 }
              broadcast_lagged_frames = if ($null -ne $json.broadcast_lagged_frames) { [int64]$json.broadcast_lagged_frames } else { 0 }
              ws_send_errors          = if ($null -ne $json.ws_send_errors) { [int64]$json.ws_send_errors } else { 0 }
              ws_accepts              = [int64]$json.ws_accepts
              tick                    = [int64]$json.tick
              last_tick_us            = [int64]$json.last_tick_us
            }
          }
        }
        $worstLagged = 0; $worstLaggedIdx = -1; $worstSendErr = 0; $worstSendErrIdx = -1
        foreach ($snap in $rampSnapshots) {
          if (-not $snap.reachable) { continue }
          if ($snap.broadcast_lagged_events -gt $worstLagged) { $worstLagged = $snap.broadcast_lagged_events; $worstLaggedIdx = $snap.cluster_index }
          if ($snap.ws_send_errors -gt $worstSendErr) { $worstSendErr = $snap.ws_send_errors; $worstSendErrIdx = $snap.cluster_index }
        }
        $mostOverloaded = if ($worstLagged -gt 0) {
          "cluster[$worstLaggedIdx]:broadcast_lagged=$worstLagged"
        } elseif ($worstSendErr -gt 0) {
          "cluster[$worstSendErrIdx]:ws_send_errors=$worstSendErr"
        } else {
          'driver_or_network (cluster counters clean; check swarm stderr drv_cpu)'
        }
        Write-Host "    [invalid] ramp-timeout most_overloaded=$mostOverloaded" -ForegroundColor Yellow
        $script:ArcaneRunEvidence += [PSCustomObject]@{
          num_servers               = $NumServers
          players                   = $players
          swarm_pass                = $false
          cluster_entities_observed = $ramp.FinalTotal
          cluster_entities_required = [int][Math]::Ceiling(($players * $effectiveDriverCount) * $ArcaneRampReachedRatio)
          driver_count              = $effectiveDriverCount
          total_players_aggregate   = $players * $effectiveDriverCount
          tier_valid                = $false
          validity_reason           = "ramp timeout: $($ramp.Detail)"
          most_overloaded           = $mostOverloaded
          cluster_stats             = $rampSnapshots
        }
        break
      }

      Send-SwarmCommand -Port $ControlPort -Line 'RESET'
      Start-Sleep -Seconds $DurationSeconds
      Send-SwarmCommand -Port $ControlPort -Line 'REPORT'

      Start-Sleep -Seconds $BetweenIncrementsSeconds
      $txt = ''
      if (Test-Path $stderr) { $txt = Get-Content -Path $stderr -Raw -ErrorAction SilentlyContinue }
      $parsed = Parse-SwarmFinal $txt
      $pass = Test-BenchmarkPass $parsed

      $entitiesObserved = 0
      $statsPollOk = $true
      $statsDetail = @()
      # Full /stats snapshot per cluster, preserved on the evidence record so a
      # post-mortem can attribute a tier failure to a specific saturation mode
      # (broadcast fan-out lag, WS egress errors, inbound message drops, etc.)
      # instead of only the ramp-timeout symptom.
      $clusterStatsSnapshots = @()
      for ($i = 0; $i -lt $NumServers; $i++) {
        $ch = if ($ArcaneClusterHosts.Count -eq 0) { '127.0.0.1' } else { $ArcaneClusterHosts[$i] }
        $wsPort = $ArcaneClusterBasePort + ($i * $ArcaneClusterPortStride)
        $statsPort = $wsPort + 1
        $json = Get-ArcaneClusterStatsJson -ClusterHost $ch -ClusterStatsPort $statsPort -TimeoutSec 5
        if ($null -eq $json) {
          $statsPollOk = $false
          $statsDetail += "cluster[$i] $ch`:$statsPort UNREACHABLE"
          $clusterStatsSnapshots += [PSCustomObject]@{
            cluster_index = $i
            host          = $ch
            stats_port    = $statsPort
            reachable     = $false
          }
        } else {
          $entitiesObserved += [int]$json.entities_current
          $statsDetail += "cluster[$i] $ch`:$statsPort entities=$($json.entities_current) msgs_ps=$($json.msgs_player_state) parse_fail=$($json.parse_failures)"
          $clusterStatsSnapshots += [PSCustomObject]@{
            cluster_index           = $i
            host                    = $ch
            stats_port              = $statsPort
            reachable               = $true
            entities_current        = [int64]$json.entities_current
            msgs_player_state       = [int64]$json.msgs_player_state
            msgs_game_action        = [int64]$json.msgs_game_action
            parse_failures          = [int64]$json.parse_failures
            bytes_in                = [int64]$json.bytes_in
            bytes_out               = if ($null -ne $json.bytes_out) { [int64]$json.bytes_out } else { 0 }
            broadcast_lagged_events = if ($null -ne $json.broadcast_lagged_events) { [int64]$json.broadcast_lagged_events } else { 0 }
            broadcast_lagged_frames = if ($null -ne $json.broadcast_lagged_frames) { [int64]$json.broadcast_lagged_frames } else { 0 }
            ws_send_errors          = if ($null -ne $json.ws_send_errors) { [int64]$json.ws_send_errors } else { 0 }
            ws_accepts              = [int64]$json.ws_accepts
            tick                    = [int64]$json.tick
            last_tick_us            = [int64]$json.last_tick_us
          }
        }
      }
      # Multi-driver: required is against the across-drivers cluster total,
      # not the per-driver tier. Single-driver runs see effectiveDriverCount=1
      # so this collapses to the historical formula.
      $required = [int][Math]::Ceiling(($players * $effectiveDriverCount) * $ArcaneEntityObservedRatioMin)
      $tierValid = $true
      $validityReason = ''
      if (-not $statsPollOk) {
        $tierValid = $false
        $validityReason = "cluster /stats poll failed: $($statsDetail -join '; ')"
      } elseif ($entitiesObserved -lt $required) {
        $tierValid = $false
        $validityReason = "cluster entities_current=$entitiesObserved, required >= $required ($($ArcaneEntityObservedRatioMin * 100)% of cluster_total=$($players * $effectiveDriverCount)). $($statsDetail -join '; ')"
      }
      $observedForLog = if ($statsPollOk) { $entitiesObserved } else { -1 }
      Write-Host ("    [evidence] cluster_entities_observed={0} required>={1} valid={2}" `
          -f $observedForLog, $required, $tierValid) -ForegroundColor DarkGray

      # Name the most-overloaded component so a failing tier points at a
      # specific suspect instead of only reporting the ramp-timeout symptom.
      # Cluster-side signals we can see from the driver are the /stats saturation
      # counters (lag + WS send errors). Driver-side CPU is captured as
      # per-second `[driver]` lines in the swarm stderr log; if the cluster
      # counters are clean, the inference is "driver or network" and the
      # caller is pointed at the swarm stderr for the drv_cpu timeline.
      $mostOverloaded = 'unknown'
      if (-not $tierValid) {
        $worstLagged = 0
        $worstSendErr = 0
        $worstLaggedIdx = -1
        $worstSendErrIdx = -1
        foreach ($snap in $clusterStatsSnapshots) {
          if (-not $snap.reachable) { continue }
          if ($snap.broadcast_lagged_events -gt $worstLagged) {
            $worstLagged = $snap.broadcast_lagged_events
            $worstLaggedIdx = $snap.cluster_index
          }
          if ($snap.ws_send_errors -gt $worstSendErr) {
            $worstSendErr = $snap.ws_send_errors
            $worstSendErrIdx = $snap.cluster_index
          }
        }
        if ($worstLagged -gt 0) {
          $mostOverloaded = "cluster[$worstLaggedIdx]:broadcast_lagged=$worstLagged"
        } elseif ($worstSendErr -gt 0) {
          $mostOverloaded = "cluster[$worstSendErrIdx]:ws_send_errors=$worstSendErr"
        } elseif (-not $statsPollOk) {
          $mostOverloaded = 'cluster:unreachable'
        } else {
          $mostOverloaded = 'driver_or_network (cluster counters clean; check swarm stderr drv_cpu)'
        }
      }

      $script:ArcaneRunEvidence += [PSCustomObject]@{
        num_servers               = $NumServers
        players                   = $players
        driver_count              = $effectiveDriverCount
        total_players_aggregate   = $players * $effectiveDriverCount
        swarm_pass                = [bool]$pass
        cluster_entities_observed = $entitiesObserved
        cluster_entities_required = $required
        tier_valid                = $tierValid
        validity_reason           = $validityReason
        most_overloaded           = $mostOverloaded
        cluster_stats             = $clusterStatsSnapshots
      }
      if (-not $tierValid) {
        Write-Host ("    [invalid] tier players=$players FAILED validity: $validityReason most_overloaded=$mostOverloaded") -ForegroundColor Yellow
        break
      }

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

    if (-not $ArcaneExternalProcesses) {
      foreach ($cid in $clusterPids) { Safe-Kill -ProcessId $cid -What 'cluster' }
      if ($null -ne $procManager) { Safe-Kill -ProcessId $procManager.Id -What 'manager' }
    }
  }

  return $ceiling
}

# ──────────────────────────────────────────────────────────────────────────
# Manifest + repro-command builders. Split per scenario so the repro command
# each one prints only references parameters that exist on its entry point's
# param block — otherwise copy-pasting the command back would produce
# parameter-binding errors against a different entry.
# ──────────────────────────────────────────────────────────────────────────

# Build a reproducible `pwsh -NoProfile -File Run-Benchmark.ps1 ...` command line
# for the run manifest. The command mirrors the actual Run-Benchmark.ps1 param
# block — `-ConfigFile` (which carries every workload knob) plus the optional
# cloud-injected overrides. Workload values (tick rate, burst profile, sweep
# bounds, etc.) deliberately do NOT appear as flags here because
# Run-Benchmark.ps1 does not accept them; they live only in the config file.
# Anyone copy-pasting the emitted command lands on the same configuration that
# produced the current manifest.
function Build-BenchmarkReproCommandLine {
  param(
    [Parameter(Mandatory)][string]$EntryScriptPath,
    [Parameter(Mandatory)][ValidateSet('SpacetimeOnly', 'ArcanePlusSpacetime')][string]$Scenario
  )
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  $parts = [System.Collections.Generic.List[string]]::new()
  [void]$parts.Add('pwsh')
  [void]$parts.Add('-NoProfile')
  [void]$parts.Add('-File')
  [void]$parts.Add((Escape-SingleQuotedPwsh $EntryScriptPath))
  [void]$parts.Add('-ConfigFile')
  [void]$parts.Add((Escape-SingleQuotedPwsh $ConfigFile))

  # Emit a string override only when it has a non-empty value — the empty
  # string is what an unbound PS [string] param looks like after binding.
  $addString = {
    param([string]$Name, $Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return }
    [void]$parts.Add("-$Name")
    [void]$parts.Add((Escape-SingleQuotedPwsh ([string]$Value)))
  }
  # Always emit ints — 0 is a valid value for some (e.g. ArcaneClusterPortStride=0
  # for AwsArcanePerHost). Only called for ints that belong in the repro given
  # the scenario, so there are no 0-from-param-default false positives.
  $addInt = {
    param([string]$Name, $Value)
    if ($null -eq $Value) { return }
    [void]$parts.Add("-$Name")
    [void]$parts.Add(([int]$Value).ToString($inv))
  }

  # Shared overrides — used by both scenarios.
  & $addString 'Environment'   $Environment
  & $addString 'OutDir'        $OutDir
  & $addString 'SpacetimeHost' $SpacetimeHost
  & $addString 'DatabaseName'  $DatabaseName
  & $addString 'SwarmExe'      $SwarmExe

  # Arcane-only overrides. SpacetimeOnly does not use Redis, the Arcane binaries,
  # or the cluster topology — including those flags in a SpacetimeOnly repro
  # command would be noise that a reader has to mentally filter out.
  if ($Scenario -eq 'ArcanePlusSpacetime') {
    & $addString 'RedisHost'          $RedisHost
    & $addInt    'RedisPort'          $RedisPort
    & $addString 'ArcaneManagerExe'   $ArcaneManagerExe
    & $addString 'ArcaneClusterExe'   $ArcaneClusterExe
    if ($ArcaneExternalProcesses) { [void]$parts.Add('-ArcaneExternalProcesses') }
    & $addString 'ArcaneManagerHost'  $ArcaneManagerHost
    & $addInt    'ArcaneManagerPort'  $ArcaneManagerPort
    if ($ArcaneClusterHosts -and $ArcaneClusterHosts.Count -gt 0) {
      [void]$parts.Add('-ArcaneClusterHosts')
      [void]$parts.Add((($ArcaneClusterHosts | ForEach-Object { Escape-SingleQuotedPwsh $_ }) -join ','))
    }
    & $addInt 'ArcaneClusterBasePort'   $ArcaneClusterBasePort
    & $addInt 'ArcaneClusterPortStride' $ArcaneClusterPortStride
  }

  return ($parts -join ' ')
}

function Get-ManifestHostBlock {
  $os = if ($PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.OS) { $PSVersionTable.OS } else { [System.Environment]::OSVersion.VersionString }
  return @{
    machine_name = [System.Environment]::MachineName
    os           = $os
  }
}

function Export-SpacetimeOnlyRunManifest {
  param(
    [string]$ManifestPath,
    [Parameter(Mandatory)][string]$EntryScriptPath,
    [bool]$Succeeded,
    [string]$ErrorMessage,
    [datetime]$StartedUtc,
    [datetime]$FinishedUtc
  )

  $evidence = @(if ($null -ne $script:SpacetimeOnlyRunEvidence) { $script:SpacetimeOnlyRunEvidence } else { @() })
  $invalidTiers = @($evidence | Where-Object { -not $_.tier_valid })
  $runValid = ($invalidTiers.Count -eq 0 -and $evidence.Count -gt 0)
  $validityFailures = @($invalidTiers | ForEach-Object {
      [ordered]@{
        scenario    = 'spacetimedb_only'
        num_servers = 0
        players     = $_.players
        reason      = $_.validity_reason
      }
    })

  $manifest = [ordered]@{
    schema_version    = 5
    scenario          = 'spacetimedb_only'
    run_started_utc   = $StartedUtc.ToString('o')
    run_finished_utc  = $FinishedUtc.ToString('o')
    run_succeeded     = $Succeeded
    run_error         = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
    run_valid         = $runValid
    validity_failures = $validityFailures
    per_tier_evidence = @($evidence)
    harness           = @{
      script              = 'Run-Benchmark.ps1'
      benchmark_repo_root = [string]$BenchmarkRoot
      out_dir             = $OutDir
      pwsh_version        = $PSVersionTable.PSVersion.ToString()
    }
    invocation        = @{
      script_path                   = $EntryScriptPath
      host_powershell_line          = $BenchmarkHostInvocationLine
      config_file                   = $(if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $null } else { (Resolve-Path -LiteralPath $ConfigFile).Path })
      repro_command_pwsh_no_profile = (Build-BenchmarkReproCommandLine -EntryScriptPath $EntryScriptPath -Scenario 'SpacetimeOnly')
    }
    environment_label = (Get-SafeResultsEnvironmentSegment $Environment)
    pass_criteria     = @{
      max_err_rate       = $MaxErrRate
      max_latency_avg_ms = $MaxLatencyMs
    }
    connectivity      = @{
      spacetime_host = $SpacetimeHost
      database_name  = $DatabaseName
    }
    swarm_client      = @{
      simulation_rates = @{
        tick_rate_hz         = $TickRateHz
        tick_rate_cli_flag   = '--tick-rate'
        actions_per_second   = $ActionsPerSec
        actions_cli_flag     = '--aps'
        read_refresh_rate_hz = $ReadRateHz
        read_rate_cli_flag   = '--read-rate'
        movement_mode        = $SwarmMode
        mode_cli_flag        = '--mode'
        burst_profile        = @{
          enabled                  = [bool]$BurstEnabled
          burst_period_secs        = $BurstPeriodSecs
          burst_cohort_percent     = $BurstCohortPercent
          burst_actions_per_player = $BurstActionsPerPlayer
          burst_window_ms          = $BurstWindowMs
          zone_event_period_secs   = $ZoneEventPeriodSecs
          zone_event_window_ms     = $ZoneEventWindowMs
        }
      }
      process_flags = @{
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
      backend = @{
        backend             = 'spacetimedb'
        server_physics      = $true
        server_physics_flag = '--server-physics'
      }
    }
    spacetimedb_only_sweep = @{
      start_players             = $SpacetimeStep
      step_players              = $SpacetimeStep
      max_players               = $SpacetimeMaxPlayers
      duration_seconds_per_tier = $DurationSeconds
    }
    binaries = @{ arcane_swarm = (Get-BinaryInfo -LiteralPath $SwarmExe) }
    host     = (Get-ManifestHostBlock)
    git      = @{
      benchmark_repo_head = (Get-GitHeadOptional -RepoRoot ([string]$BenchmarkRoot))
      arcane_swarm_head   = (Get-GitHeadOptional -RepoRoot (Join-Path ([string]$BenchmarkRoot) 'arcane_swarm'))
    }
  }

  $json = $manifest | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $ManifestPath -Value $json -Encoding utf8
  Write-Host "Run manifest: $ManifestPath" -ForegroundColor DarkGray
}

function Export-ArcaneRunManifest {
  param(
    [string]$ManifestPath,
    [Parameter(Mandatory)][string]$EntryScriptPath,
    [bool]$Succeeded,
    [string]$ErrorMessage,
    [datetime]$StartedUtc,
    [datetime]$FinishedUtc
  )

  $evidence = @(if ($null -ne $script:ArcaneRunEvidence) { $script:ArcaneRunEvidence } else { @() })
  $invalidTiers = @($evidence | Where-Object { -not $_.tier_valid })
  $runValid = ($invalidTiers.Count -eq 0 -and $evidence.Count -gt 0)
  $validityFailures = @($invalidTiers | ForEach-Object {
      [ordered]@{
        scenario    = 'arcane_plus_spacetimedb'
        num_servers = $_.num_servers
        players     = $_.players
        reason      = $_.validity_reason
      }
    })

  $bin = @{
    arcane_swarm   = (Get-BinaryInfo -LiteralPath $SwarmExe)
  }
  if (-not $ArcaneExternalProcesses) {
    $bin.arcane_manager = Get-BinaryInfo -LiteralPath $ArcaneManagerExe
    $bin.arcane_cluster = Get-BinaryInfo -LiteralPath $ArcaneClusterExe
  }

  $manifest = [ordered]@{
    schema_version    = 6
    scenario          = 'arcane_plus_spacetimedb'
    run_started_utc   = $StartedUtc.ToString('o')
    run_finished_utc  = $FinishedUtc.ToString('o')
    run_succeeded     = $Succeeded
    run_error         = $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage })
    run_valid         = $runValid
    validity_failures = $validityFailures
    per_tier_evidence = @($evidence)
    harness           = @{
      script              = 'Run-Benchmark.ps1'
      benchmark_repo_root = [string]$BenchmarkRoot
      out_dir             = $OutDir
      pwsh_version        = $PSVersionTable.PSVersion.ToString()
    }
    invocation        = @{
      script_path                   = $EntryScriptPath
      host_powershell_line          = $BenchmarkHostInvocationLine
      config_file                   = $(if ([string]::IsNullOrWhiteSpace($ConfigFile)) { $null } else { (Resolve-Path -LiteralPath $ConfigFile).Path })
      repro_command_pwsh_no_profile = (Build-BenchmarkReproCommandLine -EntryScriptPath $EntryScriptPath -Scenario 'ArcanePlusSpacetime')
    }
    environment_label = (Get-SafeResultsEnvironmentSegment $Environment)
    pass_criteria     = @{
      max_err_rate       = $MaxErrRate
      max_latency_avg_ms = $MaxLatencyMs
    }
    connectivity      = @{
      spacetime_host = $SpacetimeHost
      database_name  = $DatabaseName
      redis_host     = $RedisHost
      redis_port     = $RedisPort
    }
    arcane_topology   = @{
      external_processes              = [bool]$ArcaneExternalProcesses
      manager_host                    = $ArcaneManagerHost
      manager_port                    = $ArcaneManagerPort
      cluster_hosts                   = $(if ($ArcaneClusterHosts.Count -gt 0) { @($ArcaneClusterHosts) } else { $null })
      cluster_hosts_implicit_loopback = ($ArcaneClusterHosts.Count -eq 0)
      cluster_base_ws_port            = $ArcaneClusterBasePort
      cluster_port_stride             = $ArcaneClusterPortStride
    }
    swarm_client      = @{
      simulation_rates = @{
        tick_rate_hz         = $TickRateHz
        tick_rate_cli_flag   = '--tick-rate'
        actions_per_second   = $ActionsPerSec
        actions_cli_flag     = '--aps'
        read_refresh_rate_hz = $ReadRateHz
        read_rate_cli_flag   = '--read-rate'
        movement_mode        = $SwarmMode
        mode_cli_flag        = '--mode'
        burst_profile        = @{
          enabled                  = [bool]$BurstEnabled
          burst_period_secs        = $BurstPeriodSecs
          burst_cohort_percent     = $BurstCohortPercent
          burst_actions_per_player = $BurstActionsPerPlayer
          burst_window_ms          = $BurstWindowMs
          zone_event_period_secs   = $ZoneEventPeriodSecs
          zone_event_window_ms     = $ZoneEventWindowMs
        }
      }
      process_flags = @{
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
      backend = @{
        backend                 = 'arcane'
        arcane_manager_base_url = "http://${ArcaneManagerHost}:${ArcaneManagerPort}"
        arcane_manager_cli_flag = '--arcane-manager'
      }
      payload = @{
        # Bytes per PLAYER_STATE.user_data sent to the cluster each tick.
        # 0 = lean baseline (the historical 7,250-player ceiling). > 0 enables
        # the realistic-state benchmark (deterministic xorshift bytes via
        # arcane_swarm protocol::fill_pseudo_user_data).
        user_data_bytes = [int]$UserDataBytes
        cli_flag        = '--user-data-bytes'
      }
    }
    arcane_persist    = @{
      spacetimedb_persist_hz         = $SpacetimePersistHz
      spacetimedb_persist_batch_size = $PersistBatchSize
    }
    arcane_plus_spacetimedb_sweep = @{
      enabled                   = $true
      cluster_counts            = @($ArcaneClusterCounts)
      start_players             = $ArcaneCeilingStartPlayers
      step_players              = $ArcaneCeilingStep
      max_players               = $ArcaneCeilingMaxPlayers
      duration_seconds_per_tier = $DurationSeconds
    }
    binaries = $bin
    host     = (Get-ManifestHostBlock)
    git      = @{
      benchmark_repo_head = (Get-GitHeadOptional -RepoRoot ([string]$BenchmarkRoot))
      arcane_swarm_head   = (Get-GitHeadOptional -RepoRoot (Join-Path ([string]$BenchmarkRoot) 'arcane_swarm'))
    }
  }

  $json = $manifest | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath $ManifestPath -Value $json -Encoding utf8
  Write-Host "Run manifest: $ManifestPath" -ForegroundColor DarkGray
}

# ──────────────────────────────────────────────────────────────────────────
# Scenario orchestration wrappers. Run-Benchmark.ps1 reads BenchmarkMode from
# the config and dispatches to one of these. Each wrapper owns the full scenario
# flow: precondition checks → resolve binary paths → run scenario → write CSV →
# write manifest (always, even on throw). All inputs are read from script-scope
# variables populated by the entry script (param binding + Merge-ConfigFileParameters
# + CLI overrides).
# ──────────────────────────────────────────────────────────────────────────

# Guard: throw early (before any scenario side-effect) if a variable the scenario
# runner expects to read is not set in script scope. This catches typos in the
# config file and parameters the author forgot to move from the old param block.
# Treats $null and empty-or-whitespace strings as "missing"; 0 / $false are valid.
function Assert-RequiredScriptVariablesSet {
  param(
    [Parameter(Mandatory)][string]$Scenario,
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string[]]$Fields
  )
  $missing = @()
  foreach ($f in $Fields) {
    $v = Get-Variable -Name $f -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $v)              { $missing += $f; continue }
    if ($null -eq $v.Value)        { $missing += $f; continue }
    if ($v.Value -is [string] -and [string]::IsNullOrWhiteSpace($v.Value)) { $missing += $f }
  }
  if ($missing.Count -gt 0) {
    throw @"
Scenario '$Scenario' requires these fields but they are missing after loading '$ConfigFile' (and after any CLI overrides were applied): $($missing -join ', ').
Set them in the config JSON. Inline descriptions for each field live in the shipped configs/*.json.
"@
  }
}

# Apply hardcoded fallbacks for the validity-gate tuning knobs when the config
# does not provide them. These control the ramp-up gate (how long to wait for
# the server to reflect swarm connections before starting measurement) and the
# minimum observed-entity ratio before a tier counts as valid. Changing them
# invalidates cross-run comparisons, so configs rarely set them — but can.
function Set-BenchmarkValidityGateFallbacks {
  param([switch]$IncludeArcaneOnly)
  if ($null -eq $ArcaneRampTimeoutSeconds) {
    Set-Variable -Name 'ArcaneRampTimeoutSeconds' -Value 180 -Scope Script
  }
  if ($null -eq $ArcaneRampReachedRatio) {
    Set-Variable -Name 'ArcaneRampReachedRatio' -Value 0.95 -Scope Script
  }
  if ($IncludeArcaneOnly -and $null -eq $ArcaneEntityObservedRatioMin) {
    Set-Variable -Name 'ArcaneEntityObservedRatioMin' -Value 0.5 -Scope Script
  }
}

function Resolve-BenchmarkRepoPaths {
  $suffix = Get-ExeSuffix
  Set-Variable -Name 'BenchmarkRoot' -Value (Resolve-Path (Join-Path $PSScriptRoot '..')) -Scope Script

  $swarmRoot = [System.IO.Path]::Combine($BenchmarkRoot, 'arcane_swarm')
  if (-not (Test-Path -LiteralPath $swarmRoot)) { $swarmRoot = [string]$BenchmarkRoot }
  Set-Variable -Name 'SwarmWorkspaceRoot' -Value $swarmRoot -Scope Script

  $arcaneRepo = [System.IO.Path]::Combine($BenchmarkRoot, 'arcane')
  if (-not (Test-Path -LiteralPath $arcaneRepo)) { $arcaneRepo = [string]$BenchmarkRoot }
  Set-Variable -Name 'ArcaneRepo' -Value $arcaneRepo -Scope Script

  if ([string]::IsNullOrWhiteSpace($SwarmExe)) {
    Set-Variable -Name 'SwarmExe' -Value ([System.IO.Path]::Combine($swarmRoot, 'target', 'release', "arcane-swarm$suffix")) -Scope Script
  }
  if ([string]::IsNullOrWhiteSpace($ArcaneManagerExe)) {
    Set-Variable -Name 'ArcaneManagerExe' -Value ([System.IO.Path]::Combine($arcaneRepo, 'target', 'release', "arcane-manager$suffix")) -Scope Script
  }
  $benchmarkClusterRoot = [System.IO.Path]::Combine($BenchmarkRoot, 'crates', 'benchmark-cluster')
  if ([string]::IsNullOrWhiteSpace($ArcaneClusterExe)) {
    Set-Variable -Name 'ArcaneClusterExe' -Value ([System.IO.Path]::Combine($benchmarkClusterRoot, 'target', 'release', "benchmark-cluster$suffix")) -Scope Script
  }
}

function Resolve-BenchmarkOutDir {
  if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $envSeg = Get-SafeResultsEnvironmentSegment $Environment
    Set-Variable -Name 'OutDir' -Value (Join-Path $BenchmarkRoot (Join-Path 'results' (Join-Path 'runs' (Join-Path $envSeg $runStamp)))) -Scope Script
  }
  $null = New-Item -ItemType Directory -Path $OutDir -Force
}

function Invoke-SpacetimeOnlyScenarioRun {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EntryScriptPath)

  Set-Variable -Name 'SpacetimeOnlyRunEvidence' -Value @() -Scope Script

  # Validity-gate knobs default to hardcoded fallbacks if the config didn't
  # override them — these are internals users rarely touch.
  Set-BenchmarkValidityGateFallbacks

  # Everything else must be present in the config (or supplied as a CLI
  # override). Throw a precise error BEFORE running any scenario side-effects
  # so a typo in the config fails fast instead of producing a bogus run.
  Assert-RequiredScriptVariablesSet -Scenario 'SpacetimeOnly' -ConfigFile $ConfigFile -Fields @(
    # Connectivity
    'SpacetimeHost', 'DatabaseName',
    # Swarm client workload (canonical)
    'TickRateHz', 'ActionsPerSec', 'ReadRateHz', 'SwarmMode',
    'BetweenIncrementsSeconds',
    # Sweep bounds
    'SpacetimeStep', 'SpacetimeMaxPlayers', 'DurationSeconds',
    # Pass criteria
    'MaxErrRate', 'MaxLatencyMs',
    # Burst / zone event profile (canonical)
    'BurstEnabled', 'BurstPeriodSecs', 'BurstCohortPercent',
    'BurstActionsPerPlayer', 'BurstWindowMs',
    'ZoneEventPeriodSecs', 'ZoneEventWindowMs'
  )

  Resolve-BenchmarkRepoPaths
  Resolve-BenchmarkOutDir

  $runStartedUtc = [datetime]::UtcNow
  $runSucceeded = $false
  $runErr = $null

  try {
    Assert-SpacetimeReachable
    Assert-SwarmBinary

    Write-Host "`n=== Run-Benchmark: SpacetimeOnly ===" -ForegroundColor Cyan
    Write-Host "Environment (results subfolder): $(Get-SafeResultsEnvironmentSegment $Environment)" -ForegroundColor Gray
    Write-Host "Base OutDir: $OutDir" -ForegroundColor Gray

    $spOnlyDir = Join-Path $OutDir 'spacetimedb_only'
    $null = New-Item -ItemType Directory -Path $spOnlyDir -Force

    $spCeiling = Run-Scenario-SpacetimeOnly -ScenarioOutDir $spOnlyDir -ControlPort 9300 `
      -ScenarioStartPlayers $SpacetimeStep -ScenarioStepPlayers $SpacetimeStep -ScenarioMaxPlayers $SpacetimeMaxPlayers

    $results = @([PSCustomObject]@{ backend = 'spacetimedb_only'; num_servers = 0; ceiling_players = $spCeiling })
    $csv = Join-Path $spOnlyDir 'benchmark_scenarios_results.csv'
    $results | Export-Csv -Path $csv -NoTypeInformation
    Write-Host "Results written to: $csv" -ForegroundColor Green

    $spInvalid = @($script:SpacetimeOnlyRunEvidence | Where-Object { -not $_.tier_valid })
    if ($spInvalid.Count -gt 0) {
      Write-Host "`n!!! INVALID SPACETIMEDB-ONLY RUN !!! $($spInvalid.Count) tier(s) failed server-side evidence check." -ForegroundColor Red
      foreach ($t in $spInvalid) { Write-Host ("  - players=$($t.players): $($t.validity_reason)") -ForegroundColor Red }
      Write-Host '  Ceiling numbers below are swarm-side only and MUST NOT be treated as a saturation measurement.' -ForegroundColor Red
    }

    Write-Host "`n--- Ceiling summary ---" -ForegroundColor Cyan
    $spLabel = if ($null -eq $spCeiling) { 'none (no passing tier in this sweep)' } else { "$spCeiling" }
    $spSuffix = if ($spInvalid.Count -gt 0) { ' [INVALID — see warning above]' } else { '' }
    Write-Host "  SpacetimeDB only: ceiling = $spLabel players$spSuffix"
    Write-Host '---' -ForegroundColor Cyan

    $runSucceeded = $true
  } catch {
    $runErr = $_.Exception.Message
    throw
  } finally {
    $manifestPath = Join-Path $OutDir 'benchmark_run_manifest.json'
    Export-SpacetimeOnlyRunManifest `
      -ManifestPath $manifestPath `
      -EntryScriptPath $EntryScriptPath `
      -Succeeded $runSucceeded `
      -ErrorMessage $runErr `
      -StartedUtc $runStartedUtc `
      -FinishedUtc ([datetime]::UtcNow)
  }
}

function Invoke-ArcaneScenarioRun {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EntryScriptPath)

  Set-Variable -Name 'ArcaneRunEvidence' -Value @() -Scope Script

  # Validity-gate knobs default to hardcoded fallbacks when config doesn't
  # override them; the Arcane scenario adds the cluster entity-observed gate.
  Set-BenchmarkValidityGateFallbacks -IncludeArcaneOnly

  if ($null -eq $ArcaneClusterCounts -or $ArcaneClusterCounts.Count -eq 0) {
    throw "Config set BenchmarkMode=ArcanePlusSpacetime but did not define ArcaneClusterCount. Pick a config under configs/ whose ArcaneClusterCount matches the setup you provisioned."
  }

  Assert-RequiredScriptVariablesSet -Scenario 'ArcanePlusSpacetime' -ConfigFile $ConfigFile -Fields @(
    # Connectivity (cloud drivers override RedisHost / SpacetimeHost at runtime)
    'SpacetimeHost', 'DatabaseName', 'RedisHost', 'RedisPort',
    # Arcane topology (cloud drivers override all of these)
    'ArcaneManagerHost', 'ArcaneManagerPort',
    'ArcaneClusterBasePort', 'ArcaneClusterPortStride',
    # Swarm client workload (canonical)
    'TickRateHz', 'ActionsPerSec', 'ReadRateHz', 'SwarmMode',
    'BetweenIncrementsSeconds',
    # Sweep bounds
    'ArcaneCeilingStartPlayers', 'ArcaneCeilingStep', 'ArcaneCeilingMaxPlayers',
    'DurationSeconds',
    # Persistence
    'SpacetimePersistHz', 'PersistBatchSize',
    # Pass criteria
    'MaxErrRate', 'MaxLatencyMs',
    # Burst / zone event profile (canonical)
    'BurstEnabled', 'BurstPeriodSecs', 'BurstCohortPercent',
    'BurstActionsPerPlayer', 'BurstWindowMs',
    'ZoneEventPeriodSecs', 'ZoneEventWindowMs'
  )

  Resolve-BenchmarkRepoPaths
  Resolve-BenchmarkOutDir

  $runStartedUtc = [datetime]::UtcNow
  $runSucceeded = $false
  $runErr = $null

  try {
    Assert-SpacetimeReachable
    Assert-SwarmBinary
    Assert-RedisReachable
    Assert-ArcaneTopologyForSweep -ArcaneClusterCounts $ArcaneClusterCounts `
      -ArcaneClusterHosts $ArcaneClusterHosts -ArcaneClusterPortStride $ArcaneClusterPortStride `
      -ArcaneExternalProcesses ([bool]$ArcaneExternalProcesses) -ArcaneManagerHost $ArcaneManagerHost
    Assert-ArcaneBinaries

    Write-Host "`n=== Run-Benchmark: ArcanePlusSpacetime ===" -ForegroundColor Cyan
    Write-Host "Environment (results subfolder): $(Get-SafeResultsEnvironmentSegment $Environment)" -ForegroundColor Gray
    Write-Host "Base OutDir: $OutDir" -ForegroundColor Gray

    $arcDir = Join-Path $OutDir 'arcane_plus_spacetimedb'
    $null = New-Item -ItemType Directory -Path $arcDir -Force

    $results = @()
    foreach ($n in $ArcaneClusterCounts) {
      $controlPort = 9400 + $n
      $ceiling = Run-Scenario-Arcane -ScenarioOutDir $arcDir -NumServers $n -ControlPort $controlPort `
        -ScenarioStartPlayers $ArcaneCeilingStartPlayers -ScenarioStepPlayers $ArcaneCeilingStep -ScenarioMaxPlayers $ArcaneCeilingMaxPlayers
      $results += [PSCustomObject]@{ backend = 'arcane_plus_spacetimedb'; num_servers = $n; ceiling_players = $ceiling }
    }

    $csv = Join-Path $arcDir 'benchmark_scenarios_results.csv'
    $results | Export-Csv -Path $csv -NoTypeInformation
    Write-Host "Results written to: $csv" -ForegroundColor Green

    $arcaneInvalid = @($script:ArcaneRunEvidence | Where-Object { -not $_.tier_valid })
    if ($arcaneInvalid.Count -gt 0) {
      Write-Host "`n!!! INVALID ARCANE RUN !!! $($arcaneInvalid.Count) tier(s) failed server-side evidence check." -ForegroundColor Red
      foreach ($t in $arcaneInvalid) {
        $mo = if ($t.PSObject.Properties['most_overloaded']) { " most_overloaded=$($t.most_overloaded)" } else { '' }
        Write-Host ("  - num_servers=$($t.num_servers) players=$($t.players): $($t.validity_reason)$mo") -ForegroundColor Red
      }
      Write-Host '  Ceiling numbers below are swarm-side only and MUST NOT be treated as a saturation measurement.' -ForegroundColor Red
    }

    Write-Host "`n--- Ceiling summary ---" -ForegroundColor Cyan
    foreach ($r in ($results | Sort-Object { $_.num_servers })) {
      $suffixLabel = if ($arcaneInvalid.Count -gt 0) { ' [INVALID — see warning above]' } else { '' }
      $ceilText = if ($null -eq $r.ceiling_players) { 'none (no passing tier)' } else { "$($r.ceiling_players)" }
      Write-Host "  Arcane + SpacetimeDB ($($r.num_servers) cluster(s)): ceiling = $ceilText players$suffixLabel"
    }
    Write-Host '---' -ForegroundColor Cyan

    $runSucceeded = $true
  } catch {
    $runErr = $_.Exception.Message
    throw
  } finally {
    $manifestPath = Join-Path $OutDir 'benchmark_run_manifest.json'
    Export-ArcaneRunManifest `
      -ManifestPath $manifestPath `
      -EntryScriptPath $EntryScriptPath `
      -Succeeded $runSucceeded `
      -ErrorMessage $runErr `
      -StartedUtc $runStartedUtc `
      -FinishedUtc ([datetime]::UtcNow)
    if (-not $ArcaneExternalProcesses) { Stop-ArcaneProcesses }
  }
}
