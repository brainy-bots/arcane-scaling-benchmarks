#!/bin/bash
# Driver role. Runs scripts/Run-Benchmark.ps1 from inside the image against an
# already-running SpacetimeDB (and optionally Arcane manager/clusters). The
# orchestrator spawns the arcane-swarm binary that ships in this image — no
# host toolchain is required.
#
# The scenario to run is selected by the config file the caller points at (via
# --config): a SpacetimeDB-only config has BenchmarkMode=SpacetimeOnly; an
# Arcane config has BenchmarkMode=ArcanePlusSpacetime. The PowerShell entry
# dispatches accordingly.
#
# The pwsh orchestrator is invoked via `-Command` (not `-File`) so cloud drivers
# can pass PowerShell syntax in the trailing args — in particular array
# literals like `-ArcaneClusterHosts '10.0.0.1','10.0.0.2'` needed for
# multi-host Arcane runs. Use `--` to separate this wrapper's flags from the
# PowerShell tail. Local runs don't need any tail args.
#
# Mount /var/benchmark/out to persist the run folder outside the container,
# and mount the runtime-config dir so the driver can see the config the host
# orchestrator staged for this run:
#   docker run \
#     -v /host/out:/var/benchmark/out \
#     -v /host/runtime-config:/opt/benchmark/runtime-configs:ro \
#     IMG run-benchmark \
#       --config /opt/benchmark/runtime-configs/spacetimedb_only.json \
#       --spacetime-host http://<spacetime-vpc-ip>:3000 \
#       --environment AwsSpacetimeOnly

set -euo pipefail

CONFIG=""
SPACETIME_HOST=""
ENVIRONMENT="Local"
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config)          CONFIG="$2"; shift 2 ;;
    --spacetime-host)  SPACETIME_HOST="$2"; shift 2 ;;
    --environment)     ENVIRONMENT="$2"; shift 2 ;;
    --)                shift; EXTRA+=("$@"); break ;;
    *)                 EXTRA+=("$1"); shift ;;
  esac
done

if [ -z "$CONFIG" ]; then
  echo "--config <path> is required (path inside the container, e.g. /opt/benchmark/runtime-configs/spacetimedb_only.json — mount the host runtime-config dir there with -v)" >&2
  exit 2
fi
if [ -z "$SPACETIME_HOST" ]; then
  echo "--spacetime-host <url> is required" >&2
  exit 2
fi

OUT_DIR="/var/benchmark/out"
mkdir -p "$OUT_DIR"

export PATH="/usr/local/bin:${PATH}"

# The image always ships arcane-swarm, arcane-manager, and benchmark-cluster on
# /usr/local/bin. Passing all three every time means the PS script doesn't need
# to probe the filesystem — and the SpacetimeDB-only scenario simply ignores
# the two Arcane paths.
cmd="& '/opt/benchmark/scripts/Run-Benchmark.ps1'"
cmd+=" -ConfigFile '$CONFIG'"
cmd+=" -SpacetimeHost '$SPACETIME_HOST'"
cmd+=" -Environment '$ENVIRONMENT'"
cmd+=" -OutDir '$OUT_DIR'"
cmd+=" -SwarmExe '/usr/local/bin/arcane-swarm'"
cmd+=" -ArcaneManagerExe '/usr/local/bin/arcane-manager'"
cmd+=" -ArcaneClusterExe '/usr/local/bin/benchmark-cluster'"
if [ ${#EXTRA[@]} -gt 0 ]; then
  cmd+=" ${EXTRA[*]}"
fi

exec pwsh -NoProfile -Command "$cmd"
