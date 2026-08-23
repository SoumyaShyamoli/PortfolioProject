# __generated__ by Terraform
# Please review these resources and move them into your main configuration files.

# __generated__ by Terraform from "retail-dev-cicd-deploy-role:retail-dev-cicd-deploy-rolePolicy"
resource "aws_iam_role_policy" "dev_cicd_deploy" {
  name = "retail-dev-cicd-deploy-rolePolicy"
  policy = jsonencode({
    Statement = [{
      Action   = ["glue:CreateJob", "glue:UpdateJob", "glue:GetJob", "glue:DeleteJob", "glue:StartJobRun", "glue:GetJobRun"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "GlueJobDeployDev"
      }, {
      Action   = ["s3:PutObject", "s3:GetObject"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-dev-staged-009073574996-eu-west-2-an/scripts/*"]
      Sid      = "S3DeployArtifactsDev"
      }, {
      Action = "iam:PassRole"
      Condition = {
        StringEquals = {
          "iam:PassedToService" = "glue.amazonaws.com"
        }
      }
      Effect   = "Allow"
      Resource = "arn:aws:iam::009073574996:role/retail-dev-pipeline-exec-role"
      Sid      = "PassRoleToGlueDev"
    }]
    Version = "2012-10-17"
  })
  role = "retail-dev-cicd-deploy-role"
}

# __generated__ by Terraform from "retail-prod-pipeline-exec-role:retail-prod-pipeline-exec-rolePolicy"
resource "aws_iam_role_policy" "prod_pipeline_exec" {
  name = "retail-prod-pipeline-exec-rolePolicy"
  policy = jsonencode({
    Statement = [{
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-prod-raw-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-raw-009073574996-eu-west-2-an/*"]
      Sid      = "S3ReadRawProd"
      }, {
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-prod-curated-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-curated-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-prod-staged-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-staged-009073574996-eu-west-2-an/*"]
      Sid      = "S3WriteStagedCuratedProd"
      }, {
      Action   = ["glue:GetTable", "glue:GetDatabase", "glue:CreateTable", "glue:UpdateTable"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "GlueCatalogAccess"
      }, {
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Effect   = "Allow"
      Resource = "arn:aws:logs:*:*:/aws-glue/*"
      Sid      = "CloudWatchLogs"
    }]
    Version = "2012-10-17"
  })
  role = "retail-prod-pipeline-exec-role"
}

# __generated__ by Terraform from "retail-human-admin-role:retail-human-admin-role"
resource "aws_iam_role_policy" "human_admin" {
  name = "retail-human-admin-role"
  policy = jsonencode({
    Statement = [{
      Action   = "s3:*"
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-dev-raw-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-raw-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-dev-staged-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-staged-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-dev-curated-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-curated-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-prod-raw-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-raw-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-prod-staged-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-staged-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-prod-curated-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-prod-curated-009073574996-eu-west-2-an/*"]
      Sid      = "S3FullAccessProjectBuckets"
      }, {
      Action   = "glue:*"
      Effect   = "Allow"
      Resource = "*"
      Sid      = "GlueAdmin"
      }, {
      Action   = ["iam:Get*", "iam:List*"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "IAMReadOnly"
      }, {
      Action   = ["logs:GetLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "CloudWatchLogsRead"
      }, {
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:ListSecrets", "kms:Decrypt", "kms:DescribeKey"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "SecretsManagerKMSRead"
    }]
    Version = "2012-10-17"
  })
  role = "retail-human-admin-role"
}

# __generated__ by Terraform
resource "aws_iam_openid_connect_provider" "github" {
  client_id_list  = ["sts.amazonaws.com"]
  tags            = {}
  tags_all        = {}
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998"]
  url             = "https://token.actions.githubusercontent.com"
}

# __generated__ by Terraform from "retail-prod-pipeline-exec-role/arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
resource "aws_iam_role_policy_attachment" "prod_pipeline_exec_glue_service" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
  role       = "retail-prod-pipeline-exec-role"
}

# __generated__ by Terraform from "retail-cicd-deploy-role"
resource "aws_iam_role" "prod_cicd_deploy" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:SoumyaShyamoli/PortfolioProject:ref:refs/heads/main"
        }
      }
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::009073574996:oidc-provider/token.actions.githubusercontent.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "CICD PROD"
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "retail-cicd-deploy-role"
  path                  = "/"
  permissions_boundary  = null
  tags                  = {}
  tags_all              = {}
}

# __generated__ by Terraform from "retail-dev-cicd-deploy-role"
resource "aws_iam_role" "dev_cicd_deploy" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:SoumyaShyamoli/PortfolioProject:*"
        }
      }
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::009073574996:oidc-provider/token.actions.githubusercontent.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "CICD fo Dev"
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "retail-dev-cicd-deploy-role"
  path                  = "/"
  permissions_boundary  = null
  tags                  = {}
  tags_all              = {}
}

# __generated__ by Terraform from "retail-human-admin-role"
resource "aws_iam_role" "human_admin" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action    = "sts:AssumeRole"
      Condition = {}
      Effect    = "Allow"
      Principal = {
        AWS = "arn:aws:iam::009073574996:root"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Human Admin Role"
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "retail-human-admin-role"
  path                  = "/"
  permissions_boundary  = null
  tags                  = {}
  tags_all              = {}
}

# __generated__ by Terraform from "retail-dev-pipeline-exec-role"
resource "aws_iam_role" "dev_pipeline_exec" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Allows Glue to call AWS services on your behalf. "
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "retail-dev-pipeline-exec-role"
  path                  = "/"
  permissions_boundary  = null
  tags                  = {}
  tags_all              = {}
}

# __generated__ by Terraform from "retail-prod-pipeline-exec-role"
resource "aws_iam_role" "prod_pipeline_exec" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Allows Glue to call AWS services on your behalf. "
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "retail-prod-pipeline-exec-role"
  path                  = "/"
  permissions_boundary  = null
  tags                  = {}
  tags_all              = {}
}

# __generated__ by Terraform from "retail-dev-pipeline-exec-role/arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
resource "aws_iam_role_policy_attachment" "dev_pipeline_exec_glue_service" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
  role       = "retail-dev-pipeline-exec-role"
}

# __generated__ by Terraform from "retail-dev-pipeline-exec-role:retail-dev-pipeline-exec-rolePolicy"
resource "aws_iam_role_policy" "dev_pipeline_exec" {
  name = "retail-dev-pipeline-exec-rolePolicy"
  policy = jsonencode({
    Statement = [{
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-dev-raw-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-raw-009073574996-eu-west-2-an/*"]
      Sid      = "S3ReadRawDev"
      }, {
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-dev-staged-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-staged-009073574996-eu-west-2-an/*", "arn:aws:s3:::sd-retail-dev-curated-009073574996-eu-west-2-an", "arn:aws:s3:::sd-retail-dev-curated-009073574996-eu-west-2-an/*"]
      Sid      = "S3WriteStagedCuratedDev"
      }, {
      Action   = ["glue:GetTable", "glue:GetDatabase", "glue:CreateTable", "glue:UpdateTable"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "GlueCatalogAccess"
      }, {
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Effect   = "Allow"
      Resource = "arn:aws:logs:*:*:/aws-glue/*"
      Sid      = "CloudWatchLogs"
    }]
    Version = "2012-10-17"
  })
  role = "retail-dev-pipeline-exec-role"
}

# __generated__ by Terraform from "retail-cicd-deploy-role:retail-cicd-deploy-role"
resource "aws_iam_role_policy" "prod_cicd_deploy" {
  name = "retail-cicd-deploy-role"
  policy = jsonencode({
    Statement = [{
      Action   = ["glue:CreateJob", "glue:UpdateJob", "glue:GetJob", "glue:DeleteJob", "glue:StartJobRun", "glue:GetJobRun"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "GlueJobDeployProd"
      }, {
      Action   = ["s3:PutObject", "s3:GetObject"]
      Effect   = "Allow"
      Resource = ["arn:aws:s3:::sd-retail-prod-staged-009073574996-eu-west-2-an/scripts/*"]
      Sid      = "S3DeployArtifactsProd"
      }, {
      Action = "iam:PassRole"
      Condition = {
        StringEquals = {
          "iam:PassedToService" = "glue.amazonaws.com"
        }
      }
      Effect   = "Allow"
      Resource = "arn:aws:iam::009073574996:role/retail-prod-pipeline-exec-role"
      Sid      = "PassRoleToGlueProd"
    }]
    Version = "2012-10-17"
  })
  role = "retail-cicd-deploy-role"
}
