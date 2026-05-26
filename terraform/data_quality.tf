locals {
  glue_data_quality_role_name = "${local.name_prefix}-glue-data-quality"
  silver_dq_ruleset_name      = "${local.name_prefix}-silver-dq"
}

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_data_quality" {
  count = var.enable_glue_data_quality ? 1 : 0

  name               = local.glue_data_quality_role_name
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

resource "aws_iam_role_policy_attachment" "glue_data_quality_service" {
  count = var.enable_glue_data_quality ? 1 : 0

  role       = aws_iam_role.glue_data_quality[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_data_quality" {
  count = var.enable_glue_data_quality ? 1 : 0

  statement {
    sid = "LakeFormationDataAccess"
    actions = [
      "lakeformation:GetDataAccess"
    ]
    resources = ["*"]
  }

  statement {
    sid = "ReadGlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
      "glue:GetTables",
      "glue:GetUnfilteredPartitionMetadata",
      "glue:GetUnfilteredPartitionsMetadata",
      "glue:GetUnfilteredTableMetadata"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.citibike.name}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.citibike.name}/*"
    ]
  }

  statement {
    sid = "ReadAthenaAndWarehouseBuckets"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.lake["athena_results"].arn,
      aws_s3_bucket.lake["warehouse"].arn
    ]
  }

  statement {
    sid = "ReadWriteDataQualityResults"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = [
      "${aws_s3_bucket.lake["athena_results"].arn}/*",
      "${aws_s3_bucket.lake["warehouse"].arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "glue_data_quality" {
  count = var.enable_glue_data_quality ? 1 : 0

  name   = local.glue_data_quality_role_name
  role   = aws_iam_role.glue_data_quality[0].id
  policy = data.aws_iam_policy_document.glue_data_quality[0].json
}

resource "aws_glue_data_quality_ruleset" "citibike_trips_silver" {
  count = var.enable_glue_data_quality ? 1 : 0

  name        = local.silver_dq_ruleset_name
  description = "DQDL rules for the dbt Silver Citi Bike trips Iceberg table."
  ruleset = templatefile("${path.module}/dqdl/citibike_trips_silver.dqdl.tftpl", {
    start_date = var.citibike_start_date
  })

  target_table {
    catalog_id    = data.aws_caller_identity.current.account_id
    database_name = aws_glue_catalog_database.citibike.name
    table_name    = "citibike_trips_silver"
  }

  lifecycle {
    # Ruleset body is updated out-of-band by the dqdl-cd GitHub Actions
    # workflow. Terraform seeds the initial ruleset on first apply only.
    ignore_changes = [ruleset]
  }

  depends_on = [
    aws_iam_role_policy.glue_data_quality
  ]
}
