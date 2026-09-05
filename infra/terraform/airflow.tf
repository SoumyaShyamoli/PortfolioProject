# Airflow — two EC2 instances (dev, prod), created once and toggled between
# running and stopped rather than destroyed and recreated.
#
# See docs/adr/0014-airflow-hosting.md for the reasoning: local Docker was
# rejected because CI cannot deploy to a laptop, which breaks the
# dev-proves-itself-before-prod pattern used everywhere else in this
# platform. A single shared instance was rejected because it would co-locate
# dev and prod Snowflake credentials, contradicting ADR 0010.
#
# COST: two t3.small instances, SequentialExecutor + SQLite (no separate
# Postgres container — see the bootstrap script), running for the working
# window this was built and demoed in, then stopped. See ADR 0014's second
# amendment for the corrected, higher cost figure (SSM endpoints, actual
# runtime) — the original ~£9-10 estimate undercounted real spend.
# EBS volumes keep costing a small amount monthly while stopped, until
# terminated — see the runbook for what "pause" actually means here.

locals {
  airflow_environments = {
    dev = {
      subnet_id = aws_subnet.private["private1"].id
      role_name = "retail-dev-airflow-role"
    }
    prod = {
      subnet_id = aws_subnet.private["private2"].id
      role_name = "retail-prod-airflow-role"
    }
  }
}

# --- AMI -------------------------------------------------------------------
# Amazon Linux 2023, latest, looked up rather than pinned — this is a
# throwaway dev box that gets rebuilt rarely, not a resource where AMI drift
# matters the way it would for a long-lived production fleet.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Security group ----------------------------------------------------------
# No inbound from the internet at all. The subnets are private with no IGW
# (ADR 0003) — reaching the Airflow UI happens via SSM Session Manager port
# forwarding, not a public IP or an open security group rule.

resource "aws_security_group" "airflow" {
  for_each = local.airflow_environments

  name        = "retail-${each.key}-airflow-sg"
  description = "Airflow instance - ${each.key}. No inbound; reached via SSM."
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to AWS services, Snowflake, PyPI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = each.key
    Component   = "airflow"
  }
}

# --- IAM role ----------------------------------------------------------------
# What the instance itself can do, distinct from what Airflow's DAG tasks do
# inside Snowflake. This role: start/poll Glue jobs, read the SSM parameter
# holding the Snowflake key for its OWN environment only, and be reachable
# via SSM Session Manager (no SSH key pair, no bastion, no open port 22).

resource "aws_iam_role" "airflow" {
  for_each = local.airflow_environments

  name        = each.value.role_name
  description = "EC2 instance role for Airflow - ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM Session Manager access — how you reach the box and how CI deploys DAG
# files to it (send-command), with no inbound network path at all.
resource "aws_iam_role_policy_attachment" "airflow_ssm" {
  for_each = local.airflow_environments

  role       = aws_iam_role.airflow[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "airflow" {
  for_each = local.airflow_environments

  name = "retail-${each.key}-airflow-policy"
  role = aws_iam_role.airflow[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GlueJobControl"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"]
        Resource = "arn:aws:glue:${var.region}:${var.account_id}:job/retail-${each.key}-*"
      },
      {
        # Scoped to this environment's Snowflake key only. The dev instance
        # role cannot read /retail/prod/*, matching the CI roles.
        Sid      = "ReadOwnSnowflakeKey"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/retail/${each.key}/snowflake/private_key"
      },
      {
        Sid      = "DecryptViaSSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
      {
        # Read staged/raw for direct COPY INTO calls issued from a DAG task,
        # not through the Snowflake integration — this is Airflow reading S3
        # object listings to confirm data landed before triggering a load,
        # not reading the objects themselves.
        Sid    = "ListOwnBuckets"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.buckets["${each.key}-raw"].name}",
          "arn:aws:s3:::${local.buckets["${each.key}-staged"].name}",
        ]
      },
      {
        # Read the pre-built Python packages uploaded by
        # scripts/build_wheelhouse.sh. See ADR 0015 — there is no route
        # from this subnet to PyPI, so packages come from here instead.
        Sid    = "ReadOwnWheelhouse"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.buckets["${each.key}-staged"].name}",
          "arn:aws:s3:::${local.buckets["${each.key}-staged"].name}/_wheelhouse/*",
        ]
      },
      {
        # Read the DAG files the deploy workflow uploads to S3
        # (airflow-deploy.yml). Without this, `aws s3 sync` running ON THE
        # INSTANCE via SSM fails with AccessDenied on every object — but the
        # overall SSM command can still report Success, because
        # AWS-RunShellScript does not stop on a failed line mid-script by
        # default (the `chown` on an unchanged, possibly-empty directory
        # still exits 0). The workflow showed "DAG sync succeeded." while
        # nothing actually landed on disk. Found 2026-08-28 — the instance
        # role had never been granted access to this prefix at all.
        Sid    = "ReadOwnAirflowDags"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.buckets["${each.key}-staged"].name}",
          "arn:aws:s3:::${local.buckets["${each.key}-staged"].name}/_airflow-dags/*",
        ]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "airflow" {
  for_each = local.airflow_environments

  name = "retail-${each.key}-airflow-profile"
  role = aws_iam_role.airflow[each.key].name
}

