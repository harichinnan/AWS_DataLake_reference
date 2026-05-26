###############################################################################
# GitHub Actions OIDC trust + scoped IAM roles + artifacts S3 bucket.         #
#                                                                             #
# Two roles trusted via token.actions.githubusercontent.com:                  #
# - gha-infra:    used by infra-*.yml workflows (terraform plan/apply)        #
# - gha-pipeline: used by dbt-cd/dqdl-cd/lambda-cd/image-cd workflows         #
#                                                                             #
# Both are scoped to `repo:<org>/<repo>:*` — branch- and PR-level constraints #
# can be added by tightening the `sub` condition.                             #
###############################################################################

locals {
  github_oidc_url        = "https://token.actions.githubusercontent.com"
  github_oidc_audiences  = ["sts.amazonaws.com"]
  github_oidc_thumbprint = "6938fd4d98bab03faadb97b34396831e3780aea1"

  github_sub_pattern = "repo:${var.github_org}/${var.github_repo}:*"

  artifacts_bucket_name = "${local.name_prefix}-artifacts-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"

  gha_infra_role_name    = "${local.name_prefix}-gha-infra"
  gha_pipeline_role_name = "${local.name_prefix}-gha-pipeline"
  gha_ci_role_name       = "${local.name_prefix}-gha-ci"

  # PR slim-CI runs build into per-PR Glue databases under this prefix. dbt
  # creates the databases on demand; cleanup workflow drops them on PR close.
  ci_glue_database_prefix = "${local.glue_database}_ci_pr_"

  # CI dbt build writes Iceberg data here (separate from the prod dbt prefix).
  ci_warehouse_prefix = "${local.warehouse_prefix}/dbt-ci"
}

###############################################################################
# OIDC provider
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = local.github_oidc_audiences
  thumbprint_list = [local.github_oidc_thumbprint]
}

###############################################################################
# Trust policy shared by both roles
###############################################################################

data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = local.github_oidc_audiences
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_pattern]
    }
  }
}

###############################################################################
# Artifacts S3 bucket — versioned, used by dbt-cd / dqdl-cd / lambda-cd.
###############################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket_name
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-noncurrent-after-90-days"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

###############################################################################
# gha-infra — Terraform admin
###############################################################################

resource "aws_iam_role" "gha_infra" {
  name               = local.gha_infra_role_name
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
  description        = "Assumed by GitHub Actions infra-*.yml workflows for terraform plan / apply."
}

resource "aws_iam_role_policy_attachment" "gha_infra_power" {
  role       = aws_iam_role.gha_infra.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "gha_infra_iam" {
  role       = aws_iam_role.gha_infra.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

###############################################################################
# gha-pipeline — narrow scope for publishing pipeline artifacts
###############################################################################

resource "aws_iam_role" "gha_pipeline" {
  name               = local.gha_pipeline_role_name
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
  description        = "Assumed by GitHub Actions dbt-cd/dqdl-cd/lambda-cd/image-cd workflows."
}

data "aws_iam_policy_document" "gha_pipeline" {
  statement {
    sid = "ArtifactsBucketReadWrite"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "ArtifactsBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid = "ECRAuth"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ECRPushDbtRunner"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
    ]
    resources = local.pipeline_orchestration_active ? [aws_ecr_repository.dbt_runner[0].arn] : ["*"]
  }

  statement {
    sid = "LambdaUpdateCode"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:PublishVersion",
    ]
    resources = compact([
      aws_lambda_function.citibike_ingest.arn,
      try(aws_lambda_function.glue_dq_event_processor[0].arn, ""),
      try(aws_lambda_function.pipeline_kicker[0].arn, ""),
    ])
  }

  statement {
    sid = "GlueUpdateDataQualityRuleset"
    actions = [
      "glue:UpdateDataQualityRuleset",
      "glue:GetDataQualityRuleset",
    ]
    resources = ["*"]
  }

  statement {
    sid = "LakeFormationApplyTags"
    actions = [
      "lakeformation:AddLFTagsToResource",
      "lakeformation:RemoveLFTagsFromResource",
      "lakeformation:GetResourceLFTags",
      "lakeformation:ListLFTags",
      "lakeformation:GetLFTag",
    ]
    resources = ["*"]
  }

  statement {
    sid = "StepFunctionsStartExecution"
    actions = [
      "states:StartExecution",
      "states:DescribeExecution",
    ]
    resources = local.pipeline_orchestration_active ? [
      aws_sfn_state_machine.pipeline[0].arn,
      "${aws_sfn_state_machine.pipeline[0].arn}:*",
    ] : ["*"]
  }
}

resource "aws_iam_role_policy" "gha_pipeline" {
  name   = "${local.gha_pipeline_role_name}-policy"
  role   = aws_iam_role.gha_pipeline.id
  policy = data.aws_iam_policy_document.gha_pipeline.json
}

###############################################################################
# gha-ci — pull_request-scoped role used by dbt-ci.yml for slim CI builds.   #
#                                                                             #
# Trust is locked to GitHub OIDC tokens with sub=`...:pull_request` (so push  #
# and workflow_dispatch tokens cannot assume it). Fork PRs DO emit the same   #
# sub, so dbt-ci.yml additionally guards the slim-build job with              #
# `if: github.event.pull_request.head.repo.full_name == github.repository`.   #
###############################################################################

