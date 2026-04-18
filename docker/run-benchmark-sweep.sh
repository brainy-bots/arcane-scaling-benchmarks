#!/bin/bash
# Driver role. Runs the PowerShell benchmark orchestrator
# (scripts/Run-Benchmark.ps1) from inside the image against an already-running
# SpacetimeDB (and optionally Arcane manager/clusters). The orchestrator spawns
# the arcane-swarm binary that ships in this image — no host toolchain is
# required.
#
# The pwsh orchestrator is invoked via `-Command` (not `-File`) so callers can
# pass full PowerShell syntax in the trailing args — in particular array
# literals like `-ArcaneClusterHosts '10.0.0.1','10.0.0.2'` needed for
# multi-host Arcane runs. Use `--` to separate this wrapper's flags from the
# PowerShell tail.
#
# Mount /var/benchmark/out to persist the run folder outside the container:
#   docker run -v /host/out:/var/benchmark/out IMG run-benchmark-sweep \
#              --config /opt/benchmark/configs/spacetimedb_only.json \
#              --spacetime-host http://<spacetime-vpc-ip>:3000 \
#              --environment AwsSpacetimeOnly \
#              -- '-FindArcaneCeiling:$false'

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
  echo "--config <path> is required (path inside the container, e.g. /opt/benchmark/configs/spacetimedb_only.json)" >&2
  exit 2
fi
if [ -z "$SPACETIME_HOST" ]; then
  echo "--spacetime-host <url> is required" >&2
  exit 2
fi

OUT_DIR="/var/benchmark/out"
mkdir -p "$OUT_DIR"

export PATH="/usr/local/bin:${PATH}"

# Build a PowerShell command string: the baseline flags with values single-
# quoted for pwsh, then the verbatim EXTRA tail. EXTRA is already PS syntax as
# the caller wrote it (e.g. -ArcaneClusterHosts '10.0.0.1','10.0.0.2').
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
