terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Bucket and region come from backend.hcl (gitignored; see backend.hcl.example):
  #   terraform init -backend-config=backend.hcl
  # Locking uses an S3 lock file, not DynamoDB (ADR 0004).
  backend "s3" {
    key          = "dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
