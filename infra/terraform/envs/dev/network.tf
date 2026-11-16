# One VPC, one public subnet, no NAT, no private subnets (ADR 0001).

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11: No VPC flow logs: they need a log group and add cost; one host with two open ports. Revisit with monitoring (roadmap Day 6). Accepted 2026-11-14, Low
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

# The VPC's default security group allows nothing, so a resource that forgets
# to name a group gets no access.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-default-unused" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.20.1.0/24"
  # null lets AWS choose once; the choice is then fixed in state. Set it to pin a zone.
  availability_zone = var.availability_zone
  # The instance gets its address from the Elastic IP, not from the subnet.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---- Security group: 80/443 in, 22 closed unless operator_cidr is set ----------

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "App host: HTTP and HTTPS from the internet; SSH closed by default"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "public" {
  #checkov:skip=CKV_AWS_260: Port 80 is open by design: ACME HTTP-01 challenges and the redirect to HTTPS (security.md §3). Accepted 2026-11-14, Low
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.app.id
  description       = "${each.key} from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.operator_cidr == null ? 0 : 1

  security_group_id = aws_security_group.app.id
  description       = "Break-glass SSH from one operator address"
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "all" {
  #checkov:skip=CKV_AWS_382: Open egress is an accepted risk (security.md §3, §5): the host needs AWS endpoints, Ubuntu mirrors, Docker's repo and Let's Encrypt, and restricting it needs VPC endpoints. Accepted 2026-11-14, Low
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
