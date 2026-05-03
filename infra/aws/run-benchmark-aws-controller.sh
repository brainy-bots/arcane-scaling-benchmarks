#!/usr/bin/env bash
# Bash counterpart to Run-Benchmark-Aws-Controller.ps1.
# Designed to be runnable from any POSIX shell (WSL, Linux, macOS) with the
# AWS CLI configured, so the operator can iterate without dropping into
# Windows PowerShell. Same lifecycle as the .ps1: restart containers via SSM,
# wait for driver registration, run the local benchmark-controller binary
# against the orchestrator's HTTP API, capture logs, stop containers.
#
# Assumes the infra is already provisioned (terraform apply has run and the
# state json is at the expected path) and the docker daemon is already
# installed on every node (cloud-init done). Re-running this against a
# previously-torn-down fleet is the expected case.
#
# Usage:
#   ./run-benchmark-aws-controller.sh \
#     --state-path .benchmark-aws-terraform.json \
#     --plan plans/headline-13500.toml \
#     --image ghcr.io/brainy-bots/arcane-benchmark:dev-... \
#     --controller-binary /path/to/benchmark-controller

set -euo pipefail

STATE_PATH=""
PLAN_FILE=""
BENCHMARK_IMAGE=""
CONTROLLER_BINARY=""
RESULTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-path) STATE_PATH="$2"; shift 2 ;;
        --plan) PLAN_FILE="$2"; shift 2 ;;
        --image) BENCHMARK_IMAGE="$2"; shift 2 ;;
        --controller-binary) CONTROLLER_BINARY="$2"; shift 2 ;;
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -z "$STATE_PATH" || ! -f "$STATE_PATH" ]] && { echo "missing --state-path" >&2; exit 2; }
[[ -z "$PLAN_FILE"  || ! -f "$PLAN_FILE" ]] && { echo "missing --plan" >&2; exit 2; }
[[ -z "$BENCHMARK_IMAGE" ]] && { echo "missing --image" >&2; exit 2; }
[[ -z "$CONTROLLER_BINARY" || ! -x "$CONTROLLER_BINARY" ]] && { echo "missing/non-executable --controller-binary" >&2; exit 2; }

REGION=$(jq -r '.Region' "$STATE_PATH")
ENV_NAME=$(jq -r '.Environment' "$STATE_PATH")
MANAGER_ID=$(jq -r '.ManagerInstanceId' "$STATE_PATH")
MANAGER_PRIVATE_IP=$(jq -r '.ManagerPrivateIp' "$STATE_PATH")
MANAGER_PUBLIC_DNS=$(jq -r '.ManagerPublicDns' "$STATE_PATH")
ORCH_HTTP_PORT=$(jq -r '.OrchestratorHttpPort // 8090' "$STATE_PATH")
ORCH_DRIVER_PORT=$(jq -r '.OrchestratorDriverPort // 8088' "$STATE_PATH")
REDIS_ID=$(jq -r '.RedisInstanceId' "$STATE_PATH")
SPACETIME_ID=$(jq -r '.SpacetimeInstanceId' "$STATE_PATH")
mapfile -t CLUSTER_IDS < <(jq -r '.ClusterIds[]' "$STATE_PATH")
mapfile -t CLUSTER_INST < <(jq -r '.ClusterInstanceIds[]' "$STATE_PATH")
mapfile -t CLUSTER_IPS  < <(jq -r '.ClusterPrivateIps[]' "$STATE_PATH")
mapfile -t DRIVER_IDS   < <(jq -r '.BenchmarkInstanceIds[]' "$STATE_PATH")

RUN_ID=$(date +%Y%m%d_%H%M%S)
[[ -z "$RESULTS_DIR" ]] && RESULTS_DIR="$(dirname "$0")/../../results/runs/${ENV_NAME}/${RUN_ID}"
mkdir -p "$RESULTS_DIR"
LOGS_DIR="$RESULTS_DIR/container-logs"
mkdir -p "$LOGS_DIR"

ORCH_PUBLIC="http://${MANAGER_PUBLIC_DNS}:${ORCH_HTTP_PORT}"
ORCH_INTERNAL="ws://${MANAGER_PRIVATE_IP}:${ORCH_DRIVER_PORT}"

echo "==> environment:        $ENV_NAME"
echo "==> manager:            $MANAGER_ID ($MANAGER_PUBLIC_DNS)"
echo "==> clusters:           ${#CLUSTER_INST[@]}"
echo "==> drivers:            ${#DRIVER_IDS[@]}"
echo "==> image:              $BENCHMARK_IMAGE"
echo "==> orchestrator URL:   $ORCH_PUBLIC"
echo "==> results dir:        $RESULTS_DIR"

