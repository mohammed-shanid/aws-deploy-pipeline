# Canonical's Ubuntu 24.04 LTS, amd64. Looked up, not hardcoded.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  #checkov:skip=CKV_AWS_126: No detailed (1-minute) monitoring: it is billed per metric and 5-minute data is enough for one demo host. Revisit with alarms (roadmap Day 6). Accepted 2026-11-14, Low
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  # IMDSv2 only, hop limit 1: a container cannot reach the instance role's
  # credentials through the metadata service (security.md T4).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    delete_on_termination = true
  }

  tags = { Name = "${local.name}-app" }

  lifecycle {
    # A newer AMI must not replace the host as a side effect of an unrelated
    # plan. Rebuild on purpose: terraform plan -replace=aws_instance.app
    ignore_changes = [ami]
  }
}

# A fixed public address, so DNS survives an instance replacement.
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id

  tags = { Name = "${local.name}-app" }

  depends_on = [aws_internet_gateway.main]
}
