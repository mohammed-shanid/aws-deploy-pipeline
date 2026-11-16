variable "aws_region" {
  description = "Region for every resource in this environment."
  type        = string
}

variable "project" {
  description = "Project name, used in resource names and the Project tag."
  type        = string
}

variable "environment" {
  description = "Environment name, used in resource names and the Environment tag."
  type        = string
}

variable "owner" {
  description = "Owner tag: who to ask about these resources."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the only repository allowed to assume the deploy role."
  type        = string
  default     = "mohammed-shanid/aws-deploy-pipeline"
}

variable "operator_cidr" {
  description = "Break-glass SSH source, a single /32. null (the default) keeps port 22 closed."
  type        = string
  default     = null

  validation {
    condition     = var.operator_cidr == null || (can(cidrhost(var.operator_cidr, 0)) && endswith(coalesce(var.operator_cidr, "x"), "/32"))
    error_message = "operator_cidr must be null or a single /32."
  }
}

variable "availability_zone" {
  description = "Availability Zone for the subnet, e.g. ap-south-1a. null lets AWS choose."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type. Must be x86_64: the AMI and the image are amd64."
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Size of the encrypted gp3 root volume."
  type        = number
  default     = 20
}

variable "ecr_keep_images" {
  description = "How many images the ECR lifecycle policy keeps. At least 10, so manual rollback has history (ADR 0003)."
  type        = number
  default     = 10

  validation {
    condition     = var.ecr_keep_images >= 10
    error_message = "ecr_keep_images must be at least 10."
  }
}
