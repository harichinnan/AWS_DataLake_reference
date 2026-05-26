locals {
  quarantine_table_name        = "citibike_quarantined_partitions"
  quarantine_table_s3_location = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.warehouse_prefix}/quarantine/${local.quarantine_table_name}/"

  quarantine_template_vars = {
    database_name                = aws_glue_catalog_database.citibike.name
    quarantine_table_name        = local.quarantine_table_name
    quarantine_table_s3_location = local.quarantine_table_s3_location
  }

  quarantine_create_query = templatefile(
    "${path.module}/sql/06_create_quarantine_ledger.sql.tftpl",
    local.quarantine_template_vars
  )
}

resource "aws_athena_named_query" "create_quarantine_ledger" {
  name        = "06_create_quarantine_ledger"
  description = "Create the Iceberg ledger that tracks quarantined raw partitions."
  database    = aws_glue_catalog_database.citibike.name
  workgroup   = aws_athena_workgroup.citibike.name
  query       = local.quarantine_create_query
}

# Bootstrap the Iceberg table on apply. CREATE TABLE IF NOT EXISTS is idempotent.
# Requires the AWS CLI to be available on the machine running `terraform apply`.
resource "null_resource" "bootstrap_quarantine_ledger" {
  triggers = {
    query       = sha256(local.quarantine_create_query)
    workgroup   = aws_athena_workgroup.citibike.name
    database    = aws_glue_catalog_database.citibike.name
    aws_region  = data.aws_region.current.region
    s3_location = local.quarantine_table_s3_location
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      QUERY_ID=$(aws athena start-query-execution \
        --region "${data.aws_region.current.region}" \
        --work-group "${aws_athena_workgroup.citibike.name}" \
        --query-execution-context "Database=${aws_glue_catalog_database.citibike.name}" \
        --query-string "$(printf '%s' "${replace(local.quarantine_create_query, "\"", "\\\"")}")" \
        --query 'QueryExecutionId' \
        --output text)
      echo "Started Athena query: $QUERY_ID"
      for _ in $(seq 1 60); do
        STATE=$(aws athena get-query-execution \
          --region "${data.aws_region.current.region}" \
          --query-execution-id "$QUERY_ID" \
          --query 'QueryExecution.Status.State' --output text)
        echo "  state=$STATE"
        case "$STATE" in
          SUCCEEDED) exit 0 ;;
          FAILED|CANCELLED)
            REASON=$(aws athena get-query-execution \
              --region "${data.aws_region.current.region}" \
              --query-execution-id "$QUERY_ID" \
              --query 'QueryExecution.Status.StateChangeReason' --output text)
            echo "Athena query failed: $REASON" >&2
            exit 1
            ;;
        esac
        sleep 2
      done
      echo "Timed out waiting for Athena query" >&2
      exit 1
    EOT
  }

  depends_on = [
    aws_athena_workgroup.citibike,
    aws_glue_catalog_database.citibike,
    aws_s3_bucket.lake,
  ]
}

output "quarantine_ledger_table_name" {
  description = "Athena Iceberg table holding active and historical raw-partition quarantine entries."
  value       = local.quarantine_table_name
}

output "quarantine_ledger_create_named_query_id" {
  description = "Athena saved-query ID for the quarantine ledger DDL (idempotent CREATE TABLE IF NOT EXISTS)."
  value       = aws_athena_named_query.create_quarantine_ledger.id
}
