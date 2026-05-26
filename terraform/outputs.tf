output "aws_account_id" {
  description = "AWS account where resources were created."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region where resources were created."
  value       = data.aws_region.current.region
}

output "s3_buckets" {
  description = "Data lake bucket names."
  value       = { for name, bucket in aws_s3_bucket.lake : name => bucket.bucket }
}

output "raw_trips_s3_location" {
  description = "Raw Citi Bike trips table S3 location."
  value       = local.raw_trips_s3_location
}

output "iceberg_trips_s3_location" {
  description = "Athena Iceberg trips table S3 location."
  value       = local.iceberg_trips_s3_location
}

output "glue_database_name" {
  description = "Glue Data Catalog database used by Athena."
  value       = aws_glue_catalog_database.citibike.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup configured for engine version 3."
  value       = aws_athena_workgroup.citibike.name
}

output "athena_named_query_ids" {
  description = "Saved Athena setup/query IDs, intended to be run in numeric order."
  value       = { for name, query in aws_athena_named_query.citibike : name => query.id }
}

output "citibike_ingest_lambda_name" {
  description = "Lambda function that downloads Citi Bike ZIP CSV files and writes raw CSVs to S3."
  value       = aws_lambda_function.citibike_ingest.function_name
}

output "citibike_ingest_example_command" {
  description = "Example AWS CLI command to ingest the configured months."
  value       = "aws lambda invoke --function-name ${aws_lambda_function.citibike_ingest.function_name} --payload '${jsonencode({ months = var.citibike_months, include_jc = var.citibike_include_jc })}' --cli-binary-format raw-in-base64-out /tmp/citibike-ingest.json --region ${data.aws_region.current.region}"
}

output "run_named_query_example_command" {
  description = "Example command for running one saved Athena named query by ID."
  value       = "bash scripts/run_named_query.sh ${aws_athena_named_query.citibike["create_raw_table"].id} ${aws_athena_workgroup.citibike.name} ${data.aws_region.current.region}"
}

output "athena_runner_policy_arn" {
  description = "IAM policy ARN to attach to users/roles that should run ingestion and Athena setup queries."
  value       = aws_iam_policy.athena_runner.arn
}

output "metabase_url" {
  description = "Public URL for Metabase when enable_metabase is true."
  value       = try("http://${aws_lb.metabase[0].dns_name}", null)
}

output "metabase_admin_secret_arn" {
  description = "Secrets Manager ARN containing the initial Metabase admin email and password."
  value       = try(aws_secretsmanager_secret.metabase_admin[0].arn, null)
}

output "metabase_athena_staging_dir" {
  description = "S3 staging directory configured for Metabase Athena query results."
  value       = try(local.metabase_athena_staging_dir, null)
}

output "metabase_gold_table_name" {
  description = "Gold table used by the Metabase seed dashboard."
  value       = try(local.metabase_gold_table_name, null)
}

output "metabase_ecs_cluster_name" {
  description = "ECS cluster running Metabase."
  value       = try(aws_ecs_cluster.metabase[0].name, null)
}

output "metabase_ecs_service_name" {
  description = "ECS service running Metabase."
  value       = try(aws_ecs_service.metabase[0].name, null)
}

output "metabase_seed_command" {
  description = "Command to initialize Metabase and create the Athena Gold dashboard after the service is healthy."
  value       = var.enable_metabase ? "AWS_PROFILE=<profile> python3 scripts/setup_metabase.py" : null
}

output "glue_data_quality_role_arn" {
  description = "IAM role ARN used by AWS Glue Data Quality evaluation runs."
  value       = try(aws_iam_role.glue_data_quality[0].arn, null)
}

output "lake_formation_data_access_role_arn" {
  description = "IAM role Lake Formation uses to vend scoped S3 credentials for registered data lake locations."
  value       = try(aws_iam_role.lakeformation_data_access[0].arn, null)
}

output "silver_data_quality_ruleset_name" {
  description = "AWS Glue Data Quality DQDL ruleset for the Silver Citi Bike trips table."
  value       = try(aws_glue_data_quality_ruleset.citibike_trips_silver[0].name, null)
}

output "run_silver_data_quality_command" {
  description = "Command to run the Glue Data Quality DQDL ruleset against the Silver table."
  value       = var.enable_glue_data_quality ? "AWS_PROFILE=<profile> bash scripts/run_glue_data_quality.sh" : null
}

output "glue_data_quality_event_state_machine_arn" {
  description = "Step Functions state machine that persists Glue Data Quality result events to Athena-readable S3 tables."
  value       = try(aws_sfn_state_machine.glue_dq_event_observability[0].arn, null)
}

output "glue_data_quality_eventbridge_rule_name" {
  description = "EventBridge rule that captures Glue Data Quality result events for the Silver table."
  value       = try(aws_cloudwatch_event_rule.glue_dq_results[0].name, null)
}

output "glue_dq_run_events_table_name" {
  description = "Athena table name for normalized Glue Data Quality run-level events."
  value       = local.glue_dq_run_events_table_name
}

output "glue_dq_rule_results_table_name" {
  description = "Athena table name for normalized Glue Data Quality rule-level results."
  value       = local.glue_dq_rule_results_table_name
}

output "citibike_data_alerts_topic_arn" {
  description = "SNS topic ARN that receives Glue DQ failures and pipeline alerts."
  value       = aws_sns_topic.citibike_data_alerts.arn
}
