# Bootstrap: the Terraform state bucket and the budget alert. Applied once, by a
# human, before anything else. Uses LOCAL state (ADR 0004): the bucket that would
# hold remote state is created here.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
