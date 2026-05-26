variable "aws_region" {
  description = "AWS region for S3, Glue, Athena, Lambda, and EventBridge resources."
  type        = string
  default     = "us-east-1"
}

variable "allowed_account_id" {
  description = "Optional guardrail. Set this to the target AWS account ID so Terraform refuses to run against another account."
  type        = string
  default     = null

  validation {
    condition     = var.allowed_account_id == null || can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_id must be a 12 digit AWS account ID."
  }
}

variable "project_name" {
  description = "Short lowercase project name used in resource names."
  type        = string
  default     = "citibike-lake"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 chars, lowercase letters, digits, and hyphens only, with no leading or trailing hyphen."
  }
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}[a-z0-9]$", var.environment))
    error_message = "environment must be 3-22 chars, lowercase letters, digits, and hyphens only, with no leading or trailing hyphen."
  }
}

variable "bucket_name_prefix" {
  description = "Optional globally unique S3 bucket prefix. Defaults to project-environment-account-region."
  type        = string
  default     = null

  validation {
    condition = var.bucket_name_prefix == null ? true : (
      length(var.bucket_name_prefix) <= 48 &&
      can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.bucket_name_prefix))
    )
    error_message = "bucket_name_prefix must be <= 48 chars and valid for S3 bucket names."
  }
}

variable "force_destroy_buckets" {
  description = "When true, Terraform can delete non-empty buckets. Keep false for anything beyond disposable dev."
  type        = bool
  default     = false
}

variable "glue_database_name" {
  description = "Glue Data Catalog database name. If null, Terraform derives one from project_name and environment."
  type        = string
  default     = null

  validation {
    condition     = var.glue_database_name == null || can(regex("^[a-z0-9_]{1,252}$", var.glue_database_name))
    error_message = "glue_database_name must use lowercase letters, digits, and underscores."
  }
}

variable "raw_data_prefix" {
  description = "S3 prefix in the raw bucket for downloaded Citi Bike CSV files."
  type        = string
  default     = "raw/citibike"
}

variable "warehouse_prefix" {
  description = "S3 prefix in the warehouse bucket for Athena Iceberg table data."
  type        = string
  default     = "warehouse/citibike/iceberg"
}

variable "athena_results_retention_days" {
  description = "Days before Athena query result files expire from the results bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.athena_results_retention_days >= 1
    error_message = "athena_results_retention_days must be at least 1."
  }
}

variable "athena_bytes_scanned_cutoff_bytes" {
  description = "Optional per-query bytes scanned cutoff for the Athena workgroup. Null leaves it unset."
  type        = number
  default     = null
}

variable "citibike_base_url" {
  description = "Base URL for Citi Bike monthly tripdata ZIP files."
  type        = string
  default     = "https://s3.amazonaws.com/tripdata"
}

variable "citibike_months" {
  description = "Default YYYYMM Citi Bike months for manual Lambda ingestion. Modern schema files are expected."
  type        = list(string)
  default     = ["202401"]

  validation {
    condition     = alltrue([for month in var.citibike_months : can(regex("^[0-9]{6}$", month))])
    error_message = "citibike_months entries must be YYYYMM strings."
  }
}

variable "citibike_start_date" {
  description = "Earliest trip date expected in curated Silver/Gold/DQ checks."
  type        = string
  default     = "2026-01-01"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.citibike_start_date))
    error_message = "citibike_start_date must be a YYYY-MM-DD date string."
  }
}

variable "citibike_include_jc" {
  description = "When true, the ingestion Lambda also tries Jersey City JC-YYYYMM Citi Bike files for requested months."
  type        = bool
  default     = false
}

variable "lambda_memory_mb" {
  description = "Memory for the Citi Bike ingestion Lambda."
  type        = number
  default     = 2048

  validation {
    condition     = var.lambda_memory_mb >= 512 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 512 and 10240."
  }
}

variable "lambda_ephemeral_storage_mb" {
  description = "Ephemeral /tmp storage for the Citi Bike ingestion Lambda. Large monthly ZIPs need more than the Lambda default."
  type        = number
  default     = 10240

  validation {
    condition     = var.lambda_ephemeral_storage_mb >= 512 && var.lambda_ephemeral_storage_mb <= 10240
    error_message = "lambda_ephemeral_storage_mb must be between 512 and 10240."
  }
}

variable "enable_monthly_ingestion_schedule" {
  description = "Create an EventBridge rule that invokes the ingestion Lambda for the previous month."
  type        = bool
  default     = false
}

variable "monthly_ingestion_schedule_expression" {
  description = "EventBridge schedule expression for optional monthly ingestion."
  type        = string
  default     = "cron(0 12 5 * ? *)"
}

variable "enable_metabase" {
  description = "Create an AWS-hosted Metabase deployment connected to Athena."
  type        = bool
  default     = false
}

variable "metabase_image" {
  description = "Metabase Docker image tag to run on ECS Fargate."
  type        = string
  default     = "metabase/metabase:v0.61.2.x"
}

variable "metabase_allowed_cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to reach the public Metabase load balancer on port 80."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.metabase_allowed_cidr_blocks : can(cidrhost(cidr, 0))])
    error_message = "metabase_allowed_cidr_blocks must contain valid IPv4 CIDR blocks."
  }
}

