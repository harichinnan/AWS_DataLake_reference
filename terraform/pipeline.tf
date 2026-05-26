###############################################################################
# Step Functions orchestrator: ingest → repair → Silver → Glue DQ →           #
# (quarantine | Gold). Gated on var.enable_pipeline_orchestration AND         #
# var.enable_glue_data_quality.                                               #
###############################################################################

locals {
  pipeline_orchestration_active = var.enable_pipeline_orchestration && var.enable_glue_data_quality

  pipeline_state_machine_name = "${local.name_prefix}-data-pipeline"
  pipeline_log_group_name     = "/aws/states/${local.pipeline_state_machine_name}"

  athena_results_state_machine_dir = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/state-machine/"
  glue_dq_results_prefix           = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/glue-data-quality/"

  pipeline_state_machine_definition = local.pipeline_orchestration_active ? templatefile(
    "${path.module}/pipeline_state_machine.json.tftpl",
    {
      athena_workgroup                 = aws_athena_workgroup.citibike.name
      database                         = aws_glue_catalog_database.citibike.name
      quarantine_table                 = local.quarantine_table_name
      athena_results_state_machine_dir = local.athena_results_state_machine_dir
      ingest_lambda_arn                = aws_lambda_function.citibike_ingest.arn
      dbt_job_definition_arn           = try(aws_batch_job_definition.dbt[0].arn, "")
      dbt_job_queue_arn                = try(aws_batch_job_queue.dbt[0].arn, "")
      glue_dq_role_arn                 = try(aws_iam_role.glue_data_quality[0].arn, "")
      dq_ruleset_name                  = try(aws_glue_data_quality_ruleset.citibike_trips_silver[0].name, "")
      glue_dq_workers                  = var.glue_data_quality_number_of_workers
      glue_dq_timeout_minutes          = var.glue_data_quality_timeout_minutes
      glue_dq_results_prefix           = local.glue_dq_results_prefix
      alerts_topic_arn                 = aws_sns_topic.citibike_data_alerts.arn
    }
  ) : ""
}

###############################################################################
# IAM role for the state machine
###############################################################################

data "aws_iam_policy_document" "pipeline_sfn_assume" {
  count = local.pipeline_orchestration_active ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline_sfn" {
  count = local.pipeline_orchestration_active ? 1 : 0

  name               = "${local.pipeline_state_machine_name}-role"
  assume_role_policy = data.aws_iam_policy_document.pipeline_sfn_assume[0].json
}

data "aws_iam_policy_document" "pipeline_sfn" {
  count = local.pipeline_orchestration_active ? 1 : 0

  statement {
    sid       = "InvokeIngestLambda"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.citibike_ingest.arn, "${aws_lambda_function.citibike_ingest.arn}:*"]
  }

  statement {
    sid     = "SubmitBatchJobs"
    actions = ["batch:SubmitJob", "batch:DescribeJobs", "batch:TerminateJob"]
    resources = [
      aws_batch_job_definition.dbt[0].arn,
      "${aws_batch_job_definition.dbt[0].arn}:*",
      aws_batch_job_queue.dbt[0].arn,
    ]
  }

  statement {
    sid = "BatchEventBridgeManagedRule"
    actions = [
      "events:PutTargets",
      "events:PutRule",
      "events:DescribeRule",
    ]
    resources = [
      "arn:aws:events:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:rule/StepFunctionsGetEventsForBatchJobsRule",
    ]
  }

  statement {
    sid = "AthenaQuery"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AthenaResultsBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      aws_s3_bucket.lake["athena_results"].arn,
      "${aws_s3_bucket.lake["athena_results"].arn}/*",
      aws_s3_bucket.lake["warehouse"].arn,
      "${aws_s3_bucket.lake["warehouse"].arn}/*",
    ]
  }

  statement {
    sid = "GlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:UpdateTable",
    ]
    resources = [
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.citibike.name}",
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.citibike.name}/*",
    ]
  }

  statement {
    sid = "GlueDataQuality"
    actions = [
      "glue:StartDataQualityRulesetEvaluationRun",
      "glue:GetDataQualityRulesetEvaluationRun",
      "glue:GetDataQualityResult",
      "glue:GetDataQualityRuleset",
      "glue:ListDataQualityResults",
      "glue:ListDataQualityRulesetEvaluationRuns",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassGlueDQRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.glue_data_quality[0].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["glue.amazonaws.com"]
    }
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.citibike_data_alerts.arn]
  }

  statement {
    sid       = "LakeFormationDataAccess"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }

  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "pipeline_sfn" {
  count = local.pipeline_orchestration_active ? 1 : 0

  name   = "${local.pipeline_state_machine_name}-policy"
  role   = aws_iam_role.pipeline_sfn[0].id
  policy = data.aws_iam_policy_document.pipeline_sfn[0].json
}

###############################################################################
# Lake Formation grants for the state machine role (when LF governance is on)
###############################################################################

resource "aws_lakeformation_permissions" "pipeline_sfn_database" {
  count = local.pipeline_orchestration_active && var.enable_lake_formation_governance ? 1 : 0

  principal   = aws_iam_role.pipeline_sfn[0].arn
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.citibike.name
  }
}

resource "aws_lakeformation_permissions" "pipeline_sfn_tables" {
  count = local.pipeline_orchestration_active && var.enable_lake_formation_governance ? 1 : 0

  principal   = aws_iam_role.pipeline_sfn[0].arn
  permissions = ["SELECT", "DESCRIBE", "INSERT", "DELETE", "ALTER"]

  table {
    database_name = aws_glue_catalog_database.citibike.name
    wildcard      = true
  }
}

###############################################################################
# Log group + state machine
###############################################################################

resource "aws_cloudwatch_log_group" "pipeline_sfn" {
  count             = local.pipeline_orchestration_active ? 1 : 0
  name              = local.pipeline_log_group_name
  retention_in_days = var.glue_data_quality_event_processor_log_retention_days
}

resource "aws_sfn_state_machine" "pipeline" {
  count    = local.pipeline_orchestration_active ? 1 : 0
  name     = local.pipeline_state_machine_name
  role_arn = aws_iam_role.pipeline_sfn[0].arn

  definition = local.pipeline_state_machine_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.pipeline_sfn[0].arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  depends_on = [
    aws_iam_role_policy.pipeline_sfn,
    aws_batch_job_definition.dbt,
    aws_batch_job_queue.dbt,
  ]
}

output "pipeline_state_machine_arn" {
  description = "ARN of the citibike data pipeline state machine (only present when orchestration is enabled)."
  value       = local.pipeline_orchestration_active ? aws_sfn_state_machine.pipeline[0].arn : null
}
