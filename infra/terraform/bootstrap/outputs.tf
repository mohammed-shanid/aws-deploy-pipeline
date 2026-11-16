output "state_bucket" {
  description = "Put this in infra/terraform/envs/<env>/backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_region" {
  description = "Put this in backend.hcl as `region`."
  value       = var.aws_region
}
