# SSM interface endpoints — required for the Airflow instances to be
# reachable at all.
#
# The private subnets have no NAT and no internet gateway (ADR 0003), so an
# instance's SSM IAM permissions are necessary but not sufficient: without a
# network PATH to the SSM service, send-command and Session Manager cannot
# reach the instance regardless of what IAM allows. Three endpoints are
# needed together — ssm (the control plane), ssmmessages and ec2messages
# (the actual command/session channels) — omitting any one leaves SSM
# non-functional in a way that is not obvious from the error message.
#
# UNLIKE the EC2 instances, these endpoints hold no state. There is nothing
# to preserve across a "pause" — no installed software, no data, nothing
# that survives being destroyed. So the toggle here is destroy/recreate via
# a boolean, not the stop/start null_resource pattern used for the
# instances. Simpler, and correct for what these actually are.

variable "enable_ssm_endpoints" {
  description = <<-EOT
    Whether the SSM interface endpoints exist. Interface endpoints bill
    hourly per AZ regardless of use (~£0.01/hr/AZ), unlike the free S3
    gateway endpoint. Set to false when the Airflow instances are stopped
    and you do not need to reach them — this destroys the endpoints
    entirely rather than leaving them idle. Set back to true, apply, and
    they exist again within about a minute; nothing about them is
    stateful.
  EOT
  type    = bool
  default = true
}

locals {
  # Endpoint policy narrows what the endpoint will route, independent of the
  # instance's own IAM policy. Two layers of "no" here rather than one.
  ssm_endpoint_subnet_ids = [
    aws_subnet.private["private1"].id,
    aws_subnet.private["private2"].id,
  ]
}

resource "aws_security_group" "ssm_endpoints" {
  count = var.enable_ssm_endpoints ? 1 : 0

  name        = "retail-ssm-endpoints-sg"
  description = "HTTPS from the Airflow instances to the SSM interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from Airflow instances"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [
      aws_security_group.airflow["dev"].id,
      aws_security_group.airflow["prod"].id,
    ]
  }

  tags = { Component = "ssm-endpoints" }
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = var.enable_ssm_endpoints ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.ssm_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.ssm_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name      = "retail-${each.key}-endpoint"
    Component = "ssm-endpoints"
  }
}
