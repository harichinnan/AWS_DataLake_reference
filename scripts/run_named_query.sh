#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: bash scripts/run_named_query.sh <named-query-id> [workgroup] [region]" >&2
  exit 2
fi

TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
TERRAFORM_DIR="${TERRAFORM_DIR:-$(cd "$(dirname "$0")/../terraform" && pwd)}"
TF=("$TERRAFORM_BIN" -chdir="$TERRAFORM_DIR")

query_id="$1"
workgroup="${2:-$("${TF[@]}" output -raw athena_workgroup_name)}"
region="${3:-$("${TF[@]}" output -raw aws_region)}"

query_string="$(aws athena get-named-query \
  --named-query-id "$query_id" \
  --region "$region" \
  --query 'NamedQuery.QueryString' \
  --output text)"

database="$(aws athena get-named-query \
  --named-query-id "$query_id" \
  --region "$region" \
  --query 'NamedQuery.Database' \
  --output text)"

execution_id="$(aws athena start-query-execution \
  --work-group "$workgroup" \
  --query-execution-context "Database=$database" \
  --query-string "$query_string" \
  --region "$region" \
  --query 'QueryExecutionId' \
  --output text)"

echo "Started Athena query execution: $execution_id"

while true; do
  state="$(aws athena get-query-execution \
    --query-execution-id "$execution_id" \
    --region "$region" \
    --query 'QueryExecution.Status.State' \
    --output text)"

  case "$state" in
    SUCCEEDED)
      echo "Athena query succeeded: $execution_id"
      exit 0
      ;;
    FAILED|CANCELLED)
      reason="$(aws athena get-query-execution \
        --query-execution-id "$execution_id" \
        --region "$region" \
        --query 'QueryExecution.Status.StateChangeReason' \
        --output text)"
      echo "Athena query $state: $reason" >&2
      exit 1
      ;;
    *)
      sleep 5
      ;;
  esac
done
