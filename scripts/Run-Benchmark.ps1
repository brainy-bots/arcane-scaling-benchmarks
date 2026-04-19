<#
.SYNOPSIS
  Run the Arcane scaling benchmark. The only required parameter is -ConfigFile.

.DESCRIPTION
  The benchmark has one entry point. You pick which scenario to run by picking the config file:

    ./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/spacetimedb_only.json
    ./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/arcane_plus_spacetimedb.clusters_2.json

  Every workload parameter — tick rate, burst profile, duration, sweep start/step/max, cluster
  count, pass criteria — lives in the config JSON. The config's **BenchmarkMode** field
  (`SpacetimeOnly` or `ArcanePlusSpacetime`) selects which scenario is run. One config file per
  setup; do not edit values between runs.

  The remaining parameters are **cloud-injected overrides**. AWS driver scripts (see
  infra/aws/topologies/*/RemoteBenchmark.ps1) inject values that only exist at runtime — the
  SpacetimeDB VPC IP, the Redis VPC IP, the Arcane manager IP, the cluster IPs. For local runs
  you don't need any of them; -ConfigFile is enough.

  This script does not build binaries, pull container images, or publish SpacetimeDB modules —
  that's handled by the scripts in scripts/ (local) and the Dockerfile + topology scripts (cloud).

  Outputs land in results/runs/<Environment>/<yyyyMMdd_HHmmss>/ (the manifest, plus a
  spacetimedb_only/ or arcane_plus_spacetimedb/ subfolder with the CSV + stderr logs).
#>

param(
  [Parameter(Mandatory)]
  [string] $ConfigFile,

  # ── Cloud-injected overrides (optional; CLI wins over the same-named config keys) ──
  [string]   $Environment,
  [string]   $OutDir,
  [string]   $SpacetimeHost,
  [string]   $DatabaseName,
  [string]   $RedisHost,
  [int]      $RedisPort,
  [string]   $SwarmExe,
  [string]   $ArcaneManagerExe,
  [string]   $ArcaneClusterExe,
  [switch]   $ArcaneExternalProcesses,
  [string]   $ArcaneManagerHost,
  [int]      $ArcaneManagerPort,
  [string[]] $ArcaneClusterHosts,
  [int]      $ArcaneClusterBasePort,
  [int]      $ArcaneClusterPortStride
)

$ErrorActionPreference = 'Stop'

# Capture which overrides the user actually passed on the command line BEFORE we
# load the config. We have to re-apply them after Merge-ConfigFileParameters so
# CLI wins over config for these (and only these) fields.
$cliOverrides = @{}
foreach ($k in $PSBoundParameters.Keys) {
  if ($k -eq 'ConfigFile') { continue }
  $cliOverrides[$k] = $PSBoundParameters[$k]
}

. (Join-Path $PSScriptRoot 'BenchmarkHarnessHelpers.ps1')

Merge-ConfigFileParameters -Path $ConfigFile

foreach ($k in $cliOverrides.Keys) {
  Set-Variable -Name $k -Value $cliOverrides[$k] -Scope Script
}

$BenchmarkHostInvocationLine = $null
if ($MyInvocation.Line -and $MyInvocation.Line.Trim()) {
  $BenchmarkHostInvocationLine = $MyInvocation.Line.Trim()
}

if ([string]::IsNullOrWhiteSpace($BenchmarkMode)) {
  throw "Config '$ConfigFile' is missing required field 'BenchmarkMode'. Set it to 'SpacetimeOnly' or 'ArcanePlusSpacetime' in the config JSON, or pick a different config from configs/."
}

switch ($BenchmarkMode) {
  'SpacetimeOnly'       { Invoke-SpacetimeOnlyScenarioRun -EntryScriptPath $PSCommandPath }
  'ArcanePlusSpacetime' { Invoke-ArcaneScenarioRun       -EntryScriptPath $PSCommandPath }
  default { throw "Config '$ConfigFile' has unsupported BenchmarkMode '$BenchmarkMode'. Valid values: SpacetimeOnly, ArcanePlusSpacetime." }
}

Write-Host "`nDone." -ForegroundColor Green
