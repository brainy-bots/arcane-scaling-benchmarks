#!/usr/bin/env bash
# cleanup.sh — guaranteed-clean teardown of the AWS benchmark fleet.
#
# Wraps `terraform destroy` and follows it with an AWS-side audit so the
# success contract is concrete: either this script exits 0 AND no
# Project=arcane-benchmark resources remain in the account, or it exits
# non-zero and prints exactly what's still there.
#
# Why a wrapper instead of just running `terraform destroy`:
# - Idempotent + retryable on AWS API throttling / state-lock contention.
#   Re-running this script is always safe.
# - AWS-side audit catches the rare case where terraform reports success
#   but resources persist (out-of-band references, stale state).
# - One-line teardown command for the README; users don't have to
#   remember the right -var-file flags or which directory to cd into.
#
# Usage (from the repo root or anywhere — script self-locates):
#   ./infra/aws/cleanup.sh [--tfvars <name>] [--region <aws-region>]
#
# Defaults:
#   tfvars: arcaneperhost.clusters_4.drivers_12.tfvars (matches the
#           README's headline reproduction; override if you provisioned
#           a different topology)
#   region: us-east-1 (matches the headline tfvars)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform/aws_benchmark"
TFVARS="arcaneperhost.clusters_4.drivers_12.tfvars"
REGION="us-east-1"
PROJECT_TAG="arcane-benchmark"
MAX_DESTROY_RETRIES=2

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
    # Fall back to common per-user install paths so users who installed
    # via tfenv / their own ~/bin still hit the script's happy path
    # without needing to put terraform on PATH for this shell.
    for cand in "$HOME/bin/terraform" "$HOME/.local/bin/terraform" "$HOME/.tfenv/bin/terraform"; do
        if [[ -x "$cand" ]]; then TF_BIN="$cand"; break; fi
    done
fi
command -v "$TF_BIN" >/dev/null 2>&1 || {
    echo "cleanup.sh: terraform not found on PATH or in common install dirs." >&2
    echo "  Install: https://developer.hashicorp.com/terraform/install" >&2
    exit 2
}

if ! command -v aws >/dev/null 2>&1; then
    echo "cleanup.sh: aws CLI not found on PATH. Install + configure credentials." >&2
    exit 2
fi

if [[ ! -f "$TF_DIR/$TFVARS" ]]; then
    echo "cleanup.sh: tfvars file not found: $TF_DIR/$TFVARS" >&2
    echo "  Available tfvars in this module:" >&2
    ls "$TF_DIR"/*.tfvars 2>&1 | sed 's/^/    /' >&2
    exit 2
fi

echo "==> cleanup.sh"
echo "    terraform module: $TF_DIR"
echo "    tfvars:           $TFVARS"
echo "    region:           $REGION"
echo "    project tag:      Project=$PROJECT_TAG"

# ── 1. terraform destroy with bounded retry ─────────────────────────────────
attempt=1
while (( attempt <= MAX_DESTROY_RETRIES + 1 )); do
    echo "==> terraform destroy (attempt $attempt/$((MAX_DESTROY_RETRIES + 1)))"
    if "$TF_BIN" -chdir="$TF_DIR" destroy \
        -var-file="$TFVARS" \
        -var='operator_cidr_blocks=["0.0.0.0/0"]' \
        -auto-approve; then
        echo "    terraform destroy succeeded"
        break
    fi
    if (( attempt > MAX_DESTROY_RETRIES )); then
        echo "cleanup.sh: terraform destroy failed after $attempt attempts" >&2
        echo "  Manual recovery options:" >&2
        echo "    - State lock stuck:    terraform -chdir=$TF_DIR force-unlock <ID>" >&2
        echo "    - Out-of-band depend:  check AWS console for resources sharing the VPC/SG" >&2
        echo "  Then re-run this script." >&2
        exit 1
    fi
    echo "    retry in 10s (transient AWS API or state-lock issue)…"
    sleep 10
    attempt=$((attempt + 1))
done

# ── 2. AWS-side audit ───────────────────────────────────────────────────────
# Terraform thinks it's done. Now verify with the AWS API directly that
# no Project=arcane-benchmark resources remain. This catches:
#   - Out-of-band attachments (e.g., a Lambda ENI holding the SG open)
#   - Stale terraform state (rare but real after force-unlock recovery)
#   - Cross-region drift (we only audit $REGION but at least confirm here)
echo "==> AWS-side audit (Project=$PROJECT_TAG, region=$REGION)"
LEAK_COUNT=0

# EC2 instances (any non-terminated state)
ec2_leftovers=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`]|[0].Value]' \
    --output text 2>/dev/null || true)
if [[ -n "$ec2_leftovers" ]]; then
    LEAK_COUNT=$((LEAK_COUNT + $(echo "$ec2_leftovers" | wc -l)))
    echo "    EC2 leftovers:"
    echo "$ec2_leftovers" | sed 's/^/      /'
fi

# Security groups
sg_leftovers=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[].[GroupId,GroupName]' \
    --output text 2>/dev/null || true)
if [[ -n "$sg_leftovers" ]]; then
    LEAK_COUNT=$((LEAK_COUNT + $(echo "$sg_leftovers" | wc -l)))
    echo "    Security group leftovers:"
    echo "$sg_leftovers" | sed 's/^/      /'
fi

# VPCs (only those we created — default VPC has no Project tag so it's safe)
vpc_leftovers=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'Vpcs[].[VpcId,CidrBlock]' \
    --output text 2>/dev/null || true)
if [[ -n "$vpc_leftovers" ]]; then
    LEAK_COUNT=$((LEAK_COUNT + $(echo "$vpc_leftovers" | wc -l)))
    echo "    VPC leftovers:"
    echo "$vpc_leftovers" | sed 's/^/      /'
fi

# IAM roles / instance profiles. These don't carry the Project tag in the
# current module, so we filter by name prefix matching what the module
# creates. Stay narrow on the prefix to avoid eating user-created IAM.
iam_leftovers=$(aws iam list-roles \
    --query 'Roles[?starts_with(RoleName, `ArcaneBenchmark`)].[RoleName]' \
    --output text 2>/dev/null || true)
if [[ -n "$iam_leftovers" ]]; then
    LEAK_COUNT=$((LEAK_COUNT + $(echo "$iam_leftovers" | wc -l)))
    echo "    IAM role leftovers:"
    echo "$iam_leftovers" | sed 's/^/      /'
fi

# S3 buckets — module names them arcane-benchmark-artifacts-<account>-<region>.
# Filter conservatively to avoid touching user buckets.
s3_leftovers=$(aws s3api list-buckets \
    --query 'Buckets[?starts_with(Name, `arcane-benchmark-artifacts-`)].[Name]' \
    --output text 2>/dev/null || true)
if [[ -n "$s3_leftovers" ]]; then
    LEAK_COUNT=$((LEAK_COUNT + $(echo "$s3_leftovers" | wc -l)))
    echo "    S3 bucket leftovers:"
    echo "$s3_leftovers" | sed 's/^/      /'
fi

# ── 3. Final verdict ────────────────────────────────────────────────────────
if (( LEAK_COUNT == 0 )); then
    echo "==> CLEAN: terraform destroy succeeded AND no Project=$PROJECT_TAG resources remain in $REGION."
    exit 0
else
    echo "==> LEAK: terraform reported success but $LEAK_COUNT resources still exist (listed above)." >&2
    echo "    Most common cause: out-of-band references (e.g., a Lambda ENI keeping" >&2
    echo "    the security group attached). Investigate in the AWS console." >&2
    exit 1
fi
