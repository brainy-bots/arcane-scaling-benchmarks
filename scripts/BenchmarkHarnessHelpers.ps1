# Shared helpers for Run-Benchmark.ps1 (dot-source from that script so Merge-ConfigFileParameters
# can Set-Variable -Scope Script into the caller's script scope).

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

# Sum of entities observed across all provided cluster hosts, using the /stats
# endpoint. Returns $null when any cluster failed to respond — don't treat a
# failed poll as "0 entities", since that's also invalid.
function Get-ArcaneClustersEntitiesTotal {
  param(
    [Parameter(Mandatory)][string[]]$ClusterHosts,
    [int]$ClusterStatsPort = 8091,
    [int]$TimeoutSec = 5
  )
  $sum = 0
  foreach ($h in $ClusterHosts) {
    $s = Get-ArcaneClusterStatsJson -ClusterHost $h -ClusterStatsPort $ClusterStatsPort -TimeoutSec $TimeoutSec
    if ($null -eq $s) { return $null }
    $sum += [int]$s.entities_current
  }
  return $sum
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
  $body = "SELECT COUNT(*) FROM $Table"
  try {
    $resp = Invoke-WebRequest -Uri $uri -Method Post -Body $body -ContentType 'text/plain' `
      -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    # Try the structured shape first: array with .rows = [[N]].
    $parsed = $null
    try { $parsed = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch {}
    if ($parsed) {
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
    }
    # Fall back to grabbing the first integer in the body.
    if ($resp.Content -match '(\d+)') { return [int64]$Matches[1] }
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
    [Parameter(Mandatory)][bool]$FindArcaneCeiling,
    $ArcaneClusterCounts,
    [AllowEmptyCollection()][string[]]$ArcaneClusterHosts,
    [int]$ArcaneClusterPortStride,
    [bool]$ArcaneExternalProcesses,
    [string]$ArcaneManagerHost
  )

  if (-not $FindArcaneCeiling) { return }
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
  $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $cfg) { return }

  $supported = @(
    'SpacetimeStep',
    'SpacetimeMaxPlayers',
    'DurationSeconds',
    'FindArcaneCeiling',
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
    # Metadata keys — consumed by the AWS run validator / docs, not by Run-Benchmark.ps1. Accepted here so the
    # same config file works for both the local harness and the AWS-side topology validator.
    'BenchmarkMode',
    'SpacetimeModule',
    'PhysicsEngine',
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
}
