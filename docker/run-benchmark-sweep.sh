#!/bin/bash
# Driver role. Runs the PowerShell benchmark orchestrator (scripts/Run-Benchmark.ps1)
# from inside the image against an already-running SpacetimeDB (and optionally
# Arcane manager/clusters). The orchestrator spawns the arcane-swarm binary that
# ships in this image — no host toolchain is required.
#
# Mount /var/benchmark/out to persist the run folder outside the container:
#   docker run -v /host/out:/var/benchmark/out IMG run-benchmark-sweep \
#              --config /opt/benchmark/configs/spacetimedb_only.json \
#              --spacetime-host http://<spacetime-vpc-ip>:3000 \
#              --environment AwsSpacetimeOnly

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

# arcane-swarm is on PATH inside this image; Run-Benchmark.ps1 picks it up.
export PATH="/usr/local/bin:${PATH}"

pwsh -NoProfile -File /opt/benchmark/scripts/Run-Benchmark.ps1 \
  -ConfigFile "$CONFIG" \
  -SpacetimeHost "$SPACETIME_HOST" \
  -Environment "$ENVIRONMENT" \
  -OutDir "$OUT_DIR" \
  "${EXTRA[@]:-}"
