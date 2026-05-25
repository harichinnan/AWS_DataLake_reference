#!/usr/bin/env bash
set -euo pipefail

PROFILE_ARG=()
if [[ -n "${AWS_PROFILE:-}" ]]; then
  PROFILE_ARG=(--profile "$AWS_PROFILE")
fi

TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
TERRAFORM_DIR="${TERRAFORM_DIR:-$(cd "$(dirname "$0")/../terraform" && pwd)}"
TF=("$TERRAFORM_BIN" -chdir="$TERRAFORM_DIR")

REGION="${AWS_REGION:-$("${TF[@]}" output -raw aws_region)}"
DATABASE_NAME="$("${TF[@]}" output -raw glue_database_name)"
RULESET_NAME="$("${TF[@]}" output -raw silver_data_quality_ruleset_name)"
ROLE_ARN="$("${TF[@]}" output -raw glue_data_quality_role_arn)"
RESULTS_PREFIX="$("${TF[@]}" output -raw metabase_athena_staging_dir)"
RESULTS_PREFIX="${RESULTS_PREFIX%/}/glue-data-quality/"
NUMBER_OF_WORKERS="${GLUE_DQ_NUMBER_OF_WORKERS:-2}"
TIMEOUT_MINUTES="${GLUE_DQ_TIMEOUT_MINUTES:-60}"

if [[ -z "$RULESET_NAME" || "$RULESET_NAME" == "null" ]]; then
  echo "Glue Data Quality is not enabled in Terraform outputs." >&2
  exit 1
fi

RUN_ID="$(
  aws glue start-data-quality-ruleset-evaluation-run \
    "${PROFILE_ARG[@]}" \
    --region "$REGION" \
    --data-source "{\"GlueTable\":{\"DatabaseName\":\"${DATABASE_NAME}\",\"TableName\":\"citibike_trips_silver\"}}" \
    --role "$ROLE_ARN" \
    --number-of-workers "$NUMBER_OF_WORKERS" \
    --timeout "$TIMEOUT_MINUTES" \
    --additional-run-options "{\"CloudWatchMetricsEnabled\":true,\"ResultsS3Prefix\":\"${RESULTS_PREFIX}\"}" \
    --ruleset-names "$RULESET_NAME" \
    --query RunId \
    --output text
)"

echo "Started Glue Data Quality run: ${RUN_ID}"

while true; do
  RUN="$(
    aws glue get-data-quality-ruleset-evaluation-run \
      "${PROFILE_ARG[@]}" \
      --region "$REGION" \
      --run-id "$RUN_ID" \
      --output json
  )"
  STATUS="$(printf '%s' "$RUN" | jq -r '.Status')"
  echo "Status: ${STATUS}"

  case "$STATUS" in
    SUCCEEDED|FAILED|STOPPED|TIMEOUT)
      break
      ;;
  esac

  sleep 20
done

printf '%s\n' "$RUN" | jq '.'

RESULT_ID="$(printf '%s' "$RUN" | jq -r '.ResultIds[0] // empty')"
if [[ -n "$RESULT_ID" ]]; then
  RESULT="$(
    aws glue get-data-quality-result \
    "${PROFILE_ARG[@]}" \
    --region "$REGION" \
    --result-id "$RESULT_ID" \
      --output json
  )"
  printf '%s\n' "$RESULT" | jq '.'

  FAILED_RULE_COUNT="$(printf '%s' "$RESULT" | jq '[.RuleResults[]? | select(.Result != "PASS")] | length')"
  if [[ "$FAILED_RULE_COUNT" != "0" ]]; then
    echo "Glue Data Quality completed, but ${FAILED_RULE_COUNT} rule(s) did not pass:" >&2
    printf '%s' "$RESULT" | jq -r '.RuleResults[]? | select(.Result != "PASS") | "- \(.Name): \(.Description) => \(.Result)"' >&2
    exit 2
  fi
fi

if [[ "$STATUS" != "SUCCEEDED" ]]; then
  exit 1
fi
