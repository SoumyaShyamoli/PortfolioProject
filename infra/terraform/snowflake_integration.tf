# IAM roles that Snowflake assumes to read staged data.
#
# The Snowflake side of this — the storage integration itself — is hand-run
# DDL in snowflake/setup/04_storage_integration.sql. See the amendment to
# ADR 0011 for why that changed from the original all-Terraform plan.
#
# THE SETUP ORDER:
#   1. Run PART A of 04_storage_integration.sql   (creates integrations)
#   2. Run PART B, copy the generated values      (DESC INTEGRATION)
#   3. Put them in terraform.tfvars, apply this   (creates roles + trust)
#   4. Run PART C to verify                       (LIST @stage)
#
# Snowflake generates STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID.
# They cannot be predicted, which is why the integration must exist first.

locals {
  snowflake_integrations = {
    dev = {
      staged_bucket = local.buckets["dev-staged"].name
      raw_bucket    = local.buckets["dev-raw"].name
      role_name     = "retail-dev-snowflake-integration-role"
      external_id   = var.snowflake_external_id_dev
    }
    prod = {
      staged_bucket = local.buckets["prod-staged"].name
      raw_bucket    = local.buckets["prod-raw"].name
      role_name     = "retail-prod-snowflake-integration-role"
      external_id   = var.snowflake_external_id_prod
    }
  }
}

# --- IAM roles Snowflake assumes -------------------------------------------
#
# The external ID is the important part of this trust policy. Without it,
# any Snowflake account that learned this role ARN could attempt to assume
# it — the confused deputy problem. The external ID is unique per
# integration and known only to this Snowflake account.

resource "aws_iam_role" "snowflake_integration" {
  for_each = local.snowflake_integrations

  name        = each.value.role_name
  description = "Assumed by Snowflake to read staged data - ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.snowflake_iam_user_arn }
      Condition = {
        StringEquals = {
          "sts:ExternalId" = each.value.external_id
        }
      }
    }]
  })

  tags = {
    Environment = each.key
    Component   = "snowflake-integration"
  }
}

# Read-only, and only the two prefixes the integration is allowed to reach.
#
# No write access: Snowflake reads from staged, it does not write there.
# That also means this role cannot serve Snowflake UNLOAD operations — if
# those are needed later they get their own role rather than widening this
# one.
resource "aws_iam_role_policy" "snowflake_integration" {
  for_each = local.snowflake_integrations

  name = "${each.value.role_name}-policy"
  role = aws_iam_role.snowflake_integration[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadStagedObjects"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "arn:aws:s3:::${each.value.staged_bucket}/orders/*",
          "arn:aws:s3:::${each.value.staged_bucket}/_audit/*",
        ]
      },
      {
        # ListBucket applies to the BUCKET arn, not to objects — a common
        # mistake that produces a confusing "access denied" on LIST while
        # GET works fine. Scoped by prefix so it cannot enumerate the rest
        # of the bucket.
        Sid      = "ListStagedPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${each.value.staged_bucket}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["orders/*", "_audit/*"]
          }
        }
      },
      {
        # World Bank reference data only. NOT the orders prefix — Snowflake
        # reads orders from staged (Parquet), and granting raw access to
        # orders would let it bypass the Glue conversion entirely.
        Sid      = "ReadRawWorldBank"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = ["arn:aws:s3:::${each.value.raw_bucket}/worldbank/*"]
      },
      {
        Sid      = "ListRawWorldBank"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${each.value.raw_bucket}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["worldbank/*"]
          }
        }
      },
    ]
  })
}

output "snowflake_integration_role_arns" {
  description = "Role ARNs — these go in STORAGE_AWS_ROLE_ARN on the integrations"
  value       = { for k, v in aws_iam_role.snowflake_integration : k => v.arn }
}
