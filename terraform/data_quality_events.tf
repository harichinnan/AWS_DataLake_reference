locals {
  glue_dq_event_observability_enabled = var.enable_glue_data_quality && var.enable_glue_data_quality_event_observability
  glue_dq_event_observability_prefix  = trimsuffix(trimprefix(var.glue_data_quality_event_observability_prefix, "/"), "/")

  glue_dq_event_processor_name      = "${local.name_prefix}-glue-dq-events"
  glue_dq_event_state_machine_name  = "${local.name_prefix}-glue-dq-events"
  glue_dq_run_events_table_name     = "citibike_glue_dq_run_events"
  glue_dq_rule_results_table_name   = "citibike_glue_dq_rule_results"
  glue_dq_run_events_s3_location    = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.glue_dq_event_observability_prefix}/run-events/"
  glue_dq_rule_results_s3_location  = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.glue_dq_event_observability_prefix}/rule-results/"
  glue_dq_run_events_storage_tmpl   = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.glue_dq_event_observability_prefix}/run-events/event_date=$${event_date}/"
  glue_dq_rule_results_storage_tmpl = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.glue_dq_event_observability_prefix}/rule-results/event_date=$${event_date}/"

  glue_dq_projection_parameters = {
    "classification"                      = "json"
    "EXTERNAL"                            = "TRUE"
    "projection.enabled"                  = "true"
    "projection.event_date.type"          = "date"
    "projection.event_date.format"        = "yyyy-MM-dd"
    "projection.event_date.range"         = "${var.citibike_start_date},NOW"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    "skip.header.line.count"              = "0"
    "write.compression"                   = "none"
  }
}

data "archive_file" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/../src/lambda/process_glue_dq_event.py"
  output_path = "${path.module}/../build/glue_dq_event_processor_lambda.zip"
}

resource "aws_iam_role" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name               = local.glue_dq_event_processor_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_cloudwatch_log_group" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name              = "/aws/lambda/${local.glue_dq_event_processor_name}"
  retention_in_days = var.glue_data_quality_event_processor_log_retention_days
}

data "aws_iam_policy_document" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.glue_dq_event_processor[0].arn}:*"]
  }

  statement {
    sid = "ReadGlueDataQualityResult"
    actions = [
      "glue:GetDataQualityResult"
    ]
    resources = ["*"]
  }

  statement {
    sid = "ListWarehouseBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.lake["warehouse"].arn]
  }

  statement {
    sid = "WriteObservabilityObjects"
    actions = [
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.lake["warehouse"].arn}/${local.glue_dq_event_observability_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name   = local.glue_dq_event_processor_name
  role   = aws_iam_role.glue_dq_event_processor[0].id
  policy = data.aws_iam_policy_document.glue_dq_event_processor[0].json
}

resource "aws_lambda_function" "glue_dq_event_processor" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  function_name    = local.glue_dq_event_processor_name
  description      = "Normalizes Glue Data Quality EventBridge events into Athena-readable S3 JSONL tables."
  role             = aws_iam_role.glue_dq_event_processor[0].arn
  handler          = "process_glue_dq_event.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.glue_dq_event_processor[0].output_path
  source_code_hash = data.archive_file.glue_dq_event_processor[0].output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      OUTPUT_BUCKET       = aws_s3_bucket.lake["warehouse"].bucket
      RUN_EVENTS_PREFIX   = "${local.glue_dq_event_observability_prefix}/run-events"
      RULE_RESULTS_PREFIX = "${local.glue_dq_event_observability_prefix}/rule-results"
      TARGET_RULESET_NAME = aws_glue_data_quality_ruleset.citibike_trips_silver[0].name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.glue_dq_event_processor,
    aws_iam_role_policy.glue_dq_event_processor
  ]

  lifecycle {
    # Code updates flow through lambda-cd; Terraform only seeds initial code.
    ignore_changes = [filename, source_code_hash]
  }
}

data "aws_iam_policy_document" "stepfunctions_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_dq_event_state_machine" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name               = "${local.glue_dq_event_state_machine_name}-sfn"
  assume_role_policy = data.aws_iam_policy_document.stepfunctions_assume_role.json
}

data "aws_iam_policy_document" "glue_dq_event_state_machine" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  statement {
    sid = "InvokeEventProcessor"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [
      aws_lambda_function.glue_dq_event_processor[0].arn,
      "${aws_lambda_function.glue_dq_event_processor[0].arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "glue_dq_event_state_machine" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name   = "${local.glue_dq_event_state_machine_name}-sfn"
  role   = aws_iam_role.glue_dq_event_state_machine[0].id
  policy = data.aws_iam_policy_document.glue_dq_event_state_machine[0].json
}

resource "aws_sfn_state_machine" "glue_dq_event_observability" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name     = local.glue_dq_event_state_machine_name
  role_arn = aws_iam_role.glue_dq_event_state_machine[0].arn

  definition = jsonencode({
    Comment = "Persist Glue Data Quality EventBridge events into Athena-readable observability tables."
    StartAt = "Persist Glue DQ event"
    States = {
      "Persist Glue DQ event" = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.glue_dq_event_processor[0].arn
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        End        = true
      }
    }
  })

  depends_on = [
    aws_iam_role_policy.glue_dq_event_state_machine
  ]
}

data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_dq_eventbridge" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name               = "${local.glue_dq_event_state_machine_name}-events"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json
}

