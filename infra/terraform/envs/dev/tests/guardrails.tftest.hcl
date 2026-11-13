# Guardrail tests for the dev environment. No AWS account or credentials needed:
# the AWS provider is mocked, so `apply` here only simulates resources in memory.
#
#   terraform -chdir=infra/terraform/envs/dev init -backend=false
#   terraform -chdir=infra/terraform/envs/dev test
#
# Mocking needs Terraform >= 1.7 (syntax checked against
# developer.hashicorp.com/terraform/language/tests/mocking on 2026-10-24).
#
# Contract the dev env (Phase 5) must meet for these tests to evaluate:
#   local.common_tags                              passed to the provider's default_tags
#   var.operator_cidr                              default null; validation rejects anything but a /32
#   aws_security_group.app                         no inline ingress blocks
#   aws_vpc_security_group_ingress_rule.public     for_each, internet-facing 80/443 only
#   aws_vpc_security_group_ingress_rule.ssh        count = operator_cidr == null ? 0 : 1
#   aws_instance.app                               the app host
#   aws_iam_openid_connect_provider.github
#   aws_iam_role.gha_deploy                        assume_role_policy built with jsonencode()
#
# Why jsonencode() and not data.aws_iam_policy_document: a mocked data source
# returns a random string for `json`, so the trust policy could not be inspected.
#
# What mocks cannot prove: that default_tags actually reach every resource
# (tags_all is computed by the real provider). checkov's tag policy covers that.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  aws_region  = "us-east-1"
  project     = "aws-deploy-pipeline"
  environment = "dev"
  owner       = "harness"
}

run "required_tags" {
  assert {
    condition = alltrue([
      for k in ["Project", "Environment", "Owner", "ManagedBy"] :
      try(length(trimspace(local.common_tags[k])) > 0, false)
    ])
    error_message = "local.common_tags must set non-empty Project, Environment, Owner and ManagedBy."
  }

  assert {
    condition     = try(local.common_tags["ManagedBy"], null) == "terraform"
    error_message = "ManagedBy must be \"terraform\"."
  }

  assert {
    condition = try(
      local.common_tags["Project"] == var.project &&
      local.common_tags["Environment"] == var.environment &&
      local.common_tags["Owner"] == var.owner,
      false
    )
    error_message = "Project, Environment and Owner tags must come from the matching variables."
  }

  # A resource-level tag would override default_tags; it must not blank or change a required one.
  assert {
    condition = alltrue([
      for k, v in merge(aws_instance.app.tags, aws_security_group.app.tags, aws_iam_role.gha_deploy.tags) :
      !contains(["Project", "Environment", "Owner", "ManagedBy"], k) || v == try(local.common_tags[k], null)
    ])
    error_message = "A resource overrides a required tag with a different value."
  }
}

run "no_ssh_ingress_by_default" {
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh) == 0
    error_message = "Port 22 must be closed when operator_cidr is unset."
  }

  assert {
    condition     = length(aws_security_group.app.ingress) == 0
    error_message = "Use aws_vpc_security_group_ingress_rule resources, not inline ingress blocks."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.public :
      r.ip_protocol == "tcp" && !(r.from_port <= 22 && r.to_port >= 22)
    ])
    error_message = "A public ingress rule covers port 22 or allows all protocols."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.public :
      contains([80, 443], r.from_port) && r.from_port == r.to_port
    ])
    error_message = "Internet-facing ingress is limited to 80 and 443 (CLAUDE.md rule 5)."
  }
}

run "ssh_rejects_non_slash_32" {
  command = plan

  variables {
    operator_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.operator_cidr]
}

run "imdsv2_required" {
  assert {
    condition     = try(aws_instance.app.metadata_options[0].http_tokens, null) == "required"
    error_message = "IMDSv2 must be required (metadata_options.http_tokens = \"required\")."
  }

  assert {
    condition     = try(aws_instance.app.metadata_options[0].http_put_response_hop_limit, null) == 1
    error_message = "IMDS hop limit must be 1 so containers cannot reach instance credentials (security.md T4)."
  }
}

run "ebs_encrypted" {
  assert {
    condition     = try(aws_instance.app.root_block_device[0].encrypted, false) == true
    error_message = "The root volume must be encrypted."
  }

  assert {
    condition     = alltrue([for d in aws_instance.app.ebs_block_device : d.encrypted == true])
    error_message = "Every attached EBS volume must be encrypted."
  }
}

run "oidc_trust_pinned_to_repo_main" {
  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com"
    error_message = "The OIDC provider must be GitHub Actions."
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "The OIDC provider audience must be sts.amazonaws.com only."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement) == 1
    error_message = "The deploy role trust policy must have exactly one statement."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    )
    error_message = "The trust statement must allow only sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider."
  }

  assert {
    condition = try(
      jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"],
      null
    ) == "repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main"
    error_message = "The trust policy sub must be exactly repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main (StringEquals)."
  }

  assert {
    condition = try(
      jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"],
      null
    ) == "sts.amazonaws.com"
    error_message = "The trust policy must pin aud to sts.amazonaws.com."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.gha_deploy.assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    error_message = "Only StringEquals conditions are allowed: no StringLike wildcards on sub."
  }
}
