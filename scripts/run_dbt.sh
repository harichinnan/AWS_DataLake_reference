#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-citibike-lake-dev}"

cd "$(dirname "$0")/../dbt"
dbt "$@" --profiles-dir .
