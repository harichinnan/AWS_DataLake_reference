#!/usr/bin/env bash
set -euo pipefail

DBT_COMMAND="${DBT_COMMAND:-build}"
DBT_SELECT="${DBT_SELECT:-}"
DBT_EXCLUDE="${DBT_EXCLUDE:-}"
DBT_TARGET="${DBT_TARGET:-prod}"
DBT_VARS="${DBT_VARS:-}"
DBT_FULL_REFRESH="${DBT_FULL_REFRESH:-false}"
DBT_PROJECT_S3_URI="${DBT_PROJECT_S3_URI:-}"
DBT_PROJECT_DIR="${DBT_PROJECT_DIR:-/opt/dbt}"

if [[ -z "$DBT_PROJECT_S3_URI" ]]; then
  echo "ERROR: DBT_PROJECT_S3_URI is required. Set it on the Batch job definition" >&2
  echo "       to point at the artifact uploaded by .github/workflows/dbt-cd.yml." >&2
  exit 2
fi

echo "Downloading dbt project from $DBT_PROJECT_S3_URI"
TARBALL=/tmp/dbt-project.tar.gz
aws s3 cp "$DBT_PROJECT_S3_URI" "$TARBALL"

# Wipe whatever's in DBT_PROJECT_DIR and re-populate from the tarball so the
# job is hermetic across invocations of long-lived Fargate tasks.
mkdir -p "$DBT_PROJECT_DIR"
find "$DBT_PROJECT_DIR" -mindepth 1 -delete
tar xzf "$TARBALL" -C "$DBT_PROJECT_DIR"

cd "$DBT_PROJECT_DIR"

dbt --version

echo "Running: dbt deps"
dbt deps

ARGS=("$DBT_COMMAND" "--target" "$DBT_TARGET" "--profiles-dir" "$DBT_PROJECT_DIR")

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
set +e
dbt "${ARGS[@]}"
DBT_EXIT_CODE=$?
set -e

# On a green run, publish target/manifest.json + run_results.json to the
# artifacts bucket. PR slim-CI defers against `latest/`; `history/<ts>/` keeps
# a forensic trail for diffing prod-state across deploys. Skip silently when
# ARTIFACTS_BUCKET is unset (e.g. ad-hoc local invocations of this image).
if [[ "$DBT_EXIT_CODE" -eq 0 && -n "${ARTIFACTS_BUCKET:-}" ]]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  for f in manifest.json run_results.json; do
    if [[ -f "target/$f" ]]; then
      aws s3 cp "target/$f" "s3://${ARTIFACTS_BUCKET}/dbt/manifest/latest/$f"
      aws s3 cp "target/$f" "s3://${ARTIFACTS_BUCKET}/dbt/manifest/history/${TS}/$f"
    fi
  done
fi

exit "$DBT_EXIT_CODE"
