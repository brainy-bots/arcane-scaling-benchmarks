#!/usr/bin/env bash
# setup.sh — provision the AWS benchmark fleet end-to-end.
#
# Wraps `terraform init` + `terraform apply` and replaces the README's
# fragile manual step ("wait ~60 seconds for SSM agents") with a real
# poll: doesn't return until every EC2 reports SSM Online. After that,
# downstream run scripts can hit any node via SSM with no surprises.
#
# Why a wrapper instead of just running terraform apply:
# - One command for the README. No `cd infra/terraform/aws_benchmark`
#   dance, no remembering -var-file=... flags.
# - Idempotent + retryable. Re-running this script when infra is already
#   up is a no-op (terraform refresh + 0 changes + SSM ready).
# - Writes the canonical state JSON the run scripts expect, in the
#   canonical location, every time. No off-by-one path bugs.
# - The SSM-readiness wait closes the most common race users hit when
#   following the README.
#
# Usage (from the repo root or anywhere — script self-locates):
#   ./infra/aws/setup.sh [--tfvars <name>] [--region <aws-region>]
#
# Defaults:
#   tfvars: arcaneperhost.clusters_4.drivers_12.tfvars (matches the
#           README's headline reproduction)
#   region: us-east-1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform/aws_benchmark"
TFVARS="arcaneperhost.clusters_4.drivers_12.tfvars"
REGION="us-east-1"
SSM_WAIT_DEADLINE_SECS=600   # 10-minute ceiling; user-data installs Docker so first boot is slow

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tfvars) TFVARS="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# //;s/^#//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

TF_BIN="${TERRAFORM:-terraform}"
if ! command -v "$TF_BIN" >/dev/null 2>&1; then
    for cand in "$HOME/bin/terraform" "$HOME/.local/bin/terraform" "$HOME/.tfenv/bin/terraform"; do
        if [[ -x "$cand" ]]; then TF_BIN="$cand"; break; fi
    done
fi
command -v "$TF_BIN" >/dev/null 2>&1 || {
    echo "setup.sh: terraform not found on PATH or in common install dirs." >&2
    echo "  Install: https://developer.hashicorp.com/terraform/install" >&2
    exit 2
}

if ! command -v aws >/dev/null 2>&1; then
    echo "setup.sh: aws CLI not found on PATH. Install + configure credentials." >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "setup.sh: jq not found on PATH. Install: apt install jq / brew install jq" >&2
    exit 2
fi

if [[ ! -f "$TF_DIR/$TFVARS" ]]; then
    echo "setup.sh: tfvars file not found: $TF_DIR/$TFVARS" >&2
    echo "  Available tfvars in this module:" >&2
    ls "$TF_DIR"/*.tfvars 2>&1 | sed 's/^/    /' >&2
    exit 2
fi

echo "==> setup.sh"
echo "    terraform module: $TF_DIR"
echo "    tfvars:           $TFVARS"
echo "    region:           $REGION"

# ── 1. terraform init (safe to re-run) ──────────────────────────────────────
echo "==> terraform init"
"$TF_BIN" -chdir="$TF_DIR" init -input=false -upgrade=false 1>/dev/null

# ── 2. terraform apply ──────────────────────────────────────────────────────
# operator_cidr_blocks defaults to [] in variables.tf so it's optional for
# the README's PowerShell path. We pass 0.0.0.0/0 here so the new
# controller-mode path (which opens orchestrator HTTP to the operator)
# also works without the user knowing their public IP. Anyone running the
# orchestrator-HTTP-public path in production should override this.
echo "==> terraform apply"
"$TF_BIN" -chdir="$TF_DIR" apply \
    -var-file="$TFVARS" \
    -var='operator_cidr_blocks=["0.0.0.0/0"]' \
    -auto-approve

# ── 3. Write canonical state JSON ───────────────────────────────────────────
STATE_OUT_TF="$TF_DIR/.benchmark-aws-terraform.json"
STATE_OUT_ROOT="$REPO_ROOT/.benchmark-aws-terraform.json"
"$TF_BIN" -chdir="$TF_DIR" output -json benchmark_state > "$STATE_OUT_TF"
# Mirror to the repo root too — the new bash launcher looks there. Keeping
# both means README's PowerShell path (which reads from $TF_DIR) and the
# new controller-mode path (which reads from the repo root) both work
# without the user needing to copy the file around.
cp "$STATE_OUT_TF" "$STATE_OUT_ROOT"
echo "    state JSON written:"
echo "      $STATE_OUT_TF"
echo "      $STATE_OUT_ROOT"

# ── 4. Wait for every EC2 to report SSM Online ──────────────────────────────
# Replaces the README's "wait ~60 seconds" sleep. Reads the instance IDs
# from the state JSON we just wrote, polls SSM until every one is Online,
# bounded by SSM_WAIT_DEADLINE_SECS. This is the difference between "the
# next step works" and "the next step fails confusingly with 'no SSM
# associations found.'"
mapfile -t INSTANCE_IDS < <(jq -r '
    [.ManagerInstanceId, .RedisInstanceId, .SpacetimeInstanceId,
     (.ClusterInstanceIds // [])[],
     (.BenchmarkInstanceIds // [])[]] | .[] | select(. != null)
' "$STATE_OUT_ROOT")
EXPECTED=${#INSTANCE_IDS[@]}
echo "==> waiting for SSM agents to come online on $EXPECTED instances"

deadline=$(( $(date +%s) + SSM_WAIT_DEADLINE_SECS ))
while (( $(date +%s) < deadline )); do
    online=$(aws ssm describe-instance-information \
        --region "$REGION" \
        --filters "Key=InstanceIds,Values=$(IFS=,; echo "${INSTANCE_IDS[*]}")" \
        --query 'length(InstanceInformationList)' \
        --output text 2>/dev/null || echo 0)
    echo "    ($online/$EXPECTED Online)"
    if [[ "$online" == "$EXPECTED" ]]; then
        break
    fi
    sleep 10
done

if [[ "${online:-0}" != "$EXPECTED" ]]; then
    echo "setup.sh: SSM did not reach $EXPECTED Online within ${SSM_WAIT_DEADLINE_SECS}s." >&2
    echo "  Got $online/$EXPECTED. Run scripts will fail." >&2
    echo "  Re-run setup.sh — it's idempotent and will continue waiting." >&2
    exit 1
fi

echo "==> READY: $EXPECTED instances Online. You can now run the benchmark."
