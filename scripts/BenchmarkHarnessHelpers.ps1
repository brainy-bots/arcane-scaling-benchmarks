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
