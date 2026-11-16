# One private repository. Tags are full git SHAs and cannot be overwritten (ADR 0003).
resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_136: AES256 (ECR's default encryption) instead of a KMS key: a customer key costs about $1/month and the image holds no secrets. Accepted 2026-11-14, Low
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}
