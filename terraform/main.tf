data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix      = "${var.project_name}-${var.environment}"
  glue_database    = var.glue_database_name == null ? replace("${var.project_name}_${var.environment}", "-", "_") : var.glue_database_name
  bucket_prefix    = var.bucket_name_prefix == null ? "${var.project_name}-${var.environment}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}" : var.bucket_name_prefix
  raw_data_prefix  = trimsuffix(trimprefix(var.raw_data_prefix, "/"), "/")
  warehouse_prefix = trimsuffix(trimprefix(var.warehouse_prefix, "/"), "/")
  lambda_name      = "${local.name_prefix}-citibike-ingest"
  athena_workgroup = "${local.name_prefix}-wg"

  buckets = {
    raw            = "${local.bucket_prefix}-raw"
    warehouse      = "${local.bucket_prefix}-warehouse"
    athena_results = "${local.bucket_prefix}-athena-results"
  }
}

resource "aws_s3_bucket" "lake" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "lake" {
  for_each = aws_s3_bucket.lake

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  for_each = aws_s3_bucket.lake

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "lake" {
  for_each = aws_s3_bucket.lake

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  for_each = aws_s3_bucket.lake

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.lake["athena_results"].id

  rule {
    id     = "expire-athena-query-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = var.athena_results_retention_days
    }
  }
}

resource "aws_glue_catalog_database" "citibike" {
  name        = local.glue_database
  description = "Citi Bike data lake database for raw CSV and Athena Iceberg tables."
}

resource "aws_athena_workgroup" "citibike" {
  name          = local.athena_workgroup
  description   = "Athena engine v3 workgroup for the Citi Bike Iceberg data lake."
  state         = "ENABLED"
  force_destroy = true

  configuration {
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff_bytes
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

data "archive_file" "citibike_ingest" {
  type        = "zip"
  source_file = "${path.module}/../src/lambda/ingest_citibike.py"
  output_path = "${path.module}/../build/citibike_ingest_lambda.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "citibike_ingest" {
  name               = "${local.name_prefix}-citibike-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_cloudwatch_log_group" "citibike_ingest" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.citibike_ingest.arn}:*"]
  }

  statement {
    sid = "ListRawBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [aws_s3_bucket.lake["raw"].arn]
  }

  statement {
    sid = "WriteRawObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.lake["raw"].arn}/*"]
  }
}

