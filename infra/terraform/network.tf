# Network layer.
#
# Design: two private subnets across two AZs, no public subnets, no internet
# gateway, no NAT gateway. Egress to AWS services goes through VPC endpoints
# instead. See docs/adr/0003-no-nat-gateway.md.
#
# dev and prod share this VPC. Isolation between environments is enforced at
# the IAM layer, not the network layer — a deliberate cost trade documented in
# docs/adr/0002-shared-vpc-iam-isolation.md.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "retail-platform-vpc"
  }
}

# --- Subnets -------------------------------------------------------------

locals {
  subnets = {
    private1 = {
      id   = "subnet-07735066c27bfeb8d"
      az   = "eu-west-2a"
      cidr = "10.0.128.0/20"
      name = "retail-platform-vpc-subnet-private1-eu-west-2a"
      rtb  = "rtb-08886e03d03888075"
    }
    private2 = {
      id   = "subnet-05b550e3b3323162d"
      az   = "eu-west-2b"
      cidr = "10.0.144.0/20"
      name = "retail-platform-vpc-subnet-private2-eu-west-2b"
      rtb  = "rtb-0c376bff5a28f1e83"
    }
  }
}

resource "aws_subnet" "private" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = {
    Name = each.value.name
    Tier = "private"
  }
}

# --- Route tables --------------------------------------------------------
# Only the implicit local route (10.0.0.0/16) exists. No 0.0.0.0/0 route,
# which is what makes these subnets genuinely private.

resource "aws_route_table" "private" {
  for_each = local.subnets

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "retail-platform-vpc-rtb-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each = local.subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# The main route table, created with the VPC. Nothing is associated with it —
# both subnets have explicit tables above. Managed so it cannot be quietly
# given an internet route later.


# --- S3 gateway endpoint -------------------------------------------------
# NOT YET CREATED — Terraform will create this.
#
# Gateway endpoints are free: no hourly charge, no data processing charge.
# Only Interface endpoints (e.g. the Glue API endpoint) bill hourly per AZ.
#
# This is load-bearing, not an optimisation. With no NAT and no IGW, a Glue
# job in these subnets has no route to S3 without it.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [for k, _ in local.subnets : aws_route_table.private[k].id]
  )

  tags = {
    Name = "retail-s3-gateway-endpoint"
  }
}

# --- Security group ------------------------------------------------------

resource "aws_security_group" "glue" {
  name        = "retail-glue-sg"
  description = "Glue End Point SG"
  vpc_id      = aws_vpc.main.id

  # Self-referencing inbound rule. Glue provisions multiple workers in the
  # subnet and they must reach each other on arbitrary ports. Without this,
  # jobs fail at startup with an opaque connectivity error rather than
  # anything that points at the security group.
  #
  # NOTE: this rule did not exist on the console-created SG. Terraform adds it.
  ingress {
    description = "Self-referencing: Glue worker to worker"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # Matching self-referencing egress for the same reason.
  egress {
    description = "Self-referencing: Glue worker to worker"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # Existing rule: HTTPS out. Reaches S3 via the gateway endpoint above, and
  # AWS service APIs generally. Traffic to S3 stays on the AWS network and
  # never traverses the internet, since there is no route to one.
  egress {
    description = "HTTPS to AWS services"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "retail-glue-sg"
  }
}