# --- Instances -----------------------------------------------------------
#
# lifecycle.prevent_destroy: `terraform destroy`, or accidentally deleting
# this resource block, FAILS loudly instead of silently terminating the
# instance. The guard must be deliberately removed first. This exists
# because "pause" here means STOP, never destroy — see the runbook.
#
# Set back to TRUE here. It was left FALSE after the 2026-08-27 bootstrap
# fixes and again during the 2026-08-31 t3.medium attempt (which itself
# destroyed and recreated both instances when it failed — see the incident
# note in ADR 0014's amendments). No further -replace is planned in the
# current verification flow, so the guard goes back on now rather than
# staying open longer than each specific fix needs.

resource "aws_instance" "airflow" {
  for_each = local.airflow_environments

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.airflow_instance_type
  subnet_id              = each.value.subnet_id
  vpc_security_group_ids = [aws_security_group.airflow[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.airflow[each.key].name

  # Runs once, on first boot only. Idempotent re-runs (e.g. after a stop and
  # restart, which does NOT re-run user_data) are not needed — the box keeps
  # its disk, so Airflow, dbt and the DAG files all persist across a
  # stop/start cycle. NOTE: both instances were recreated on 2026-08-31 (the
  # failed t3.medium attempt destroyed the originals) — swap file and any
  # other interactive on-box fixes from before that date do NOT carry over
  # and need reapplying on the current instances.
  user_data = templatefile("${path.module}/../../scripts/airflow_bootstrap.sh.tpl", {
    environment      = each.key
    aws_region       = var.region
    s3_staged_bucket = local.buckets["${each.key}-staged"].name
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens                = "required"  # IMDSv2 only — blocks the SSRF-to-credential-theft pattern IMDSv1 is vulnerable to
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name        = "retail-${each.key}-airflow"
    Environment = each.key
    Component   = "airflow"
  }

  lifecycle {
    prevent_destroy = true
    # user_data changes do not force replacement — see the note above about
    # it only running on first boot. Changing it will not retroactively
    # apply; that requires a manual re-run or a fresh instance.
    ignore_changes = [ami]
  }
}

# --- Power state toggle ----------------------------------------------------
#
# Flip var.airflow_instance_state and apply to start or stop. This does NOT
# create or destroy the instance — aws_instance.airflow above is created
# exactly once and every other `terraform apply` in this project, for
# unrelated changes, leaves it untouched.
#
# --profile and --output are EXPLICIT here, not left to ambient shell
# config. Without them, this command intermittently failed with
# "Unknown output type: None" — the AWS CLI resolving to a broken output
# format when invoked from Terraform's local-exec (a different execution
# context than an interactive shell, where ambient config behaves
# differently). Found 2026-08-31.

resource "null_resource" "airflow_power_state" {
  for_each = local.airflow_environments

  triggers = {
    desired_state = var.airflow_instance_state
    instance_id   = aws_instance.airflow[each.key].id
  }

  provisioner "local-exec" {
    command = var.airflow_instance_state == "running" ? (
      "aws ec2 start-instances --instance-ids ${aws_instance.airflow[each.key].id} --region ${var.region} --profile retail-dev --output json"
      ) : (
      "aws ec2 stop-instances --instance-ids ${aws_instance.airflow[each.key].id} --region ${var.region} --profile retail-dev --output json"
    )
  }
}

# --- Outputs -----------------------------------------------------------

output "airflow_instance_ids" {
  description = "For SSM commands: aws ssm start-session --target <id>"
  value       = { for k, v in aws_instance.airflow : k => v.id }
}