variable "metabase_vpc_cidr" {
  description = "CIDR block for the dedicated Metabase VPC."
  type        = string
  default     = "10.80.0.0/16"

  validation {
    condition     = can(cidrhost(var.metabase_vpc_cidr, 0))
    error_message = "metabase_vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "metabase_task_cpu" {
  description = "CPU units for the Metabase Fargate task."
  type        = number
  default     = 1024
}

variable "metabase_task_memory" {
  description = "Memory in MiB for the Metabase Fargate task."
  type        = number
  default     = 2048
}

variable "metabase_desired_count" {
  description = "Number of Metabase ECS tasks to run."
  type        = number
  default     = 1
}

variable "metabase_db_instance_class" {
  description = "RDS PostgreSQL instance class for the Metabase application database."
  type        = string
  default     = "db.t4g.micro"
}

variable "metabase_db_allocated_storage_gb" {
  description = "Initial RDS PostgreSQL storage for Metabase, in GiB."
  type        = number
  default     = 20
}

variable "metabase_db_max_allocated_storage_gb" {
  description = "Maximum RDS PostgreSQL autoscaled storage for Metabase, in GiB."
  type        = number
  default     = 100
}

variable "metabase_db_name" {
  description = "RDS PostgreSQL database name for Metabase."
  type        = string
  default     = "metabase"
}

variable "metabase_db_username" {
  description = "RDS PostgreSQL master username for Metabase."
  type        = string
  default     = "metabase"
}

variable "metabase_db_backup_retention_days" {
  description = "RDS backup retention in days for the Metabase application database."
  type        = number
  default     = 7
}

variable "metabase_db_skip_final_snapshot" {
  description = "When true, RDS skips a final snapshot on destroy. Keep true only for disposable dev deployments."
  type        = bool
  default     = true
}

variable "metabase_db_deletion_protection" {
  description = "Protect the Metabase RDS instance from deletion."
  type        = bool
  default     = false
}

variable "metabase_admin_email" {
  description = "Initial Metabase admin email used by scripts/setup_metabase.py."
  type        = string
  default     = "admin@citibike.local"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.metabase_admin_email))
    error_message = "metabase_admin_email must be a valid email address."
  }
}

variable "metabase_site_name" {
  description = "Metabase site name used during first-run setup."
  type        = string
  default     = "Citi Bike Lake"
}

variable "enable_lake_formation_governance" {
  description = "Register data lake S3 locations with Lake Formation and manage lake permissions there."
  type        = bool
  default     = false
}

variable "lake_formation_admin_principal_arns" {
  description = "IAM principal ARNs that should be Lake Formation data lake administrators for this lake."
  type        = list(string)
  default     = []
}

variable "lake_formation_additional_readonly_principal_arns" {
  description = "Additional IAM principal ARNs that should be able to query all lake tables through Lake Formation."
  type        = list(string)
  default     = []
}

variable "lake_formation_hybrid_access_enabled" {
  description = "Register data lake S3 locations in Lake Formation hybrid access mode. Keep false when fully moving the lake to LF permissions."
  type        = bool
  default     = false
}

variable "enable_glue_data_quality" {
  description = "Create AWS Glue Data Quality DQDL rulesets and the execution role used to evaluate them."
  type        = bool
  default     = false
}

variable "glue_data_quality_number_of_workers" {
  description = "Number of workers for Glue Data Quality ruleset evaluation runs."
  type        = number
  default     = 2
}

variable "glue_data_quality_timeout_minutes" {
  description = "Timeout in minutes for Glue Data Quality ruleset evaluation runs."
  type        = number
  default     = 60
}

variable "enable_glue_data_quality_event_observability" {
  description = "Create EventBridge, Step Functions, Lambda, and Athena tables for Glue Data Quality result events."
  type        = bool
  default     = false
}

variable "glue_data_quality_event_observability_prefix" {
  description = "S3 prefix in the warehouse bucket for Glue Data Quality event observability JSONL tables."
  type        = string
  default     = "observability/glue-data-quality"

  validation {
    condition     = length(trimsuffix(trimprefix(var.glue_data_quality_event_observability_prefix, "/"), "/")) > 0
    error_message = "glue_data_quality_event_observability_prefix must not be empty."
  }
}

variable "glue_data_quality_event_processor_log_retention_days" {
  description = "CloudWatch Logs retention in days for the Glue Data Quality event processor Lambda."
  type        = number
  default     = 14

  validation {
    condition     = var.glue_data_quality_event_processor_log_retention_days >= 1
    error_message = "glue_data_quality_event_processor_log_retention_days must be at least 1."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the data alerts SNS topic. Empty disables the email subscription."
  type        = string
  default     = ""
}

variable "enable_pipeline_orchestration" {
  description = "If true, creates the AWS Batch dbt runner, Step Functions pipeline, and S3/cron triggers that orchestrate the auto-heal flow."
  type        = bool
  default     = false
}

variable "dbt_runner_vpc_cidr" {
  description = "CIDR block for the dedicated VPC used by the Batch dbt runner."
  type        = string
  default     = "10.42.0.0/16"
}

variable "dbt_runner_image_tag" {
  description = "Image tag pushed to the dbt-runner ECR repository (typically 'latest' or a release SHA)."
  type        = string
  default     = "latest"
}

variable "dbt_batch_vcpu" {
  description = "Fargate vCPU allocated to each dbt Batch job."
  type        = number
  default     = 1
}

variable "dbt_batch_memory_mb" {
  description = "Fargate memory (MB) allocated to each dbt Batch job. Must be a valid Fargate vCPU/memory combination."
  type        = number
  default     = 2048
}

variable "dbt_batch_max_vcpus" {
  description = "Maximum vCPUs the dbt Batch compute environment will scale to."
  type        = number
  default     = 8
}

variable "pipeline_schedule_expression" {
  description = "EventBridge schedule expression for the daily safety-net pipeline run. Set empty to disable the cron."
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "alert_slack_webhook_url" {
  description = "Optional Slack incoming webhook URL subscribed to the data alerts SNS topic. Empty disables Slack."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Additional tags applied to supported AWS resources."
  type        = map(string)
  default     = {}
}
