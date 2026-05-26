locals {
  data_alerts_topic_name = "${local.name_prefix}-data-alerts"
  alerts_email_enabled   = trimspace(var.alert_email) != ""
  alerts_slack_enabled   = trimspace(var.alert_slack_webhook_url) != ""
}

resource "aws_sns_topic" "citibike_data_alerts" {
  name              = local.data_alerts_topic_name
  kms_master_key_id = "alias/aws/sns"
}

data "aws_iam_policy_document" "citibike_data_alerts_publish" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.citibike_data_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "citibike_data_alerts" {
  arn    = aws_sns_topic.citibike_data_alerts.arn
  policy = data.aws_iam_policy_document.citibike_data_alerts_publish.json
}

resource "aws_sns_topic_subscription" "citibike_data_alerts_email" {
  count = local.alerts_email_enabled ? 1 : 0

  topic_arn = aws_sns_topic.citibike_data_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "citibike_data_alerts_slack" {
  count = local.alerts_slack_enabled ? 1 : 0

  topic_arn              = aws_sns_topic.citibike_data_alerts.arn
  protocol               = "https"
  endpoint               = var.alert_slack_webhook_url
  endpoint_auto_confirms = true
}

resource "aws_cloudwatch_event_rule" "glue_dq_failures" {
  count = var.enable_glue_data_quality ? 1 : 0

  name        = "${local.name_prefix}-glue-dq-failures"
  description = "Routes Glue Data Quality failure events to the data alerts SNS topic."

  event_pattern = jsonencode({
    source        = ["aws.glue-dataquality"]
    "detail-type" = ["Data Quality Evaluation Results Available"]
    detail = {
      state = [{ "anything-but" = "SUCCEEDED" }]
      context = {
        databaseName = [aws_glue_catalog_database.citibike.name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_dq_failures_sns" {
  count = var.enable_glue_data_quality ? 1 : 0

  rule = aws_cloudwatch_event_rule.glue_dq_failures[0].name
  arn  = aws_sns_topic.citibike_data_alerts.arn

  input_transformer {
    input_paths = {
      database = "$.detail.context.databaseName"
      table    = "$.detail.context.tableName"
      state    = "$.detail.state"
      score    = "$.detail.score"
      result   = "$.detail.resultId"
      time     = "$.time"
    }

    input_template = <<-EOT
      "Glue Data Quality failure for <database>.<table> at <time>. State=<state>, Score=<score>, ResultId=<result>. Inspect citibike_glue_dq_rule_results for failing rules."
    EOT
  }
}
