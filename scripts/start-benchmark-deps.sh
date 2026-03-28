#!/usr/bin/env bash
# Start Redis + SpacetimeDB in Docker on 127.0.0.1 — same stack locally and on EC2.
# Run from anywhere:  bash /path/to/arcane-scaling-benchmarks/scripts/start-benchmark-deps.sh
# Override images:    SPACETIME_IMAGE=clockworklabs/spacetime:2.0.5 ./scripts/start-benchmark-deps.sh
set -euo pipefail

REDIS_CONTAINER="${REDIS_CONTAINER:-arcane-bench-redis}"
SPACETIME_CONTAINER="${SPACETIME_CONTAINER:-arcane-bench-spacetime}"
SPACETIME_IMAGE="${SPACETIME_IMAGE:-clockworklabs/spacetime:latest}"

echo "=== Benchmark deps: Redis (Docker) on 127.0.0.1:6379 ==="
docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
docker run -d --name "$REDIS_CONTAINER" -p 127.0.0.1:6379:6379 redis:7-alpine redis-server --appendonly yes
redis_ok=0
for _ in $(seq 1 60); do
  if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then redis_ok=1; break; fi
  sleep 1
done
if [ "$redis_ok" != "1" ]; then
  echo "ERROR: Redis did not respond to PING in time."
  docker logs "$REDIS_CONTAINER" 2>/dev/null || true
  exit 1
fi

echo "=== Benchmark deps: SpacetimeDB (Docker) on 127.0.0.1:3000 image=$SPACETIME_IMAGE ==="
docker rm -f "$SPACETIME_CONTAINER" 2>/dev/null || true
docker pull "$SPACETIME_IMAGE"
docker run -d --name "$SPACETIME_CONTAINER" -p 127.0.0.1:3000:3000 "$SPACETIME_IMAGE" start
st_ok=0
for _ in $(seq 1 120); do
  if bash -c "echo >/dev/tcp/127.0.0.1/3000" 2>/dev/null; then st_ok=1; break; fi
  sleep 2
done
if [ "$st_ok" != "1" ]; then
  echo "ERROR: Nothing accepted TCP on 127.0.0.1:3000 (SpacetimeDB container)."
  docker logs "$SPACETIME_CONTAINER" 2>/dev/null || true
  exit 1
fi

echo "=== Redis + SpacetimeDB ready (same recipe as cloud benchmark) ==="