data "aws_iam_policy_document" "gha_ci_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = local.github_oidc_audiences
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "gha_ci" {
  name               = local.gha_ci_role_name
  assume_role_policy = data.aws_iam_policy_document.gha_ci_assume.json
  description        = "Assumed by .github/workflows/dbt-ci.yml for slim CI builds against per-PR Glue databases."
}

data "aws_iam_policy_document" "gha_ci" {
  # Read the prod manifest published by the Batch dbt-runner (or the parse
  # fallback workflow) — needed for `dbt build --select state:modified+`.
  statement {
    sid       = "ManifestRead"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/dbt/manifest/*"]
  }

  statement {
    sid       = "ArtifactsBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  # Athena query exec on the shared workgroup. CI reuses the dev workgroup
  # rather than provisioning a parallel one — split it out later if cost
  # attribution matters.
  statement {
    sid = "AthenaQueryExec"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
      "athena:GetDataCatalog",
      "athena:ListDataCatalogs",
      "athena:ListDatabases",
      "athena:GetDatabase",
      "athena:ListTableMetadata",
      "athena:GetTableMetadata",
    ]
    resources = [
      aws_athena_workgroup.citibike.arn,
      "arn:${data.aws_partition.current.partition}:athena:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:datacatalog/AwsDataCatalog",
    ]
  }

  # Read prod Glue metadata for `--favor-state` deferral against unchanged
  # refs + sources.
  statement {
    sid = "GlueReadProd"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${local.glue_database}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${local.glue_database}/*",
    ]
  }

  # CRUD on the per-PR CI databases (citibike_lake_dev_ci_pr_*). dbt creates
  # them on demand during the slim build; cleanup workflow drops them on PR
  # close.
  statement {
    sid = "GlueCrudCI"
    actions = [
      "glue:CreateDatabase",
      "glue:DeleteDatabase",
      "glue:UpdateDatabase",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateTable",
      "glue:DeleteTable",
      "glue:UpdateTable",
      "glue:GetTable",
      "glue:GetTables",
      "glue:BatchDeleteTable",
      "glue:CreatePartition",
      "glue:DeletePartition",
      "glue:UpdatePartition",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchGetPartition",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${local.ci_glue_database_prefix}*",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${local.ci_glue_database_prefix}*/*",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:userDefinedFunction/${local.ci_glue_database_prefix}*/*",
    ]
  }

  # Bucket-level list — Athena + dbt-athena both call ListBucket during
  # planning + Iceberg metadata reads.
  statement {
    sid = "S3LakeList"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.lake["raw"].arn,
      aws_s3_bucket.lake["warehouse"].arn,
      aws_s3_bucket.lake["athena_results"].arn,
    ]
  }

  # Read prod source data (raw CSVs) and prod warehouse (Iceberg data files
  # referenced by `--favor-state`).
  statement {
    sid = "S3ProdRead"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      "${aws_s3_bucket.lake["raw"].arn}/*",
      "${aws_s3_bucket.lake["warehouse"].arn}/*",
    ]
  }

  # Write the per-PR CI build's Iceberg data files. Scoped to the dbt-ci
  # prefix so an escaped PR can't trample prod warehouse data.
  statement {
    sid = "S3CIWrite"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      "${aws_s3_bucket.lake["warehouse"].arn}/${local.ci_warehouse_prefix}/*",
    ]
  }

  # Athena results — workgroup writes query state + results here.
  statement {
    sid = "S3AthenaResults"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.lake["athena_results"].arn}/*"]
  }

  # LF data-access stub — when enable_lake_formation_governance is on the LF
  # grants in lakeformation.tf add this role to readonly_principals; reading
  # prod tables flows through LF. Harmless when LF is off.
  statement {
    sid       = "LakeFormation"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_ci" {
  name   = "${local.gha_ci_role_name}-policy"
  role   = aws_iam_role.gha_ci.id
  policy = data.aws_iam_policy_document.gha_ci.json
}

###############################################################################
# Outputs
###############################################################################

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_infra_role_arn" {
  description = "Role assumed by infra-*.yml workflows."
  value       = aws_iam_role.gha_infra.arn
}

output "github_actions_pipeline_role_arn" {
  description = "Role assumed by dbt-cd/dqdl-cd/lambda-cd/image-cd workflows."
  value       = aws_iam_role.gha_pipeline.arn
}

output "github_actions_ci_role_arn" {
  description = "Role assumed by .github/workflows/dbt-ci.yml for per-PR slim dbt builds."
  value       = aws_iam_role.gha_ci.arn
}

output "ci_glue_database_prefix" {
  description = "Prefix for per-PR Glue databases provisioned by the dbt-ci slim-build workflow (e.g. citibike_lake_dev_ci_pr_42)."
  value       = local.ci_glue_database_prefix
}

output "ci_dbt_athena_staging_dir" {
  description = "Athena staging dir used by dbt-ci slim builds."
  value       = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/dbt-ci/"
}

output "ci_dbt_athena_data_dir" {
  description = "Iceberg data root used by dbt-ci slim builds."
  value       = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.ci_warehouse_prefix}/"
}

output "artifacts_bucket_name" {
  description = "S3 bucket holding pipeline code artifacts (dbt tarballs, Lambda zips, rendered DQDL)."
  value       = aws_s3_bucket.artifacts.bucket
}
