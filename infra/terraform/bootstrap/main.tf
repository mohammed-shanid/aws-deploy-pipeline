data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Project     = var.project
    Environment = "shared"
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  # Bucket names are global; the account ID makes this one unique.
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ---- Terraform state bucket (ADR 0004) --------------------------------------

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18: No access logging: it needs a second bucket for one operator's state files. Accepted 2026-11-14, Low
  #checkov:skip=CKV_AWS_144: No cross-region replication: versioning covers accidental loss and the infra can be re-imported. Accepted 2026-11-14, Low
  #checkov:skip=CKV_AWS_145: SSE-S3 (AES256) instead of a KMS key: a customer key costs about $1/month and adds no protection here. Accepted 2026-11-14, Low
  #checkov:skip=CKV2_AWS_62: No event notifications: nothing consumes them. Accepted 2026-11-14, Low
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions are kept for 90 days, which is the rollback window for a
# bad apply. Current versions are never expired.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Deny any request that does not use TLS.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---- Budget alert: a cost tripwire, not a spending cap ------------------------
# AWS Budgets only notifies. It does not stop or delete anything.

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
