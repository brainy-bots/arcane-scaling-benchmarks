<#
.SYNOPSIS
  Run the Arcane scaling benchmark. The only required parameter is -ConfigFile.

.DESCRIPTION
  ## What this script does, in one paragraph

  It drives a benchmark against an ALREADY-RUNNING server fleet (SpacetimeDB on
  its own, or SpacetimeDB + Redis + Arcane manager + N Arcane clusters). It
  launches arcane-swarm — the load generator — and walks it through a series of
  player-count tiers, one at a time. At each tier it waits for the swarm to
  connect, waits for the server to reflect those connections (the "ramp-up"
  validity gate), measures for DurationSeconds, then decides pass or fail. The
  highest tier that passed is the ceiling. Output is a CSV plus a JSON manifest
  capturing every effective parameter so someone else can reproduce the run.

  This script does NOT build binaries, pull container images, or publish
  SpacetimeDB modules. Those are separate steps — see REPRODUCIBILITY.md for
  the full workflow (local) and infra/aws/ (AWS).

  ## How to run it (locally)

    ./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/spacetimedb_only.json
    ./scripts/Run-Benchmark.ps1 -ConfigFile ./configs/arcane_plus_spacetimedb.clusters_2.json

  The scenario is picked by the config's BenchmarkMode field (`SpacetimeOnly`
  or `ArcanePlusSpacetime`). Every workload parameter — tick rate, burst
  profile, duration, sweep start/step/max, cluster count, pass criteria — lives
  in the config JSON, documented inline. One config per setup; do NOT edit
  values between runs — pick a different config file instead.

  ## How it runs on AWS

  You do not invoke this script yourself on AWS. Run-Benchmark-Aws.ps1 sends
  the container command `docker run ... run-benchmark` over SSM to the driver
  EC2 instance. Inside the container, docker/run-benchmark.sh shells out to
  this script with the cloud-injected overrides (SpacetimeDB IP, Redis IP,
  Arcane manager IP, per-cluster IPs) appended to the command line.

  ## Why there are CLI overrides at all

  The cloud IPs are produced by Terraform outputs at provisioning time. They
  cannot live in the config file because they only exist at runtime. So the
  AWS driver passes them as CLI arguments and this script OVERLAYS them on
  top of whatever the config said. Local users don't pass any of these — the
  config's defaults (loopback, known ports) are fine.

  ## Outputs

  results/runs/<Environment>/<yyyyMMdd_HHmmss>/
    benchmark_run_manifest.json        effective parameters, pass criteria, binary hashes,
                                       host+git metadata, repro command (copy-pasteable)
    spacetimedb_only/                  (present when BenchmarkMode=SpacetimeOnly)
      benchmark_scenarios_results.csv  one row per backend/cluster config; ceiling_players
      stderr/*.log                     captured stdout/stderr from the swarm
    arcane_plus_spacetimedb/           (present when BenchmarkMode=ArcanePlusSpacetime)
      benchmark_scenarios_results.csv
      stderr/*.log                     plus cluster and manager logs
#>

param(
  # REQUIRED. Path to a config file under configs/ (or anywhere readable). The
  # config carries BenchmarkMode + every workload parameter; see the inline
  # comments in the shipped configs/*.json for what each field does.
  [Parameter(Mandatory)]
  [string] $ConfigFile,

  # ── Cloud-injected overrides (optional; leave unset for local runs) ────────
  #
  # These are the values the AWS SSM driver needs to inject at run time — VPC
  # IPs and per-environment labels that cannot live in a baked-into-the-image
  # config. Any value you pass here WINS over the same-named key in the config
  # file (see the $cliOverrides dance below for how we preserve that).
  #
  # For LOCAL runs you do not pass any of these. Everything defaults to
  # loopback and the binaries land where the build step puts them.

  # Label that groups runs under results/runs/<Environment>/. Defaults from
  # config; cloud drivers pass "AwsSpacetimeOnly" or "AwsArcanePerHost".
  [string]   $Environment,

  # Override the results directory entirely. Cloud drivers mount a tmpfs and
  # pass its path so the container can emit results somewhere it will later
  # aws-s3-sync. If unset, a timestamped folder under results/runs/ is used.
  [string]   $OutDir,

  # SpacetimeDB HTTP endpoint. Local default: http://127.0.0.1:3000. Cloud:
  # http://<vpc-private-ip>:3000.
  [string]   $SpacetimeHost,
  # SpacetimeDB database name. Almost always "arcane".
  [string]   $DatabaseName,

  # Redis endpoint (only used when BenchmarkMode=ArcanePlusSpacetime — Arcane
  # clusters use Redis pub/sub for entity replication). Local default:
  # 127.0.0.1:6379. Cloud: the Redis VPC private IP + 6379.
  [string]   $RedisHost,
  [int]      $RedisPort,

  # Paths to the three Rust binaries the harness shells out to. Locally these
  # point inside arcane_swarm/target/release/, arcane/target/release/, and
  # crates/benchmark-cluster/target/release/. Inside the benchmark container
  # they all live on /usr/local/bin, and docker/run-benchmark.sh passes those
  # absolute paths here.
  [string]   $SwarmExe,
  [string]   $ArcaneManagerExe,
  [string]   $ArcaneClusterExe,

  # ── Arcane topology (only for ArcanePlusSpacetime; cloud-only in practice) ──
  #
  # Local Arcane runs start manager + cluster processes on localhost themselves.
  # Cloud runs can't — those processes are on separate EC2 instances, started
  # by the topology's RemoteBenchmark.ps1 before the driver fires. In that case
  # pass -ArcaneExternalProcesses to tell the harness NOT to spawn them
  # locally, and pass the VPC IPs and ports where they actually live.

  [switch]   $ArcaneExternalProcesses,
  [string]   $ArcaneManagerHost,
  [int]      $ArcaneManagerPort,
  # Array of cluster WS hosts, one per cluster. Index i corresponds to
  # cluster i. Cloud AwsArcanePerHost topology passes one entry per EC2
  # cluster instance.
  [string[]] $ArcaneClusterHosts,
  # Base WebSocket port + stride. Local default: 8090 + i*1 (clusters on the
  # same host need different ports). Cloud AwsArcanePerHost: every cluster
  # listens on 8090 on its own host, so stride is 0.
  [int]      $ArcaneClusterBasePort,
  [int]      $ArcaneClusterPortStride
)

$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────────
#  PRECEDENCE: config file first, then CLI overrides on top.
# ──────────────────────────────────────────────────────────────────────────────
# Why not the other way around? Because the config file describes the SETUP
# (what's being measured) and the CLI flags describe RUNTIME INJECTION (where
# things live right now). If we let the config file overwrite CLI values, the
# cloud driver's injected IPs would be lost and the script would try to reach
# SpacetimeDB at 127.0.0.1:3000 on the driver EC2 — wrong.
#
# PowerShell binds params before the script body runs, so by the time we are
# here $SpacetimeHost / $RedisHost / etc. already hold whatever the caller
# passed (or the param-block default, which is an empty string / zero for
# detection). $PSBoundParameters tells us WHICH ones the user actually passed,
# as opposed to which ones defaulted. We snapshot those now, then load the
# config (which can overwrite everything including CLI-provided values), then
# re-apply the CLI snapshot so CLI wins.
$cliOverrides = @{}
foreach ($k in $PSBoundParameters.Keys) {
  if ($k -eq 'ConfigFile') { continue }   # ConfigFile is the one thing we never want to overlay
  $cliOverrides[$k] = $PSBoundParameters[$k]
}

# Dot-source the shared helpers. This gives us:
#   - Merge-ConfigFileParameters (reads the config JSONC and promotes every
#     recognized key to script scope so the scenario runners can see it)
#   - Invoke-SpacetimeOnlyScenarioRun / Invoke-ArcaneScenarioRun (the two
#     orchestration wrappers — see BenchmarkHarnessHelpers.ps1 for their flow)
#   - Every scenario/precondition/TCP/manifest helper the wrappers call
# The dot-source imports these into THIS script's scope so Set-Variable
# -Scope Script (used by Merge-ConfigFileParameters) writes somewhere the
# wrappers can then read via dynamic scope lookup.
. (Join-Path $PSScriptRoot 'BenchmarkHarnessHelpers.ps1')

# Parse the config and promote every recognized key to this script's scope.
# If the config has an unknown key, this throws — better than silently ignoring
# a typo in a setup that's supposed to be reproducible.
Merge-ConfigFileParameters -Path $ConfigFile

# Re-apply CLI overrides on top of the config. CLI wins.
foreach ($k in $cliOverrides.Keys) {
  Set-Variable -Name $k -Value $cliOverrides[$k] -Scope Script
}

# Capture the original invocation line for the manifest, when PowerShell
# populates it. Often empty when invoked via `pwsh -File` (which is how the
# cloud shell wrapper drives us), in which case the manifest's repro_command
# field is the more useful thing to look at.
$BenchmarkHostInvocationLine = $null
if ($MyInvocation.Line -and $MyInvocation.Line.Trim()) {
  $BenchmarkHostInvocationLine = $MyInvocation.Line.Trim()
}

# ──────────────────────────────────────────────────────────────────────────────
#  DISPATCH. BenchmarkMode must be set; it tells us which scenario to run.
# ──────────────────────────────────────────────────────────────────────────────
# Each wrapper owns the full scenario: precondition checks (is SpacetimeDB
# actually reachable? does the swarm binary exist?), the player-tier sweep,
# the per-tier validity gate (did the server actually see the connections?),
# CSV output, and manifest emission. Manifests are written in a `finally`
# block so a run that throws mid-sweep still leaves evidence behind.
# See Invoke-SpacetimeOnlyScenarioRun / Invoke-ArcaneScenarioRun in
# BenchmarkHarnessHelpers.ps1 for the line-by-line flow.

if ([string]::IsNullOrWhiteSpace($BenchmarkMode)) {
  throw "Config '$ConfigFile' is missing required field 'BenchmarkMode'. Set it to 'SpacetimeOnly' or 'ArcanePlusSpacetime' in the config JSON, or pick a different config from configs/."
}

switch ($BenchmarkMode) {
  'SpacetimeOnly'       { Invoke-SpacetimeOnlyScenarioRun -EntryScriptPath $PSCommandPath }
  'ArcanePlusSpacetime' { Invoke-ArcaneScenarioRun       -EntryScriptPath $PSCommandPath }
  default { throw "Config '$ConfigFile' has unsupported BenchmarkMode '$BenchmarkMode'. Valid values: SpacetimeOnly, ArcanePlusSpacetime." }
}

Write-Host "`nDone." -ForegroundColor Green
