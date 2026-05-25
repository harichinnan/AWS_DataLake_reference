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
CATALOG_ID="$("${TF[@]}" output -raw aws_account_id)"
DATABASE_NAME="${1:-$("${TF[@]}" output -raw glue_database_name)}"

revoke_iam_allowed() {
  local resource_json="$1"

  aws lakeformation revoke-permissions \
    "${PROFILE_ARG[@]}" \
    --region "$REGION" \
    --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
    --resource "$resource_json" \
    --permissions ALL >/dev/null 2>&1 || true
}

echo "Revoking IAM_ALLOWED_PRINCIPALS from database ${DATABASE_NAME}"
revoke_iam_allowed "{\"Database\":{\"CatalogId\":\"${CATALOG_ID}\",\"Name\":\"${DATABASE_NAME}\"}}"

TABLES="$(
  aws glue get-tables \
    "${PROFILE_ARG[@]}" \
    --region "$REGION" \
    --database-name "$DATABASE_NAME" \
    --query 'TableList[].Name' \
    --output text
)"

for table in $TABLES; do
  echo "Revoking IAM_ALLOWED_PRINCIPALS from table ${DATABASE_NAME}.${table}"
  revoke_iam_allowed "{\"Table\":{\"CatalogId\":\"${CATALOG_ID}\",\"DatabaseName\":\"${DATABASE_NAME}\",\"Name\":\"${table}\"}}"
done

echo "Remaining IAM_ALLOWED_PRINCIPALS grants for ${DATABASE_NAME}:"
aws lakeformation list-permissions \
  "${PROFILE_ARG[@]}" \
  --region "$REGION" \
  --output json |
  jq --arg database "$DATABASE_NAME" '
    [
      .PrincipalResourcePermissions[]
      | select(.Principal.DataLakePrincipalIdentifier == "IAM_ALLOWED_PRINCIPALS")
      | select(
          (.Resource.Database.Name? == $database)
          or (.Resource.Table.DatabaseName? == $database)
          or (.Resource.TableWithColumns.DatabaseName? == $database)
        )
      | {Resource, Permissions}
    ]
  '