resource "aws_iam_role_policy" "citibike_ingest" {
  name   = "${local.name_prefix}-citibike-ingest"
  role   = aws_iam_role.citibike_ingest.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_lambda_function" "citibike_ingest" {
  function_name    = local.lambda_name
  description      = "Downloads monthly Citi Bike ZIP CSV files, extracts CSVs, and writes raw files to S3."
  role             = aws_iam_role.citibike_ingest.arn
  handler          = "ingest_citibike.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.citibike_ingest.output_path
  source_code_hash = data.archive_file.citibike_ingest.output_base64sha256
  timeout          = 900
  memory_size      = var.lambda_memory_mb

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  environment {
    variables = {
      RAW_BUCKET         = aws_s3_bucket.lake["raw"].bucket
      RAW_PREFIX         = local.raw_data_prefix
      CITIBIKE_BASE_URL  = var.citibike_base_url
      DEFAULT_MONTHS     = jsonencode(var.citibike_months)
      DEFAULT_INCLUDE_JC = tostring(var.citibike_include_jc)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.citibike_ingest,
    aws_iam_role_policy.citibike_ingest
  ]

  lifecycle {
    # Lambda code is updated out-of-band by the lambda-cd GitHub Actions
    # workflow (aws lambda update-function-code). Terraform only seeds the
    # initial code on first apply and manages configuration thereafter.
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_cloudwatch_event_rule" "monthly_ingestion" {
  count = var.enable_monthly_ingestion_schedule ? 1 : 0

  name                = "${local.name_prefix}-citibike-monthly-ingest"
  description         = "Invokes Citi Bike ingestion Lambda for the previous month."
  schedule_expression = var.monthly_ingestion_schedule_expression
}

resource "aws_cloudwatch_event_target" "monthly_ingestion" {
  count = var.enable_monthly_ingestion_schedule ? 1 : 0

  rule = aws_cloudwatch_event_rule.monthly_ingestion[0].name
  arn  = aws_lambda_function.citibike_ingest.arn

  input = jsonencode({
    months     = "previous"
    include_jc = var.citibike_include_jc
  })
}

resource "aws_lambda_permission" "allow_eventbridge_monthly_ingestion" {
  count = var.enable_monthly_ingestion_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.citibike_ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_ingestion[0].arn
}

locals {
  raw_trips_s3_location     = "s3://${aws_s3_bucket.lake["raw"].bucket}/${local.raw_data_prefix}/trips/"
  iceberg_trips_s3_location = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.warehouse_prefix}/trips/"

  athena_template_vars = {
    database                  = aws_glue_catalog_database.citibike.name
    raw_table                 = "citibike_trips_raw"
    iceberg_table             = "citibike_trips_iceberg"
    raw_trips_s3_location     = local.raw_trips_s3_location
    iceberg_trips_s3_location = local.iceberg_trips_s3_location
  }

  athena_named_queries = {
    create_raw_table = {
      name        = "01_create_raw_citibike_trips"
      description = "Create the raw partitioned Citi Bike CSV table."
      file        = "01_create_raw_table.sql.tftpl"
    }
    repair_raw_partitions = {
      name        = "02_repair_raw_citibike_partitions"
      description = "Discover year/month partitions in the raw Citi Bike table."
      file        = "02_repair_raw_partitions.sql.tftpl"
    }
    create_iceberg_table = {
      name        = "03_create_iceberg_citibike_trips"
      description = "Create the Athena Iceberg Citi Bike trips table."
      file        = "03_create_iceberg_table.sql.tftpl"
    }
    merge_raw_to_iceberg = {
      name        = "04_merge_raw_to_iceberg"
      description = "Idempotently merge typed raw Citi Bike rows into Iceberg by ride_id."
      file        = "04_merge_raw_to_iceberg.sql.tftpl"
    }
    sample_queries = {
      name        = "05_sample_citibike_queries"
      description = "Sample Athena queries against the Iceberg table."
      file        = "05_sample_queries.sql.tftpl"
    }
  }
}

resource "aws_athena_named_query" "citibike" {
  for_each = local.athena_named_queries

  name        = each.value.name
  description = each.value.description
  database    = aws_glue_catalog_database.citibike.name
  workgroup   = aws_athena_workgroup.citibike.name
  query       = templatefile("${path.module}/sql/${each.value.file}", local.athena_template_vars)
}

data "aws_iam_policy_document" "athena_runner" {
  statement {
    sid = "RunAthenaQueries"
    actions = [
      "athena:BatchGetNamedQuery",
      "athena:GetNamedQuery",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:ListNamedQueries",
      "athena:ListQueryExecutions",
      "athena:StartQueryExecution",
      "athena:StopQueryExecution"
    ]
    resources = ["*"]
  }

  statement {
    sid = "UseLakeFormationDataAccess"
    actions = [
      "lakeformation:GetDataAccess"
    ]
    resources = ["*"]
  }

  statement {
    sid = "RunGlueDataQuality"
    actions = [
      "glue:BatchGetDataQualityResult",
      "glue:GetDataQualityResult",
      "glue:GetDataQualityRuleset",
      "glue:GetDataQualityRulesetEvaluationRun",
      "glue:ListDataQualityResults",
      "glue:ListDataQualityRulesetEvaluationRuns",
      "glue:ListDataQualityRulesets",
      "glue:StartDataQualityRulesetEvaluationRun"
    ]
    resources = ["*"]
  }

  statement {
    sid = "PassGlueDataQualityRole"
    actions = [
      "iam:PassRole"
    ]
    resources = var.enable_glue_data_quality ? [aws_iam_role.glue_data_quality[0].arn] : ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["glue.amazonaws.com"]
    }
  }

  statement {
    sid = "UseGlueCatalogDatabase"
    actions = [
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:CreateTable",
      "glue:DeletePartition",
      "glue:DeleteTable",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetUserDefinedFunction",
      "glue:GetUserDefinedFunctions",
      "glue:UpdatePartition",
      "glue:UpdateTable"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.citibike.name}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.citibike.name}/*"
    ]
  }

  statement {
    sid = "ListLakeBuckets"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [for bucket in aws_s3_bucket.lake : bucket.arn]
  }

  statement {
    sid = "ReadRawObjects"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.lake["raw"].arn}/*"]
  }

  statement {
    sid = "WriteWarehouseAndResultsObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = [
      "${aws_s3_bucket.lake["warehouse"].arn}/*",
      "${aws_s3_bucket.lake["athena_results"].arn}/*"
    ]
  }

  statement {
    sid = "InvokeCitibikeIngestion"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [aws_lambda_function.citibike_ingest.arn]
  }
}

resource "aws_iam_policy" "athena_runner" {
  name        = "${local.name_prefix}-athena-runner"
  description = "Permissions for a user or role to ingest Citi Bike data and run Athena Iceberg setup queries."
  policy      = data.aws_iam_policy_document.athena_runner.json
}
