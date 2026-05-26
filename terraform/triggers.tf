###############################################################################
# Triggers for the data pipeline state machine.                               #
# - S3 ObjectCreated events on raw/citibike/trips/year=*/month=*/             #
# - Daily cron safety net (configurable via var.pipeline_schedule_expression) #
# All gated on enable_pipeline_orchestration AND enable_glue_data_quality.    #
###############################################################################

locals {
  pipeline_kicker_name = "${local.name_prefix}-pipeline-kicker"
  pipeline_kicker_zip  = "${path.module}/../build/pipeline_kicker_lambda.zip"
}

###############################################################################
# Kicker Lambda — normalizes triggers and starts the state machine.
###############################################################################

data "archive_file" "pipeline_kicker" {
  count = local.pipeline_orchestration_active ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/../src/lambda/pipeline_kicker.py"
  output_path = local.pipeline_kicker_zip
}

resource "aws_iam_role" "pipeline_kicker" {
  count = local.pipeline_orchestration_active ? 1 : 0

  name = "${local.pipeline_kicker_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pipeline_kicker_basic" {
  count = local.pipeline_orchestration_active ? 1 : 0

  role       = aws_iam_role.pipeline_kicker[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "pipeline_kicker" {
  count = local.pipeline_orchestration_active ? 1 : 0

  statement {
    sid       = "StartPipelineExecution"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline[0].arn]
  }
}

resource "aws_iam_role_policy" "pipeline_kicker" {
  count = local.pipeline_orchestration_active ? 1 : 0

  name   = "${local.pipeline_kicker_name}-policy"
  role   = aws_iam_role.pipeline_kicker[0].id
  policy = data.aws_iam_policy_document.pipeline_kicker[0].json
}

resource "aws_cloudwatch_log_group" "pipeline_kicker" {
  count             = local.pipeline_orchestration_active ? 1 : 0
  name              = "/aws/lambda/${local.pipeline_kicker_name}"
  retention_in_days = var.glue_data_quality_event_processor_log_retention_days
}

resource "aws_lambda_function" "pipeline_kicker" {
  count = local.pipeline_orchestration_active ? 1 : 0

  function_name    = local.pipeline_kicker_name
  role             = aws_iam_role.pipeline_kicker[0].arn
  runtime          = "python3.12"
  handler          = "pipeline_kicker.handler"
  filename         = data.archive_file.pipeline_kicker[0].output_path
  source_code_hash = data.archive_file.pipeline_kicker[0].output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      STATE_MACHINE_ARN  = aws_sfn_state_machine.pipeline[0].arn
      DEFAULT_INCLUDE_JC = tostring(var.citibike_include_jc)
    }
  }

  depends_on = [
    aws_iam_role_policy.pipeline_kicker,
    aws_cloudwatch_log_group.pipeline_kicker,
  ]
}

###############################################################################
# S3 → EventBridge → Lambda
###############################################################################

resource "aws_s3_bucket_notification" "raw_eventbridge" {
  count = local.pipeline_orchestration_active ? 1 : 0

  bucket      = aws_s3_bucket.lake["raw"].id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "pipeline_s3_trigger" {
  count = local.pipeline_orchestration_active ? 1 : 0

  name        = "${local.pipeline_state_machine_name}-s3-trigger"
  description = "Starts the citibike data pipeline on new raw trip files."

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.lake["raw"].id] }
      object = { key = [{ prefix = "${local.raw_data_prefix}/trips/year=" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline_s3_trigger" {
  count = local.pipeline_orchestration_active ? 1 : 0

  rule = aws_cloudwatch_event_rule.pipeline_s3_trigger[0].name
  arn  = aws_lambda_function.pipeline_kicker[0].arn
}

resource "aws_lambda_permission" "pipeline_s3_trigger" {
  count = local.pipeline_orchestration_active ? 1 : 0

  statement_id  = "AllowEventBridgeS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_kicker[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_s3_trigger[0].arn
}

###############################################################################
# Daily cron safety net
###############################################################################

resource "aws_cloudwatch_event_rule" "pipeline_daily" {
  count = local.pipeline_orchestration_active && trimspace(var.pipeline_schedule_expression) != "" ? 1 : 0

  name                = "${local.pipeline_state_machine_name}-daily"
  description         = "Daily safety-net run of the citibike data pipeline."
  schedule_expression = var.pipeline_schedule_expression
}

resource "aws_cloudwatch_event_target" "pipeline_daily" {
  count = local.pipeline_orchestration_active && trimspace(var.pipeline_schedule_expression) != "" ? 1 : 0

  rule = aws_cloudwatch_event_rule.pipeline_daily[0].name
  arn  = aws_lambda_function.pipeline_kicker[0].arn

  input = jsonencode({ trigger_source = "schedule" })
}

resource "aws_lambda_permission" "pipeline_daily" {
  count = local.pipeline_orchestration_active && trimspace(var.pipeline_schedule_expression) != "" ? 1 : 0

  statement_id  = "AllowEventBridgeDailyInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_kicker[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_daily[0].arn
}

output "pipeline_kicker_lambda_name" {
  description = "Name of the kicker Lambda that starts pipeline executions."
  value       = local.pipeline_orchestration_active ? aws_lambda_function.pipeline_kicker[0].function_name : null
}
