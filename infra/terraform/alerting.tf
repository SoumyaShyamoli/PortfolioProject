# Alerting — SNS + CloudWatch alarms on pipeline failures.
#
# Three failure modes are covered:
#   1. Glue job run fails (JobRunState = FAILED/TIMEOUT/STOPPED)
#   2. World Bank Lambda invocation fails
#   3. Reconciliation mismatch — the Glue job's own recon check found
#      balanced: false but did NOT crash (--fail_on_recon_mismatch=false),
#      or a human needs to know a genuine data anomaly blocked processing.
#
# STREAMING NOTE: when the Firehose/producer path is added, extend
# sns_alert_environments with a Firehose delivery-failure alarm
# (DeliveryToS3.DataFreshness or similar) using the same topic — the alerting
# fan-out here is designed to take additional sources without restructuring.

locals {
  alert_environments = {
    dev = {
      email = var.alert_email_dev
    }
    prod = {
      email = var.alert_email_prod
    }
  }
}

# --- SNS topics ------------------------------------------------------------
# One topic per environment, so a dev failure while iterating doesn't compete
# for attention with a prod failure.

resource "aws_sns_topic" "pipeline_alerts" {
  for_each = local.alert_environments

  name = "retail-${each.key}-pipeline-alerts"

  # AWS-managed key, no separate cost (unlike S3's CMK tradeoff — SNS's
  # default KMS key is free to use, so there's no reason to accept this
  # one the way ADR 0013 accepts S3's).
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Environment = each.key
  }
}

resource "aws_sns_topic_subscription" "email" {
  for_each = local.alert_environments

  topic_arn = aws_sns_topic.pipeline_alerts[each.key].arn
  protocol  = "email"
  endpoint  = each.value.email

  # Note: SNS email subscriptions require manual confirmation via a link
  # sent to the address. Terraform cannot complete this step — check the
  # inbox after apply and confirm before relying on alerts.
}

# --- Glue job failure alarms -------------------------------------------------
# Glue publishes glue.driver.aggregate.numFailedTasks and job-run-state
# metrics to CloudWatch under the AWS/Glue namespace automatically — no
# custom metric needed for the basic failure signal.

resource "aws_cloudwatch_metric_alarm" "glue_job_failed" {
  for_each = local.alert_environments

  alarm_name        = "retail-${each.key}-glue-json-to-parquet-failed"
  alarm_description = "Glue json-to-parquet job failed, timed out, or was stopped"

  namespace   = "Glue"
  metric_name = "glue.driver.aggregate.numFailedTasks"
  dimensions = {
    JobName  = "retail-${each.key}-json-to-parquet"
    JobRunId = "ALL"
    Type     = "gauge"
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.pipeline_alerts[each.key].arn]
}

# --- Lambda failure alarms --------------------------------------------------
# The Lambda Errors metric increments on any unhandled exception, including
# the ValueError this function deliberately raises when fetched != written.

resource "aws_cloudwatch_metric_alarm" "worldbank_lambda_failed" {
  for_each = local.alert_environments

  alarm_name        = "retail-${each.key}-worldbank-ingest-failed"
  alarm_description = "World Bank reference ingestion Lambda failed"

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = "retail-${each.key}-worldbank-ingest"
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.pipeline_alerts[each.key].arn]
}

# --- Reconciliation mismatch alarm (log-based metric filter) ---------------
# The Glue job always prints a RECON_RESULT line, whether it fails the job
# or not. This filter fires specifically on balanced:false, independent of
# whether --fail_on_recon_mismatch caused the job itself to fail — so a
# silent mismatch (the escape hatch case) is still surfaced.

resource "aws_cloudwatch_log_metric_filter" "recon_mismatch" {
  for_each = local.alert_environments

  name           = "retail-${each.key}-recon-mismatch"
  log_group_name = "/aws-glue/jobs/output"

  # Matches the RECON_RESULT JSON line only when "balanced":false appears.
  # CloudWatch Logs filter pattern syntax, not regex.
  pattern = "RECON_UNBALANCED"

  metric_transformation {
    name          = "ReconciliationMismatch"
    namespace     = "RetailPlatform/${title(each.key)}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "recon_mismatch" {
  for_each = local.alert_environments

  alarm_name        = "retail-${each.key}-recon-mismatch"
  alarm_description = "Glue job reconciliation did not balance — possible silent data loss"

  namespace   = "RetailPlatform/${title(each.key)}"
  metric_name = "ReconciliationMismatch"

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.pipeline_alerts[each.key].arn]

  tags = {
    Environment = each.key
    Severity    = "high" # a mismatch means data may be wrong, not just late
  }
}

# --- Budget-adjacent: SNS is also where a billing alarm would publish ------
# Not built here — the AWS Budget alert created by hand at the start of the
# project already covers cost. Left as a note rather than duplicated, since
# a second, differently-configured cost alert is a common source of
# confusing double-notifications.
