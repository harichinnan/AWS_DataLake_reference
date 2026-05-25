data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  metabase_subnet_keys        = var.enable_metabase ? toset(["0", "1"]) : toset([])
  metabase_availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  metabase_container_name     = "metabase"
  metabase_container_port     = 3000
  metabase_athena_staging_dir = "s3://${aws_s3_bucket.lake["athena_results"].bucket}/metabase/"
  metabase_gold_table_name    = "citibike_daily_ridership_gold"
}

resource "aws_vpc" "metabase" {
  count = var.enable_metabase ? 1 : 0

  cidr_block           = var.metabase_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-metabase"
  }
}

resource "aws_internet_gateway" "metabase" {
  count = var.enable_metabase ? 1 : 0

  vpc_id = aws_vpc.metabase[0].id

  tags = {
    Name = "${local.name_prefix}-metabase"
  }
}

resource "aws_subnet" "metabase_public" {
  for_each = local.metabase_subnet_keys

  vpc_id                  = aws_vpc.metabase[0].id
  availability_zone       = local.metabase_availability_zones[tonumber(each.key)]
  cidr_block              = cidrsubnet(var.metabase_vpc_cidr, 8, tonumber(each.key))
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-metabase-public-${tonumber(each.key) + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "metabase_private" {
  for_each = local.metabase_subnet_keys

  vpc_id            = aws_vpc.metabase[0].id
  availability_zone = local.metabase_availability_zones[tonumber(each.key)]
  cidr_block        = cidrsubnet(var.metabase_vpc_cidr, 8, tonumber(each.key) + 10)

  tags = {
    Name = "${local.name_prefix}-metabase-private-${tonumber(each.key) + 1}"
    Tier = "private"
  }
}

resource "aws_route_table" "metabase_public" {
  count = var.enable_metabase ? 1 : 0

  vpc_id = aws_vpc.metabase[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.metabase[0].id
  }

  tags = {
    Name = "${local.name_prefix}-metabase-public"
  }
}

resource "aws_route_table_association" "metabase_public" {
  for_each = aws_subnet.metabase_public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.metabase_public[0].id
}

resource "aws_db_subnet_group" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name       = "${local.name_prefix}-metabase"
  subnet_ids = [for key in sort(keys(aws_subnet.metabase_private)) : aws_subnet.metabase_private[key].id]

  tags = {
    Name = "${local.name_prefix}-metabase"
  }
}

resource "aws_security_group" "metabase_alb" {
  count = var.enable_metabase ? 1 : 0

  name        = "${local.name_prefix}-metabase-alb"
  description = "Controls public HTTP access to Metabase."
  vpc_id      = aws_vpc.metabase[0].id
}

resource "aws_vpc_security_group_ingress_rule" "metabase_alb_http" {
  for_each = var.enable_metabase ? toset(var.metabase_allowed_cidr_blocks) : toset([])

  security_group_id = aws_security_group.metabase_alb[0].id
  description       = "Metabase HTTP access."
  cidr_ipv4         = each.key
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "metabase_alb_all" {
  count = var.enable_metabase ? 1 : 0

  security_group_id = aws_security_group.metabase_alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "metabase_ecs" {
  count = var.enable_metabase ? 1 : 0

  name        = "${local.name_prefix}-metabase-ecs"
  description = "Allows the Metabase ECS task to receive traffic from the load balancer."
  vpc_id      = aws_vpc.metabase[0].id
}

resource "aws_vpc_security_group_ingress_rule" "metabase_ecs_from_alb" {
  count = var.enable_metabase ? 1 : 0

  security_group_id            = aws_security_group.metabase_ecs[0].id
  description                  = "Metabase container traffic from ALB."
  referenced_security_group_id = aws_security_group.metabase_alb[0].id
  from_port                    = local.metabase_container_port
  ip_protocol                  = "tcp"
  to_port                      = local.metabase_container_port
}

resource "aws_vpc_security_group_egress_rule" "metabase_ecs_all" {
  count = var.enable_metabase ? 1 : 0

  security_group_id = aws_security_group.metabase_ecs[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "metabase_rds" {
  count = var.enable_metabase ? 1 : 0

  name        = "${local.name_prefix}-metabase-rds"
  description = "Allows the Metabase ECS task to connect to PostgreSQL."
  vpc_id      = aws_vpc.metabase[0].id
}

resource "aws_vpc_security_group_ingress_rule" "metabase_rds_from_ecs" {
  count = var.enable_metabase ? 1 : 0

  security_group_id            = aws_security_group.metabase_rds[0].id
  description                  = "PostgreSQL from Metabase ECS."
  referenced_security_group_id = aws_security_group.metabase_ecs[0].id
  from_port                    = 5432
  ip_protocol                  = "tcp"
  to_port                      = 5432
}

resource "aws_db_instance" "metabase" {
  count = var.enable_metabase ? 1 : 0

  identifier                          = "${local.name_prefix}-metabase"
  engine                              = "postgres"
  instance_class                      = var.metabase_db_instance_class
  allocated_storage                   = var.metabase_db_allocated_storage_gb
  max_allocated_storage               = var.metabase_db_max_allocated_storage_gb
  storage_type                        = "gp3"
  storage_encrypted                   = true
  db_name                             = var.metabase_db_name
  username                            = var.metabase_db_username
  manage_master_user_password         = true
  db_subnet_group_name                = aws_db_subnet_group.metabase[0].name
  vpc_security_group_ids              = [aws_security_group.metabase_rds[0].id]
  publicly_accessible                 = false
  backup_retention_period             = var.metabase_db_backup_retention_days
  skip_final_snapshot                 = var.metabase_db_skip_final_snapshot
  deletion_protection                 = var.metabase_db_deletion_protection
  auto_minor_version_upgrade          = true
  apply_immediately                   = true
  copy_tags_to_snapshot               = true
  iam_database_authentication_enabled = false
  performance_insights_enabled        = false
  monitoring_interval                 = 0
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  network_type                        = "IPV4"
  multi_az                            = false
}

resource "random_password" "metabase_admin" {
  count = var.enable_metabase ? 1 : 0

  length  = 24
  special = false
}

resource "random_password" "metabase_encryption_key" {
  count = var.enable_metabase ? 1 : 0

  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "metabase_admin" {
  count = var.enable_metabase ? 1 : 0

  name                    = "${local.name_prefix}/metabase/admin"
  description             = "Initial Metabase admin credentials for API seeding."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "metabase_admin" {
  count = var.enable_metabase ? 1 : 0

  secret_id = aws_secretsmanager_secret.metabase_admin[0].id
  secret_string = jsonencode({
    email    = var.metabase_admin_email
    password = random_password.metabase_admin[0].result
  })
}

resource "aws_secretsmanager_secret" "metabase_encryption_key" {
  count = var.enable_metabase ? 1 : 0

  name                    = "${local.name_prefix}/metabase/encryption-key"
  description             = "Metabase encryption key for sensitive fields stored in the application database."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "metabase_encryption_key" {
  count = var.enable_metabase ? 1 : 0

  secret_id     = aws_secretsmanager_secret.metabase_encryption_key[0].id
  secret_string = random_password.metabase_encryption_key[0].result
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "metabase_task_execution" {
  count = var.enable_metabase ? 1 : 0

  name               = "${local.name_prefix}-metabase-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "metabase_task_execution" {
  count = var.enable_metabase ? 1 : 0

  role       = aws_iam_role.metabase_task_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "metabase_task_execution_secrets" {
  count = var.enable_metabase ? 1 : 0

  statement {
    sid = "ReadMetabaseRuntimeSecrets"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      aws_db_instance.metabase[0].master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.metabase_encryption_key[0].arn
    ]
  }
}

resource "aws_iam_role_policy" "metabase_task_execution_secrets" {
  count = var.enable_metabase ? 1 : 0

  name   = "${local.name_prefix}-metabase-runtime-secrets"
  role   = aws_iam_role.metabase_task_execution[0].id
  policy = data.aws_iam_policy_document.metabase_task_execution_secrets[0].json
}

resource "aws_iam_role" "metabase_task" {
  count = var.enable_metabase ? 1 : 0

  name               = "${local.name_prefix}-metabase-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

data "aws_iam_policy_document" "metabase_athena" {
  count = var.enable_metabase ? 1 : 0

  statement {
    sid = "RunAthenaQueries"
    actions = [
      "athena:BatchGetQueryExecution",
      "athena:GetDataCatalog",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:GetWorkGroup",
      "athena:ListDataCatalogs",
      "athena:ListDatabases",
      "athena:ListQueryExecutions",
      "athena:ListTableMetadata",
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
    sid = "ReadGlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTableVersion",
      "glue:GetTableVersions",
      "glue:GetTables"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.citibike.name}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.citibike.name}/*"
    ]
  }

  statement {
    sid = "ListAccountBuckets"
    actions = [
      "s3:ListAllMyBuckets"
    ]
    resources = ["*"]
  }

  statement {
    sid = "ListLakeBuckets"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [for bucket in aws_s3_bucket.lake : bucket.arn]
  }

  statement {
    sid = "ReadLakeObjects"
    actions = [
      "s3:GetObject"
    ]
    resources = [
      "${aws_s3_bucket.lake["raw"].arn}/*",
      "${aws_s3_bucket.lake["warehouse"].arn}/*",
      "${aws_s3_bucket.lake["athena_results"].arn}/*"
    ]
  }

  statement {
    sid = "WriteAthenaResults"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = [
      "${aws_s3_bucket.lake["athena_results"].arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "metabase_athena" {
  count = var.enable_metabase ? 1 : 0

  name   = "${local.name_prefix}-metabase-athena"
  role   = aws_iam_role.metabase_task[0].id
  policy = data.aws_iam_policy_document.metabase_athena[0].json
}

resource "aws_cloudwatch_log_group" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name              = "/ecs/${local.name_prefix}/metabase"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name = "${local.name_prefix}-metabase"
}

resource "aws_ecs_task_definition" "metabase" {
  count = var.enable_metabase ? 1 : 0

  family                   = "${local.name_prefix}-metabase"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.metabase_task_cpu
  memory                   = var.metabase_task_memory
  execution_role_arn       = aws_iam_role.metabase_task_execution[0].arn
  task_role_arn            = aws_iam_role.metabase_task[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = local.metabase_container_name
      image     = var.metabase_image
      essential = true

      portMappings = [
        {
          containerPort = local.metabase_container_port
          hostPort      = local.metabase_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "MB_DB_TYPE"
          value = "postgres"
        },
        {
          name  = "MB_DB_HOST"
          value = aws_db_instance.metabase[0].address
        },
        {
          name  = "MB_DB_PORT"
          value = "5432"
        },
        {
          name  = "MB_DB_DBNAME"
          value = var.metabase_db_name
        },
        {
          name  = "MB_DB_USER"
          value = var.metabase_db_username
        },
        {
          name  = "MB_SITE_URL"
          value = "http://${aws_lb.metabase[0].dns_name}"
        },
        {
          name  = "MB_LOAD_SAMPLE_CONTENT"
          value = "false"
        },
        {
          name  = "MB_ANON_TRACKING_ENABLED"
          value = "false"
        },
        {
          name  = "JAVA_TOOL_OPTIONS"
          value = "-XX:MaxRAMPercentage=75.0"
        }
      ]

      secrets = [
        {
          name      = "MB_DB_PASS"
          valueFrom = "${aws_db_instance.metabase[0].master_user_secret[0].secret_arn}:password::"
        },
        {
          name      = "MB_ENCRYPTION_SECRET_KEY"
          valueFrom = aws_secretsmanager_secret.metabase_encryption_key[0].arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.metabase[0].name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "metabase"
        }
      }
    }
  ])
}

resource "aws_lb" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name               = "${local.name_prefix}-metabase"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.metabase_alb[0].id]
  subnets            = [for key in sort(keys(aws_subnet.metabase_public)) : aws_subnet.metabase_public[key].id]
}

resource "aws_lb_target_group" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name        = "${local.name_prefix}-metabase"
  port        = local.metabase_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.metabase[0].id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = "/api/health"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "metabase_http" {
  count = var.enable_metabase ? 1 : 0

  load_balancer_arn = aws_lb.metabase[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.metabase[0].arn
  }
}

resource "aws_ecs_service" "metabase" {
  count = var.enable_metabase ? 1 : 0

  name                               = "${local.name_prefix}-metabase"
  cluster                            = aws_ecs_cluster.metabase[0].id
  task_definition                    = aws_ecs_task_definition.metabase[0].arn
  desired_count                      = var.metabase_desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 300
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.metabase_ecs[0].id]
    subnets          = [for key in sort(keys(aws_subnet.metabase_public)) : aws_subnet.metabase_public[key].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.metabase[0].arn
    container_name   = local.metabase_container_name
    container_port   = local.metabase_container_port
  }

  depends_on = [
    aws_iam_role_policy.metabase_task_execution_secrets,
    aws_iam_role_policy.metabase_athena,
    aws_lb_listener.metabase_http
  ]
}
