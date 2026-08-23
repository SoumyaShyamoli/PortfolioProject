# IAM — adopted from console-created roles, then tidied.
#
# Five roles split by function (see docs/adr/0004):
#   pipeline exec  — assumed by Glue at runtime, one per environment
#   cicd deploy    — assumed by GitHub Actions via OIDC, one per environment
#   human admin    — break-glass and manual inspection
#
# Generated originally by `terraform plan -generate-config-out`; the verbose
# provider defaults have been removed and the policies corrected.

locals {
  github_repo = "SoumyaShyamoli/PortfolioProject"

  # Must match local.glue_script_key in glue.tf. The deploy roles need write
  # access to exactly this prefix — an earlier version granted "scripts/*"
  # while the job read from "_scripts/", so deploys would have 403'd.
  script_prefix = "_scripts"
}

# --- GitHub OIDC provider ------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998"]
}

# =========================================================================
# Pipeline execution roles — assumed by Glue
# =========================================================================

resource "aws_iam_role" "dev_pipeline_exec" {
  name        = "retail-dev-pipeline-exec-role"
  description = "Glue job execution - dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "prod_pipeline_exec" {
  name        = "retail-prod-pipeline-exec-role"
  description = "Glue job execution - prod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

# AWS baseline for Glue service roles. Provides the EC2 network permissions
# (CreateNetworkInterface, DescribeSubnets, ...) that a VPC-attached job
# needs. Broader than the inline policies below — retained for now, to be
# re-evaluated once the job runs successfully (see ADR 0004 follow-ups).
resource "aws_iam_role_policy_attachment" "dev_pipeline_exec_glue_service" {
  role       = aws_iam_role.dev_pipeline_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "prod_pipeline_exec_glue_service" {
  role       = aws_iam_role.prod_pipeline_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "dev_pipeline_exec" {
  name = "retail-dev-pipeline-exec-rolePolicy"
  role = aws_iam_role.dev_pipeline_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only on raw. Raw is the immutable replay point (ADR 0005), so
        # the pipeline role deliberately cannot delete or overwrite it.
        Sid    = "S3ReadRawDev"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.buckets["dev-raw"].name}",
          "arn:aws:s3:::${local.buckets["dev-raw"].name}/*",
        ]
      },
      {
        # DeleteObject is required: dynamic partition overwrite deletes the
        # existing files in a partition before writing new ones. Without it,
        # every rerun fails and the idempotency guarantee does not hold.
        #
        # Abort/ListMultipartUploadParts: Spark writes larger files as
        # multipart uploads; without abort rights a failed write leaves
        # orphaned parts accruing storage charges.
        #
        # Safe to grant because staged is fully reproducible from raw.
        Sid    = "S3WriteStagedDev"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${local.buckets["dev-staged"].name}",
          "arn:aws:s3:::${local.buckets["dev-staged"].name}/*",
        ]
      },
      # No curated access. Curated belongs to Project 2 (Databricks); nothing
      # in this pipeline writes there.
      {
        Sid      = "GlueCatalogAccess"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetDatabase", "glue:CreateTable", "glue:UpdateTable"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:/aws-glue/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "prod_pipeline_exec" {
  name = "retail-prod-pipeline-exec-rolePolicy"
  role = aws_iam_role.prod_pipeline_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadRawProd"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.buckets["prod-raw"].name}",
          "arn:aws:s3:::${local.buckets["prod-raw"].name}/*",
        ]
      },
      {
        Sid    = "S3WriteStagedProd"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${local.buckets["prod-staged"].name}",
          "arn:aws:s3:::${local.buckets["prod-staged"].name}/*",
        ]
      },
      {
        Sid      = "GlueCatalogAccess"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetDatabase", "glue:CreateTable", "glue:UpdateTable"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:/aws-glue/*"
      },
    ]
  })
}

