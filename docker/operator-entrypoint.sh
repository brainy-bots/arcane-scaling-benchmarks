#!/usr/bin/env bash
set -euo pipefail

cd /workspace

# Defaults mirror the documented headline run.
# Default matches README / manual runs (override with -e BENCHMARK_IMAGE=...).
BENCHMARK_IMAGE="${BENCHMARK_IMAGE:-ghcr.io/brainy-bots/arcane-benchmark:v0.2.0}"
PLAN_FILE="${PLAN_FILE:-./plans/headline-13500.toml}"
TFVARS_FILE="${TFVARS_FILE:-arcaneperhost.clusters_4.drivers_12.tfvars}"
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

if [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; then
  exec pwsh -NoProfile ./infra/aws/Run-Repro-Aws-Controller.ps1 \
    -PlanFile "$PLAN_FILE" \
    -BenchmarkImage "$BENCHMARK_IMAGE" \
    -Tfvars "$TFVARS_FILE" \
    -Region "$AWS_REGION_VALUE" \
    "$@"
elif [ "$#" -eq 0 ]; then
  exec pwsh -NoProfile ./infra/aws/Run-Repro-Aws-Controller.ps1 \
    -PlanFile "$PLAN_FILE" \
    -BenchmarkImage "$BENCHMARK_IMAGE" \
    -Tfvars "$TFVARS_FILE" \
    -Region "$AWS_REGION_VALUE"
else
  exec "$@"
fi
