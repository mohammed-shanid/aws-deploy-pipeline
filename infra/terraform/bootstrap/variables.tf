variable "aws_region" {
  description = "Region for the state bucket. Use the same region as the environment."
  type        = string
}

variable "project" {
  description = "Project name, used in resource names and the Project tag."
  type        = string
  default     = "aws-deploy-pipeline"
}

variable "owner" {
  description = "Owner tag: who to ask about these resources."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD. An email is sent at 80% actual and 100% forecast."
  type        = number

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than 0."
  }
}

variable "budget_alert_email" {
  description = "Address that receives budget alerts. Kept in terraform.tfvars (gitignored)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be an email address."
  }
}
