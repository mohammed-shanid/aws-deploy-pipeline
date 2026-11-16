data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  name = "${var.project}-${var.environment}"

  # Parameter Store path the instance may read. The parameter itself is created
  # by a human and never managed here, so its value never reaches state (ADR 0005).
  parameter_path = "/${var.project}/${var.environment}"
}