# ─── helpers ─────────────────────────────────────────────────────────────────
# Submit a single shell command to one EC2 via SSM, block until it terminates,
# return the exit code. We pass commands as a single shell -c so multi-line
# scripts and pipes survive. Output is discarded by default; use
# `ssm_capture` if you need stdout.
_ssm_send() {
    # Marshal the script through a temp JSON file so embedded newlines and
    # quotes survive AWS CLI's parameter parser (the inline `commands=[...]`
    # form turns "\n" into literal `n` after the backslash gets stripped).
    local id="$1"; shift
    local script="$*"
    local tmp
    tmp=$(mktemp)
    jq -n --arg s "$script" '{commands:[$s]}' > "$tmp"
    aws ssm send-command --region "$REGION" \
        --instance-ids "$id" \
        --document-name AWS-RunShellScript \
        --parameters "file://$tmp" \
        --output text --query 'Command.CommandId'
    local rc=$?
    rm -f "$tmp"
    return $rc
}

ssm_run() {
    local id="$1"; shift
    local cmd_id
    cmd_id=$(_ssm_send "$id" "$@") || return 1
    local status
    while true; do
        sleep 3
        status=$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cmd_id" --instance-id "$id" \
            --output text --query 'Status' 2>/dev/null || echo "")
        case "$status" in
            Success) return 0 ;;
            Failed|Cancelled|TimedOut)
                aws ssm get-command-invocation --region "$REGION" \
                    --command-id "$cmd_id" --instance-id "$id" \
                    --output json >&2
                return 1
                ;;
        esac
    done
}

ssm_capture() {
    local id="$1"; shift
    local cmd_id
    cmd_id=$(_ssm_send "$id" "$@") || return 1
    while true; do
        sleep 2
        local status
        status=$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cmd_id" --instance-id "$id" \
            --output text --query 'Status' 2>/dev/null || echo "")
        if [[ "$status" == "Success" || "$status" == "Failed" || "$status" == "Cancelled" || "$status" == "TimedOut" ]]; then
            aws ssm get-command-invocation --region "$REGION" \
                --command-id "$cmd_id" --instance-id "$id" \
                --output text --query 'StandardOutputContent'
            return 0
        fi
    done
}

# ─── 1. pull image on every node ─────────────────────────────────────────────
ALL_IDS=("$MANAGER_ID" "${CLUSTER_INST[@]}" "${DRIVER_IDS[@]}" "$SPACETIME_ID" "$REDIS_ID")
echo "==> pulling image on ${#ALL_IDS[@]} nodes"
for id in "${ALL_IDS[@]}"; do
    ssm_run "$id" "docker pull $BENCHMARK_IMAGE" &
done
wait
echo "   image pulled"

# ─── 2. Redis + SpacetimeDB ──────────────────────────────────────────────────
echo "==> starting Redis"
ssm_run "$REDIS_ID" "docker rm -f bench-redis 2>/dev/null || true; docker run -d --name bench-redis --restart unless-stopped --network host redis:7-alpine redis-server --appendonly yes"

echo "==> starting SpacetimeDB + publishing module"
ssm_run "$SPACETIME_ID" "docker rm -f bench-spacetime 2>/dev/null || true; docker run -d --name bench-spacetime --restart unless-stopped --network host $BENCHMARK_IMAGE spacetime start; for i in \$(seq 1 30); do bash -c 'echo > /dev/tcp/127.0.0.1/3000' 2>/dev/null && break; sleep 2; done; docker run --rm --network host $BENCHMARK_IMAGE benchmark-publish-module --mode Persist --host http://127.0.0.1:3000"

REDIS_HOST=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$REDIS_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
SPACE_HOST=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SPACETIME_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# ─── 3. clusters ─────────────────────────────────────────────────────────────
echo "==> starting clusters (Redis=$REDIS_HOST, ST=$SPACE_HOST)"
for i in "${!CLUSTER_INST[@]}"; do
    cid="${CLUSTER_INST[$i]}"
    cuid="${CLUSTER_IDS[$i]}"
    ssm_run "$cid" "docker rm -f bench-cluster 2>/dev/null || true; docker run -d --name bench-cluster --restart unless-stopped --ulimit nofile=65536:65536 --network host -e CLUSTER_ID=$cuid -e REDIS_URL=redis://${REDIS_HOST}:6379 -e CLUSTER_WS_PORT=8090 -e SPACETIMEDB_URI=http://${SPACE_HOST}:3000 -e SPACETIMEDB_DATABASE=arcane -e SPACETIMEDB_PERSIST=1 -e SPACETIMEDB_PERSIST_HZ=1 $BENCHMARK_IMAGE benchmark-cluster" &
done
wait

# ─── 4. manager + orchestrator ──────────────────────────────────────────────
echo "==> starting manager + orchestrator on $MANAGER_ID"
MGR_CLUSTERS=""
for i in "${!CLUSTER_IDS[@]}"; do
    [[ -n "$MGR_CLUSTERS" ]] && MGR_CLUSTERS+=","
    MGR_CLUSTERS+="${CLUSTER_IDS[$i]}:${CLUSTER_IPS[$i]}:8090"