# =========================================================================
# CI/CD deploy roles — assumed by GitHub Actions via OIDC
# =========================================================================
# No static access keys exist. The prod role's trust is scoped to the main
# branch, so a pull request from a fork cannot obtain production credentials.

resource "aws_iam_role" "dev_cicd_deploy" {
  name        = "retail-dev-cicd-deploy-role"
  description = "GitHub Actions deploy - dev (any branch)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role" "prod_cicd_deploy" {
  name        = "retail-cicd-deploy-role"
  description = "GitHub Actions deploy - prod (main branch only)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "dev_cicd_deploy" {
  name = "retail-dev-cicd-deploy-rolePolicy"
  role = aws_iam_role.dev_cicd_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GlueJobDeployDev"
        Effect   = "Allow"
        Action   = ["glue:CreateJob", "glue:UpdateJob", "glue:GetJob", "glue:DeleteJob", "glue:StartJobRun", "glue:GetJobRun", "glue:GetConnection", "glue:CreateConnection", "glue:UpdateConnection"]
        Resource = "*"
      },
      {
        # Prefix corrected to match local.script_prefix in glue.tf.
        Sid      = "S3DeployArtifactsDev"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.buckets["dev-staged"].name}/${local.script_prefix}/*"]
      },
      {
        # Needed to list the prefix during deploy; scoped by prefix condition.
        Sid      = "S3ListStagedDev"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.buckets["dev-staged"].name}"]
        Condition = {
          StringLike = { "s3:prefix" = ["${local.script_prefix}/*"] }
        }
      },
      {
        # A deploy role that can create Glue jobs must be able to hand the
        # execution role to Glue. Scoped to that one role and that one
        # service, so it cannot pass a more privileged role instead.
        Sid       = "PassRoleToGlueDev"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.dev_pipeline_exec.arn
        Condition = { StringEquals = { "iam:PassedToService" = "glue.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_iam_role_policy" "prod_cicd_deploy" {
  name = "retail-cicd-deploy-role"
  role = aws_iam_role.prod_cicd_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GlueJobDeployProd"
        Effect   = "Allow"
        Action   = ["glue:CreateJob", "glue:UpdateJob", "glue:GetJob", "glue:DeleteJob", "glue:StartJobRun", "glue:GetJobRun", "glue:GetConnection", "glue:CreateConnection", "glue:UpdateConnection"]
        Resource = "*"
      },
      {
        Sid      = "S3DeployArtifactsProd"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.buckets["prod-staged"].name}/${local.script_prefix}/*"]
      },
      {
        Sid      = "S3ListStagedProd"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.buckets["prod-staged"].name}"]
        Condition = {
          StringLike = { "s3:prefix" = ["${local.script_prefix}/*"] }
        }
      },
      {
        Sid       = "PassRoleToGlueProd"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.prod_pipeline_exec.arn
        Condition = { StringEquals = { "iam:PassedToService" = "glue.amazonaws.com" } }
      },
    ]
  })
}

# =========================================================================
# Human admin role — break-glass and manual inspection
# =========================================================================

resource "aws_iam_role" "human_admin" {
  name        = "retail-human-admin-role"
  description = "Break-glass and manual inspection"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
    }]
  })
}

resource "aws_iam_role_policy" "human_admin" {
  name = "retail-human-admin-role"
  role = aws_iam_role.human_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3FullAccessProjectBuckets"
        Effect = "Allow"
        Action = "s3:*"
        Resource = flatten([
          for k, v in local.buckets : [
            "arn:aws:s3:::${v.name}",
            "arn:aws:s3:::${v.name}/*",
          ]
        ])
      },
      {
        Sid      = "GlueAdmin"
        Effect   = "Allow"
        Action   = "glue:*"
        Resource = "*"
      },
      {
        Sid      = "IAMReadOnly"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogsRead"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = "*"
      },
      {
        Sid      = "SecretsManagerKMSRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:ListSecrets", "kms:Decrypt", "kms:DescribeKey"]
        Resource = "*"
      },
    ]
  })
}
