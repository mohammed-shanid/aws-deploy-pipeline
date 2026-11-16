# Terraform: how to bring this up on AWS

Status, 2026-11-14: **nothing here has been planned or applied against AWS.** The code passes the local checks (`terraform validate`, the guardrail tests, checkov). The first real `plan` needs AWS credentials, which only the human has.

Every `apply` below is run by the human (CLAUDE.md rule 1). Read each plan before applying it.

## 0. Once: credentials and versions

```bash
mise install                      # Terraform 1.16.7
aws login                         # or: aws configure sso. Short-lived credentials only, no access keys
export AWS_PROFILE=<your profile>
aws sts get-caller-identity       # confirm the account before going further
```

## 1. Bootstrap: state bucket and budget alert (local state)

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars    # then edit: region, owner, budget, email
terraform init
terraform plan -out=tfplan                      # 7 resources in the code; confirm the plan says 7 to add
terraform apply tfplan                          # HUMAN
terraform output                                # bucket name and region for step 2
```

Creates one S3 bucket (versioned, encrypted, private, TLS-only, `prevent_destroy`) and one AWS Budget that emails at 80% actual and 100% forecast. The budget only notifies; it does not stop anything. `terraform.tfstate` for this folder stays on your machine and is gitignored: keep it.

Check afterwards: the budget is listed in the Billing console, and the bucket shows versioning on and public access blocked.

## 2. The dev environment

```bash
cd infra/terraform/envs/dev
cp backend.hcl.example backend.hcl              # then edit: bucket and region from step 1
cp terraform.tfvars.example terraform.tfvars    # then edit: same region, owner
terraform init -backend-config=backend.hcl
terraform test                                  # 6 passed
terraform plan -out=tfplan
```

Before applying, the tag check on the saved plan must print nothing (docs/architecture/deployment.md §6.2):

```bash
terraform show -json tfplan | jq -r '
  .resource_changes[]
  | select(.change.after | type == "object" and has("tags_all"))
  | select((.change.after.tags_all // {}) as $t
      | ["Project","Environment","Owner","ManagedBy"] | all(. as $k | $t | has($k)) | not)
  | .address'

terraform apply tfplan                          # HUMAN. Billing starts here (~$20/month, cost-estimate.md)
```

Check afterwards:

```bash
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text   # Online
aws ssm start-session --target "$(terraform output -raw instance_id)"                                             # a shell, without SSH
```

## What it creates

| File | Resources |
|---|---|
| `network.tf` | VPC, one public subnet, internet gateway, route table, security group (80/443 in; 22 only if `operator_cidr` is set) |
| `compute.tf` | One `t3.small` Ubuntu 24.04 instance (IMDSv2, hop limit 1, encrypted gp3 root) and an Elastic IP |
| `ecr.tf` | One private ECR repository, immutable tags, scan on push, keeps the last 10 images |
| `ssm.tf` | The `<project>-deploy` command document: runs `/opt/app/bin/deploy <sha>` and nothing else |
| `iam.tf` | Instance role, GitHub OIDC provider, deploy role. Every action is explained in docs/architecture/security.md §2 |

Not here yet: CloudWatch log groups, alarms and the instance's CloudWatch permissions (roadmap Day 6); DNS (human-managed).

## To stop paying

`terraform plan -destroy -out=tfplan` in `envs/dev`, read it, then the human applies it. The bootstrap bucket has `prevent_destroy` and costs cents; leave it.
