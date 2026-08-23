# Glue: JSON -> Parquet conversion job, one per environment.
#
# Both environments run the IDENTICAL script. The only difference is which
# buckets and role are passed in as job arguments, so "it worked in dev"
# means something — the artifact promoted to prod is the same file, not a
# rebuilt or re-edited one.
#
# See docs/adr/0006 for why Glue rather than EMR.

locals {
  glue_environments = {
    dev = {
      role_arn      = aws_iam_role.dev_pipeline_exec.arn
      raw_bucket    = local.buckets["dev-raw"].name
      staged_bucket = local.buckets["dev-staged"].name
    }
    prod = {
      role_arn      = aws_iam_role.prod_pipeline_exec.arn
      raw_bucket    = local.buckets["prod-raw"].name
      staged_bucket = local.buckets["prod-staged"].name
    }
  }

  glue_script_key = "_scripts/json_to_parquet.py"
}

# --- Script upload -------------------------------------------------------
# The script lives in the repo and is uploaded from there. source_hash means
# Terraform re-uploads whenever the file changes, so the deployed script
# cannot silently drift from what is committed.
#
# In CI this upload is done by the deploy workflow rather than Terraform;
# keeping it here as well means a local `terraform apply` never leaves the
# job pointing at a stale script.

resource "aws_s3_object" "glue_script" {
  for_each = local.glue_environments

  bucket      = each.value.staged_bucket
  key         = local.glue_script_key
  source      = "${path.module}/../../glue/jobs/json_to_parquet.py"
  source_hash = filemd5("${path.module}/../../glue/jobs/json_to_parquet.py")

  tags = {
    Environment = each.key
  }
}

# --- Glue connection -----------------------------------------------------
# Attaches the job to the private subnets. Without this the job runs on
# Glue's own network and the VPC design in ADR 0002/0003 is decorative.
#
# A NETWORK connection needs exactly one subnet. Glue will use the AZ of
# whichever subnet is named here; the second subnet exists so the connection
# can be repointed if that AZ has problems.

resource "aws_glue_connection" "vpc" {
  name            = "retail-vpc-connection"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = aws_subnet.private["private1"].availability_zone
    subnet_id              = aws_subnet.private["private1"].id
    security_group_id_list = [aws_security_group.glue.id]
  }
}

# --- Jobs ----------------------------------------------------------------

resource "aws_glue_job" "json_to_parquet" {
  for_each = local.glue_environments

  name        = "retail-${each.key}-json-to-parquet"
  description = "Convert one month of raw NDJSON to partitioned Parquet"
  role_arn    = each.value.role_arn

  glue_version      = "4.0"
  worker_type       = "G.1X" # smallest available; see ADR 0006 on cost
  number_of_workers = 2      # minimum for a Spark job

  # Fail fast. The default is 2880 minutes (48 hours) — a hung job at that
  # timeout would cost more than the entire project budget.
  timeout = 15

  # No automatic retries. A failed run here usually means bad input or a
  # reconciliation mismatch, and retrying makes it harder to see what
  # happened. Retry deliberately after looking.
  max_retries = 0

  connections = [aws_glue_connection.vpc.name]

  command {
    name            = "glueetl"
    script_location = "s3://${each.value.staged_bucket}/${local.glue_script_key}"
    python_version  = "3"
  }

  default_arguments = {
    "--input_bucket"  = each.value.raw_bucket
    "--output_bucket" = each.value.staged_bucket

    # year and month are supplied per-run, not here. Defaults would make it
    # possible to trigger a run without specifying a period, which would
    # silently process the wrong month.

    "--fail_on_recon_mismatch" = "true"

    # Job bookmarks disabled: this job is idempotent by design (dynamic
    # partition overwrite), so bookmarks would add hidden state that makes
    # reprocessing a month harder rather than easier.
    "--job-bookmark-option" = "job-bookmark-disable"

    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "false" # writes event logs to S3; not needed
    "--TempDir"                          = "s3://${each.value.staged_bucket}/_glue-temp/"
  }

  execution_property {
    # One run at a time. Two concurrent runs on the same month would both
    # dynamic-overwrite the same partition, and the loser's rows vanish.
    max_concurrent_runs = 1
  }

  tags = {
    Environment = each.key
    Component   = "ingestion"
  }
}

# --- Outputs -------------------------------------------------------------

output "glue_job_names" {
  description = "Glue job names, for triggering runs from the CLI or Lambda"
  value       = { for k, v in aws_glue_job.json_to_parquet : k => v.name }
}
