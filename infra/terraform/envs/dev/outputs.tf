output "instance_id" {
  description = "For `aws ssm start-session --target` and the deploy workflow."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Elastic IP. Point the DNS A record here (human action)."
  value       = aws_eip.app.public_ip
}

output "ecr_repository_url" {
  description = "IMAGE_REPO for the deploy script and the workflow."
  value       = aws_ecr_repository.app.repository_url
}

output "gha_deploy_role_arn" {
  description = "Role the deploy workflow assumes through OIDC."
  value       = aws_iam_role.gha_deploy.arn
}

output "deploy_document_name" {
  description = "SSM document the deploy workflow runs."
  value       = aws_ssm_document.deploy.name
}

output "secret_parameter" {
  description = "Create this SecureString by hand (ADR 0005); Terraform never manages it."
  value       = "${local.parameter_path}/DEMO_SECRET"
}