done
STATS_ARGS=""
for ip in "${CLUSTER_IPS[@]}"; do
    STATS_ARGS+=" --cluster-stats-url http://${ip}:8091/stats"
done

ssm_run "$MANAGER_ID" "docker rm -f bench-manager bench-orchestrator 2>/dev/null || true; docker run -d --name bench-manager --restart unless-stopped --ulimit nofile=65536:65536 --network host -e MANAGER_HTTP_PORT=8081 -e MANAGER_CLUSTERS='$MGR_CLUSTERS' $BENCHMARK_IMAGE arcane-manager; mkdir -p /var/orchestrator; docker run -d --name bench-orchestrator --restart unless-stopped --ulimit nofile=65536:65536 --network host -v /var/orchestrator:/var/orchestrator $BENCHMARK_IMAGE arcane-swarm-orchestrator --driver-port $ORCH_DRIVER_PORT --http-port $ORCH_HTTP_PORT --archive-dir /var/orchestrator/snapshots --max-drivers 64 $STATS_ARGS"

# ─── 5. drivers ──────────────────────────────────────────────────────────────
echo "==> starting ${#DRIVER_IDS[@]} drivers"
DRV_RUN="docker rm -f bench-driver 2>/dev/null || true; docker run -d --name bench-driver --restart unless-stopped --ulimit nofile=65536:65536 --network host -e ORCHESTRATOR_URL=$ORCH_INTERNAL $BENCHMARK_IMAGE arcane-swarm --backend arcane --arcane-manager http://${MANAGER_PRIVATE_IP}:8081 --orchestrator-url $ORCH_INTERNAL --tick-rate 60 --max-players 4000 --user-data-bytes 1000 --inter-spawn-delay-ms 8 --max-players-per-driver 4000 --burst-enabled --burst-period-secs 30 --burst-cohort-percent 20 --burst-actions-per-player 10 --burst-window-ms 500 --zone-event-period-secs 30 --zone-event-window-ms 500 --actions-per-sec 2 --read-rate 5 --run-forever"
for did in "${DRIVER_IDS[@]}"; do
    ssm_run "$did" "$DRV_RUN" &
done
wait

# ─── 6. wait for drivers to register ────────────────────────────────────────
echo "==> waiting for ${#DRIVER_IDS[@]} drivers to register"
EXPECTED=${#DRIVER_IDS[@]}
DEADLINE=$(( $(date +%s) + 180 ))
while (( $(date +%s) < DEADLINE )); do
    raw=$(curl -sN --max-time 3 "${ORCH_PUBLIC}/telemetry/stream" 2>/dev/null || true)
    first=$(echo "$raw" | grep -m1 '^data: ' | sed 's/^data: //')
    if [[ -n "$first" ]]; then
        active=$(echo "$first" | jq '[.fleet[] | select(.state=="Active")] | length' 2>/dev/null || echo 0)
        echo "   ($active/$EXPECTED active)"
        if (( active >= EXPECTED )); then break; fi
    fi
    sleep 2
done

# ─── 7. run controller ───────────────────────────────────────────────────────
echo "==> running controller"
set +e
"$CONTROLLER_BINARY" \
    --plan "$PLAN_FILE" \
    --orchestrator-url "$ORCH_PUBLIC" \
    --results-dir "$RESULTS_DIR" \
    --submitter "operator-bash" \
    --dashboard "${DASHBOARD:-auto}"
CTL_EXIT=$?
set -e

# ─── 8. capture logs ─────────────────────────────────────────────────────────
echo "==> capturing logs to $LOGS_DIR"
{
    ssm_capture "$MANAGER_ID" "docker logs bench-orchestrator 2>&1 | tail -300; echo '---SEPARATOR---'; docker logs bench-manager 2>&1 | tail -100"
} > "$LOGS_DIR/manager-${MANAGER_ID}.log"

for i in "${!DRIVER_IDS[@]}"; do
    did="${DRIVER_IDS[$i]}"
    ssm_capture "$did" "docker logs bench-driver 2>&1 | tail -200" > "$LOGS_DIR/driver-${i}-${did}.log" &
done
wait

for i in "${!CLUSTER_INST[@]}"; do
    cid="${CLUSTER_INST[$i]}"
    ssm_capture "$cid" "docker logs bench-cluster 2>&1 | tail -100" > "$LOGS_DIR/cluster-${i}-${cid}.log" &
done
wait

# ─── 9. teardown ─────────────────────────────────────────────────────────────
echo "==> stopping containers"
STOP_ALL="docker rm -f bench-driver bench-orchestrator bench-manager bench-cluster bench-spacetime bench-redis 2>/dev/null || true"
for id in "${ALL_IDS[@]}"; do
    ssm_run "$id" "$STOP_ALL" &
done
wait

if [[ $CTL_EXIT -eq 0 ]]; then
    echo "==> controller exit 0 (overall PASS)"
else
    echo "==> controller exit $CTL_EXIT"
fi
exit $CTL_EXIT
