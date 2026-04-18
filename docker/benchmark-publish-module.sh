#!/bin/bash
# Publish a benchmark WASM module into an already-running SpacetimeDB instance.
#
# Invoked as a short-lived container role:
#   docker run IMG benchmark-publish-module --mode Full   --host http://spacetime:3000
#   docker run IMG benchmark-publish-module --mode Persist --host http://spacetime:3000
#
# Exit 0 on success (or if the module is already published with the same
# version). The caller decides when to invoke this (typically once, right after
# SpacetimeDB is Online).

set -euo pipefail

MODE="Full"
HOST="http://127.0.0.1:3000"
DB_NAME="arcane"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     MODE="$2"; shift 2 ;;
    --host)     HOST="$2"; shift 2 ;;
    --db|--database) DB_NAME="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  Full)    WASM=/opt/modules/benchmark_spacetimedb_full.wasm ;;
  Persist) WASM=/opt/modules/benchmark_spacetimedb_persist.wasm ;;
  *) echo "--mode must be Full or Persist (got '$MODE')" >&2; exit 2 ;;
esac

if [ ! -f "$WASM" ]; then
  echo "WASM not found at $WASM (image built wrong?)" >&2
  exit 2
fi

exec spacetime publish "$DB_NAME" --yes --anonymous -s "$HOST" --bin-path "$WASM"
