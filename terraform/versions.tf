terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "../.terraform-state/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0, < 3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0"
    }

    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0, < 4.0"
    }
  }
}

locals {
  common_tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Workload    = "citibike-athena-iceberg-lake"
    }
  )
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.allowed_account_id == null ? null : [var.allowed_account_id]

  default_tags {
    tags = local.common_tags
  }
}
