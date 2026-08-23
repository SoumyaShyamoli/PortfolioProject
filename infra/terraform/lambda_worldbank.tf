# World Bank reference data ingestion.
#
# Runs OUTSIDE the VPC — deliberately. The private subnets have no NAT and no
# internet gateway (ADR 0003), so a function that calls a public API is placed
# outside rather than paying ~£30/month for NAT to reach one free API.
#
# Cost: comfortably inside the Lambda free tier. Monthly schedule, a few
# seconds per invocation.

locals {
  worldbank_environments = {
    dev = {
      raw_bucket = local.buckets["dev-raw"].name
    }
    prod = {
      raw_bucket = local.buckets["prod-raw"].name
    }
  }

  # Mid-dataset. Online Retail II spans Dec 2009 - Dec 2011, so 2010 is the
  # representative year for a point-in-time GDP/population join.
  worldbank_indicator_year = "2010"
}

# --- Package -------------------------------------------------------------
# No dependencies beyond the standard library and the boto3 that Lambda
# provides, so the deployment package is a zip of one file.

data "archive_file" "worldbank" {
  type        = "zip"
  source_file = "${path.module}/../../ingestion/worldbank/fetch_worldbank.py"
  output_path = "${path.module}/.build/fetch_worldbank.zip"
}

# --- Execution role ------------------------------------------------------
# Separate from the Glue pipeline execution role. This one WRITES to raw,
# which the pipeline role deliberately cannot do (raw is its replay point).
# Different job, different trust boundary, different role — ADR 0004.

resource "aws_iam_role" "worldbank_lambda" {
  for_each = local.worldbank_environments

  name        = "retail-${each.key}-worldbank-ingest-role"
  description = "World Bank reference ingestion - ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "worldbank_lambda" {
  for_each = local.worldbank_environments

  name = "retail-${each.key}-worldbank-ingest-policy"
  role = aws_iam_role.worldbank_lambda[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to the two prefixes this function owns. It cannot touch the
        # orders data sitting in the same bucket.
        Sid    = "WriteWorldBankPrefixes"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "arn:aws:s3:::${each.value.raw_bucket}/worldbank/*",
          "arn:aws:s3:::${each.value.raw_bucket}/_audit/worldbank/*",
        ]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# --- Function ------------------------------------------------------------

resource "aws_lambda_function" "worldbank" {
  for_each = local.worldbank_environments

  function_name = "retail-${each.key}-worldbank-ingest"
  description   = "Fetch World Bank country metadata, GDP and population"

  role    = aws_iam_role.worldbank_lambda[each.key].arn
  handler = "fetch_worldbank.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.worldbank.output_path
  source_code_hash = data.archive_file.worldbank.output_base64sha256

  # Three paginated API calls against a free public API that is sometimes
  # slow. 60s is generous; the retry logic bounds the worst case.
  timeout     = 60
  memory_size = 256

  # No vpc_config block. See the note at the top of this file.

  environment {
    variables = {
      RAW_BUCKET     = each.value.raw_bucket
      INDICATOR_YEAR = local.worldbank_indicator_year
    }
  }

  tags = {
    Environment = each.key
    Component   = "ingestion"
  }
}

# --- Log retention -------------------------------------------------------
# Lambda creates its log group implicitly with NEVER EXPIRE retention.
# Declaring it here caps the retention so logs cannot accumulate cost
# indefinitely — small, but it is the kind of thing that is invisible until
# it is not.

resource "aws_cloudwatch_log_group" "worldbank" {
  for_each = local.worldbank_environments

  name              = "/aws/lambda/${aws_lambda_function.worldbank[each.key].function_name}"
  retention_in_days = 14

  tags = {
    Environment = each.key
  }
}

# --- Schedule ------------------------------------------------------------
# Reference data changes rarely — World Bank revises indicators a few times a
# year. Monthly is more than enough, and each run overwrites in place.
#
# Disabled in prod until the prod pipeline is actually running, so nothing
# fires against an empty environment.

resource "aws_cloudwatch_event_rule" "worldbank_monthly" {
  for_each = local.worldbank_environments

  name                = "retail-${each.key}-worldbank-monthly"
  description         = "Monthly World Bank reference data refresh"
  schedule_expression = "cron(0 3 1 * ? *)" # 03:00 UTC on the 1st
  state               = each.key == "dev" ? "ENABLED" : "DISABLED"
}

resource "aws_cloudwatch_event_target" "worldbank_monthly" {
  for_each = local.worldbank_environments

  rule      = aws_cloudwatch_event_rule.worldbank_monthly[each.key].name
  target_id = "lambda"
  arn       = aws_lambda_function.worldbank[each.key].arn
}

resource "aws_lambda_permission" "worldbank_events" {
  for_each = local.worldbank_environments

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.worldbank[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.worldbank_monthly[each.key].arn
}

# --- Outputs -------------------------------------------------------------

output "worldbank_function_names" {
  description = "World Bank ingestion function names, for manual invocation"
  value       = { for k, v in aws_lambda_function.worldbank : k => v.function_name }
}