data "aws_iam_policy_document" "glue_dq_eventbridge" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  statement {
    sid = "StartStateMachine"
    actions = [
      "states:StartExecution"
    ]
    resources = [aws_sfn_state_machine.glue_dq_event_observability[0].arn]
  }
}

resource "aws_iam_role_policy" "glue_dq_eventbridge" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name   = "${local.glue_dq_event_state_machine_name}-events"
  role   = aws_iam_role.glue_dq_eventbridge[0].id
  policy = data.aws_iam_policy_document.glue_dq_eventbridge[0].json
}

resource "aws_cloudwatch_event_rule" "glue_dq_results" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name        = "${local.name_prefix}-glue-dq-results"
  description = "Starts the Glue DQ observability workflow when Silver table data quality results are available."

  event_pattern = jsonencode({
    source        = ["aws.glue-dataquality"]
    "detail-type" = ["Data Quality Evaluation Results Available"]
    detail = {
      resultId = [{ exists = true }]
      context = {
        databaseName = [aws_glue_catalog_database.citibike.name]
        tableName    = ["citibike_trips_silver"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_dq_results" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  rule     = aws_cloudwatch_event_rule.glue_dq_results[0].name
  arn      = aws_sfn_state_machine.glue_dq_event_observability[0].arn
  role_arn = aws_iam_role.glue_dq_eventbridge[0].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }

  depends_on = [
    aws_iam_role_policy.glue_dq_eventbridge
  ]
}

resource "aws_glue_catalog_table" "glue_dq_run_events" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name          = local.glue_dq_run_events_table_name
  database_name = aws_glue_catalog_database.citibike.name
  table_type    = "EXTERNAL_TABLE"
  parameters = merge(local.glue_dq_projection_parameters, {
    "storage.location.template" = local.glue_dq_run_events_storage_tmpl
  })

  partition_keys {
    name = "event_date"
    type = "string"
  }

  storage_descriptor {
    location      = local.glue_dq_run_events_s3_location
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
      }
    }

    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_time"
      type = "string"
    }
    columns {
      name = "observed_at"
      type = "string"
    }
    columns {
      name = "account_id"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
    columns {
      name = "source"
      type = "string"
    }
    columns {
      name = "detail_type"
      type = "string"
    }
    columns {
      name = "result_id"
      type = "string"
    }
    columns {
      name = "profile_id"
      type = "string"
    }
    columns {
      name = "ruleset_name"
      type = "string"
    }
    columns {
      name = "ruleset_names"
      type = "array<string>"
    }
    columns {
      name = "state"
      type = "string"
    }
    columns {
      name = "score"
      type = "double"
    }
    columns {
      name = "rules_succeeded"
      type = "int"
    }
    columns {
      name = "rules_failed"
      type = "int"
    }
    columns {
      name = "rules_skipped"
      type = "int"
    }
    columns {
      name = "rules_other"
      type = "int"
    }
    columns {
      name = "run_id"
      type = "string"
    }
    columns {
      name = "context_type"
      type = "string"
    }
    columns {
      name = "catalog_id"
      type = "string"
    }
    columns {
      name = "database_name"
      type = "string"
    }
    columns {
      name = "table_name"
      type = "string"
    }
    columns {
      name = "job_id"
      type = "string"
    }
    columns {
      name = "job_name"
      type = "string"
    }
    columns {
      name = "evaluation_context"
      type = "string"
    }
    columns {
      name = "started_on"
      type = "string"
    }
    columns {
      name = "completed_on"
      type = "string"
    }
    columns {
      name = "completed_run_id"
      type = "string"
    }
  }

  depends_on = [
    aws_lakeformation_resource.lake
  ]
}

resource "aws_glue_catalog_table" "glue_dq_rule_results" {
  count = local.glue_dq_event_observability_enabled ? 1 : 0

  name          = local.glue_dq_rule_results_table_name
  database_name = aws_glue_catalog_database.citibike.name
  table_type    = "EXTERNAL_TABLE"
  parameters = merge(local.glue_dq_projection_parameters, {
    "storage.location.template" = local.glue_dq_rule_results_storage_tmpl
  })

  partition_keys {
    name = "event_date"
    type = "string"
  }

  storage_descriptor {
    location      = local.glue_dq_rule_results_s3_location
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
      }
    }

    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_time"
      type = "string"
    }
    columns {
      name = "observed_at"
      type = "string"
    }
    columns {
      name = "result_id"
      type = "string"
    }
    columns {
      name = "profile_id"
      type = "string"
    }
    columns {
      name = "ruleset_name"
      type = "string"
    }
    columns {
      name = "run_id"
      type = "string"
    }
    columns {
      name = "database_name"
      type = "string"
    }
    columns {
      name = "table_name"
      type = "string"
    }
    columns {
      name = "state"
      type = "string"
    }
    columns {
      name = "score"
      type = "double"
    }
    columns {
      name = "rule_name"
      type = "string"
    }
    columns {
      name = "rule_description"
      type = "string"
    }
    columns {
      name = "rule_result"
      type = "string"
    }
    columns {
      name = "evaluation_message"
      type = "string"
    }
    columns {
      name = "evaluated_metrics_json"
      type = "string"
    }
  }

  depends_on = [
    aws_lakeformation_resource.lake
  ]
}
