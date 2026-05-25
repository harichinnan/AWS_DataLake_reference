locals {
  lake_formation_data_access_role_name = "${local.name_prefix}-lakeformation-data-access"

  lake_formation_registered_locations = var.enable_lake_formation_governance ? {
    raw       = aws_s3_bucket.lake["raw"].arn
    warehouse = aws_s3_bucket.lake["warehouse"].arn
  } : {}

  lake_formation_readonly_principals = var.enable_lake_formation_governance ? merge(
    { for idx, arn in var.lake_formation_additional_readonly_principal_arns : "additional-${idx}" => arn },
    var.enable_metabase ? { metabase = aws_iam_role.metabase_task[0].arn } : {},
    var.enable_glue_data_quality ? { glue_data_quality = aws_iam_role.glue_data_quality[0].arn } : {}
  ) : {}

  lake_formation_data_location_principals = var.enable_lake_formation_governance ? merge(
    { for idx, arn in var.lake_formation_admin_principal_arns : "admin-${idx}" => arn },
    var.enable_glue_data_quality ? { glue_data_quality = aws_iam_role.glue_data_quality[0].arn } : {}
  ) : {}
}

data "aws_iam_policy_document" "lakeformation_data_access_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lakeformation.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lakeformation_data_access" {
  count = var.enable_lake_formation_governance ? 1 : 0

  name               = local.lake_formation_data_access_role_name
  assume_role_policy = data.aws_iam_policy_document.lakeformation_data_access_assume_role.json
}

data "aws_iam_policy_document" "lakeformation_data_access" {
  count = var.enable_lake_formation_governance ? 1 : 0

  statement {
    sid = "ListRegisteredLakeBuckets"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [
      aws_s3_bucket.lake["raw"].arn,
      aws_s3_bucket.lake["warehouse"].arn
    ]
  }

  statement {
    sid = "ReadWriteRegisteredLakeObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = [
      "${aws_s3_bucket.lake["raw"].arn}/*",
      "${aws_s3_bucket.lake["warehouse"].arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "lakeformation_data_access" {
  count = var.enable_lake_formation_governance ? 1 : 0

  name   = local.lake_formation_data_access_role_name
  role   = aws_iam_role.lakeformation_data_access[0].id
  policy = data.aws_iam_policy_document.lakeformation_data_access[0].json
}

resource "aws_lakeformation_data_lake_settings" "citibike" {
  count = var.enable_lake_formation_governance ? 1 : 0

  admins                                = toset(var.lake_formation_admin_principal_arns)
  allow_full_table_external_data_access = var.enable_glue_data_quality
}

resource "aws_lakeformation_resource" "lake" {
  for_each = local.lake_formation_registered_locations

  arn                   = each.value
  role_arn              = aws_iam_role.lakeformation_data_access[0].arn
  hybrid_access_enabled = var.lake_formation_hybrid_access_enabled

  depends_on = [
    aws_lakeformation_data_lake_settings.citibike,
    aws_iam_role_policy.lakeformation_data_access
  ]
}

resource "aws_lakeformation_permissions" "readonly_tables" {
  for_each = local.lake_formation_readonly_principals

  principal   = each.value
  permissions = ["DESCRIBE", "SELECT"]

  table {
    catalog_id    = data.aws_caller_identity.current.account_id
    database_name = aws_glue_catalog_database.citibike.name
    wildcard      = true
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.citibike,
    aws_lakeformation_resource.lake
  ]
}

resource "aws_lakeformation_permissions" "data_location" {
  for_each = {
    for pair in setproduct(keys(local.lake_formation_data_location_principals), keys(local.lake_formation_registered_locations)) :
    "${pair[0]}-${pair[1]}" => {
      principal = local.lake_formation_data_location_principals[pair[0]]
      location  = pair[1]
      arn       = local.lake_formation_registered_locations[pair[1]]
    }
  }

  principal   = each.value.principal
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    catalog_id = data.aws_caller_identity.current.account_id
    arn        = each.value.arn
  }

  depends_on = [
    aws_lakeformation_resource.lake
  ]
}
