###############################################################################
# AWS Batch dbt runner — Fargate-backed dbt-athena container invoked by Step  #
# Functions for orchestrated Silver/Gold builds.                              #
#                                                                             #
# All resources here are gated by var.enable_pipeline_orchestration.          #
###############################################################################

locals {
  pipeline_enabled = var.enable_pipeline_orchestration

  dbt_runner_name      = "${local.name_prefix}-dbt-runner"
  dbt_runner_repo_name = "${local.name_prefix}/dbt-runner"
  dbt_runner_log_group = "/aws/batch/${local.dbt_runner_name}"
  dbt_runner_image_uri = local.pipeline_enabled ? "${aws_ecr_repository.dbt_runner[0].repository_url}:${var.dbt_runner_image_tag}" : ""

  dbt_data_dir    = "s3://${aws_s3_bucket.lake["warehouse"].bucket}/${local.warehouse_prefix}/dbt/"
  dbt_staging_dir = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/dbt/"
}

###############################################################################
# ECR repository + image build
###############################################################################

resource "aws_ecr_repository" "dbt_runner" {
  count = local.pipeline_enabled ? 1 : 0

  name                 = local.dbt_runner_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = var.force_destroy_buckets

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "dbt_runner" {
  count = local.pipeline_enabled ? 1 : 0

  repository = aws_ecr_repository.dbt_runner[0].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# Build + push the dbt-runner image at apply time. Requires the docker CLI.
resource "null_resource" "dbt_runner_image_build" {
  count = local.pipeline_enabled ? 1 : 0

  triggers = {
    # The image NO LONGER bakes in the dbt project — pipeline code is pulled
    # from S3 at runtime by entrypoint.sh. So the trigger watches only the
    # image's own contents (Dockerfile, entrypoint, pinned Python deps).
    # dbt changes ship via dbt-cd.yml without rebuilding this image.
    dockerfile_hash   = filesha256("${path.module}/../docker/dbt-runner/Dockerfile")
    entrypoint_hash   = filesha256("${path.module}/../docker/dbt-runner/entrypoint.sh")
    requirements_hash = filesha256("${path.module}/../docker/dbt-runner/requirements.txt")
    repo_url          = aws_ecr_repository.dbt_runner[0].repository_url
    image_tag         = var.dbt_runner_image_tag
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = "${path.module}/.."
    command     = <<-EOT
      set -euo pipefail
      REPO_URL="${aws_ecr_repository.dbt_runner[0].repository_url}"
      REGISTRY="$${REPO_URL%%/*}"
      aws ecr get-login-password --region "${data.aws_region.current.region}" \
        | docker login --username AWS --password-stdin "$REGISTRY"
      docker buildx build \
        --platform linux/amd64 \
        --file docker/dbt-runner/Dockerfile \
        --tag "$REPO_URL:${var.dbt_runner_image_tag}" \
        --push \
        .
    EOT
  }

  depends_on = [aws_ecr_repository.dbt_runner]
}

###############################################################################
# Minimal VPC dedicated to the dbt Batch runner (Fargate needs subnets).
# aws_availability_zones.available is shared with metabase.tf.
###############################################################################

resource "aws_vpc" "dbt_runner" {
  count = local.pipeline_enabled ? 1 : 0

  cidr_block           = var.dbt_runner_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.dbt_runner_name}-vpc" }
}

resource "aws_internet_gateway" "dbt_runner" {
  count = local.pipeline_enabled ? 1 : 0

  vpc_id = aws_vpc.dbt_runner[0].id
  tags   = { Name = "${local.dbt_runner_name}-igw" }
}

resource "aws_subnet" "dbt_runner_public" {
  count = local.pipeline_enabled ? 2 : 0

  vpc_id                  = aws_vpc.dbt_runner[0].id
  cidr_block              = cidrsubnet(var.dbt_runner_vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.dbt_runner_name}-public-${count.index}" }
}

resource "aws_route_table" "dbt_runner_public" {
  count = local.pipeline_enabled ? 1 : 0

  vpc_id = aws_vpc.dbt_runner[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dbt_runner[0].id
  }

  tags = { Name = "${local.dbt_runner_name}-public-rt" }
}

resource "aws_route_table_association" "dbt_runner_public" {
  count = local.pipeline_enabled ? 2 : 0

  subnet_id      = aws_subnet.dbt_runner_public[count.index].id
  route_table_id = aws_route_table.dbt_runner_public[0].id
}

resource "aws_security_group" "dbt_runner" {
  count = local.pipeline_enabled ? 1 : 0

  name        = "${local.dbt_runner_name}-sg"
  description = "Egress-only SG for dbt Fargate Batch jobs."
  vpc_id      = aws_vpc.dbt_runner[0].id

  egress {
    description = "All egress (AWS APIs, ECR, S3, Athena)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# IAM
###############################################################################

# Task execution role — pulls images, writes logs
data "aws_iam_policy_document" "dbt_runner_execution_assume" {
  count = local.pipeline_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dbt_runner_execution" {
  count = local.pipeline_enabled ? 1 : 0

  name               = "${local.dbt_runner_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.dbt_runner_execution_assume[0].json
}

resource "aws_iam_role_policy_attachment" "dbt_runner_execution_managed" {
  count = local.pipeline_enabled ? 1 : 0

  role       = aws_iam_role.dbt_runner_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role — what the dbt container itself uses to call AWS APIs
data "aws_iam_policy_document" "dbt_runner_task_assume" {
  count = local.pipeline_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dbt_runner_task" {
  count = local.pipeline_enabled ? 1 : 0

  name               = "${local.dbt_runner_name}-task"
  assume_role_policy = data.aws_iam_policy_document.dbt_runner_task_assume[0].json
}

data "aws_iam_policy_document" "dbt_runner_task_policy" {
  count = local.pipeline_enabled ? 1 : 0

  statement {
    sid = "Athena"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
      "athena:ListDataCatalogs",
      "athena:GetDataCatalog",
      "athena:ListDatabases",
      "athena:GetDatabase",
      "athena:ListTableMetadata",
      "athena:GetTableMetadata",
    ]
    resources = ["*"]
  }

  statement {
    sid = "Glue"
    actions = [
      "glue:GetCatalogImportStatus",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:BatchCreatePartition",
      "glue:CreatePartition",
      "glue:BatchDeletePartition",
      "glue:DeletePartition",
      "glue:BatchGetPartition",
      "glue:UpdatePartition",
    ]
    resources = [
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.citibike.name}",
      "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.citibike.name}/*",
    ]
  }

  statement {
    sid = "S3LakeList"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [for bucket in aws_s3_bucket.lake : bucket.arn]
  }

  statement {
    sid = "S3LakeRead"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.lake["raw"].arn}/*"]
  }

  statement {
    sid = "S3LakeWrite"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      "${aws_s3_bucket.lake["warehouse"].arn}/*",
      "${aws_s3_bucket.lake["athena_results"].arn}/*",
    ]
  }

  statement {
    sid       = "ArtifactsBucketRead"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/dbt/*"]
  }

  statement {
    sid       = "ArtifactsBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid = "LakeFormation"
    actions = [
      "lakeformation:GetDataAccess",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dbt_runner_task" {
  count = local.pipeline_enabled ? 1 : 0

  name   = "${local.dbt_runner_name}-task"
  role   = aws_iam_role.dbt_runner_task[0].id
  policy = data.aws_iam_policy_document.dbt_runner_task_policy[0].json
}

###############################################################################
# Lake Formation grant for the dbt task role (only when LF governance is on)
###############################################################################

resource "aws_lakeformation_permissions" "dbt_runner_database" {
  count = local.pipeline_enabled && var.enable_lake_formation_governance ? 1 : 0

  principal   = aws_iam_role.dbt_runner_task[0].arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = aws_glue_catalog_database.citibike.name
  }
}

resource "aws_lakeformation_permissions" "dbt_runner_tables" {
  count = local.pipeline_enabled && var.enable_lake_formation_governance ? 1 : 0

  principal   = aws_iam_role.dbt_runner_task[0].arn
  permissions = ["SELECT", "DESCRIBE", "INSERT", "DELETE", "ALTER"]

  table {
    database_name = aws_glue_catalog_database.citibike.name
    wildcard      = true
  }
}

###############################################################################
# CloudWatch log group
###############################################################################

resource "aws_cloudwatch_log_group" "dbt_runner" {
  count             = local.pipeline_enabled ? 1 : 0
  name              = local.dbt_runner_log_group
  retention_in_days = var.glue_data_quality_event_processor_log_retention_days
}

###############################################################################
# AWS Batch Fargate
###############################################################################

data "aws_iam_policy_document" "batch_service_assume" {
  count = local.pipeline_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_service" {
  count              = local.pipeline_enabled ? 1 : 0
  name               = "${local.dbt_runner_name}-batch-service"
  assume_role_policy = data.aws_iam_policy_document.batch_service_assume[0].json
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  count      = local.pipeline_enabled ? 1 : 0
  role       = aws_iam_role.batch_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_batch_compute_environment" "dbt" {
  count = local.pipeline_enabled ? 1 : 0

  name         = "${local.dbt_runner_name}-ce"
  type         = "MANAGED"
  state        = "ENABLED"
  service_role = aws_iam_role.batch_service[0].arn

  compute_resources {
    type               = "FARGATE"
    max_vcpus          = var.dbt_batch_max_vcpus
    subnets            = aws_subnet.dbt_runner_public[*].id
    security_group_ids = [aws_security_group.dbt_runner[0].id]
  }

  depends_on = [aws_iam_role_policy_attachment.batch_service]
}

resource "aws_batch_job_queue" "dbt" {
  count = local.pipeline_enabled ? 1 : 0

  name     = "${local.dbt_runner_name}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.dbt[0].arn
  }
}

resource "aws_batch_job_definition" "dbt" {
  count = local.pipeline_enabled ? 1 : 0

  name                  = "${local.dbt_runner_name}-job"
  type                  = "container"
  platform_capabilities = ["FARGATE"]
  propagate_tags        = true

  container_properties = jsonencode({
    image            = local.dbt_runner_image_uri
    jobRoleArn       = aws_iam_role.dbt_runner_task[0].arn
    executionRoleArn = aws_iam_role.dbt_runner_execution[0].arn

    resourceRequirements = [
      { type = "VCPU", value = tostring(var.dbt_batch_vcpu) },
      { type = "MEMORY", value = tostring(var.dbt_batch_memory_mb) },
    ]

    networkConfiguration = {
      assignPublicIp = "ENABLED"
    }

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }

    runtimePlatform = {
      operatingSystemFamily = "LINUX"
      cpuArchitecture       = "X86_64"
    }

    environment = [
      { name = "AWS_REGION", value = data.aws_region.current.region },
      { name = "DBT_TARGET", value = "prod" },
      { name = "DBT_ATHENA_SCHEMA", value = aws_glue_catalog_database.citibike.name },
      { name = "DBT_ATHENA_WORKGROUP", value = aws_athena_workgroup.citibike.name },
      { name = "DBT_ATHENA_STAGING_DIR", value = local.dbt_staging_dir },
      { name = "DBT_ATHENA_DATA_DIR", value = local.dbt_data_dir },
      # Pipeline code is published by .github/workflows/dbt-cd.yml to this S3
      # path. The container downloads + extracts it at runtime; the image
      # itself does not bundle the dbt project.
      { name = "DBT_PROJECT_S3_URI", value = "s3://${aws_s3_bucket.artifacts.bucket}/dbt/latest.tar.gz" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.dbt_runner[0].name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "dbt"
      }
    }
  })

  depends_on = [null_resource.dbt_runner_image_build]
}

###############################################################################
# Outputs
###############################################################################

output "dbt_runner_image_repository_url" {
  description = "ECR repository URL for the dbt-runner image."
  value       = local.pipeline_enabled ? aws_ecr_repository.dbt_runner[0].repository_url : null
}

output "dbt_runner_batch_job_queue_arn" {
  description = "Batch job queue ARN for submitting dbt jobs."
  value       = local.pipeline_enabled ? aws_batch_job_queue.dbt[0].arn : null
}

output "dbt_runner_batch_job_definition_arn" {
  description = "Batch job definition ARN for the dbt runner."
  value       = local.pipeline_enabled ? aws_batch_job_definition.dbt[0].arn : null
}
