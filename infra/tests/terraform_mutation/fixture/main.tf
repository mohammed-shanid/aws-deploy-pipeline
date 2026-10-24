# NOT REAL INFRASTRUCTURE. Never plan or apply this.
#
# The smallest configuration that meets the contract in the header of
# infra/terraform/envs/dev/tests/guardrails.tftest.hcl. mutate.py breaks it one
# rule at a time to prove each guardrail test catches the violation it exists for.
# It lives outside infra/terraform so CI's checkov scan (real infra only) skips it.
# The backend block is never initialised (init -backend=false).

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "example-state"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

variable "aws_region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "owner" { type = string }
variable "github_repo" {
  type    = string
  default = "mohammed-shanid/aws-deploy-pipeline"
}
variable "operator_cidr" {
  type    = string
  default = null
  validation {
    condition     = var.operator_cidr == null || (can(cidrhost(var.operator_cidr, 0)) && endswith(coalesce(var.operator_cidr, "x"), "/32"))
    error_message = "operator_cidr must be null or a single /32."
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_vpc" "main" { cidr_block = "10.20.0.0/16" }
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}
resource "aws_security_group" "app" {
  name   = "app"
  vpc_id = aws_vpc.main.id
  tags   = { Name = "app" }
}
resource "aws_vpc_security_group_ingress_rule" "public" {
  for_each          = { http = 80, https = 443 }
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = var.operator_cidr == null ? 0 : 1
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}
resource "aws_instance" "app" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.public.id
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }
}
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_iam_role" "gha_deploy" {
  name = "gha-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}
