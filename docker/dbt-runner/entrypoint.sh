#!/usr/bin/env bash
set -euo pipefail

DBT_COMMAND="${DBT_COMMAND:-build}"
DBT_SELECT="${DBT_SELECT:-}"
DBT_EXCLUDE="${DBT_EXCLUDE:-}"
DBT_TARGET="${DBT_TARGET:-prod}"
DBT_VARS="${DBT_VARS:-}"
DBT_FULL_REFRESH="${DBT_FULL_REFRESH:-false}"

cd /opt/dbt

dbt --version

echo "Running: dbt deps"
dbt deps

ARGS=("$DBT_COMMAND" "--target" "$DBT_TARGET" "--profiles-dir" "/opt/dbt")

if [[ -n "$DBT_SELECT" ]]; then
  ARGS+=("--select" "$DBT_SELECT")
fi

if [[ -n "$DBT_EXCLUDE" ]]; then
  ARGS+=("--exclude" "$DBT_EXCLUDE")
fi

if [[ -n "$DBT_VARS" ]]; then
  ARGS+=("--vars" "$DBT_VARS")
fi

if [[ "$DBT_FULL_REFRESH" == "true" ]]; then
  ARGS+=("--full-refresh")
fi

echo "Running: dbt ${ARGS[*]}"
exec dbt "${ARGS[@]}"
