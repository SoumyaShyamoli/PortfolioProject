# S3 storage layers.
#
# Note: since AWS provider v4, a bucket's versioning, encryption, lifecycle and
# public access settings are each a SEPARATE resource rather than inline blocks.
# That is why six buckets become ~20+ resources.

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value.name

  tags = {
    Environment = each.value.env
    Layer       = each.value.layer
    # Raw holds unmasked customer_id from the source extract.
    DataClass = each.value.layer == "raw" ? "pii-restricted" : "internal"
  }
}

# Managed on prod-raw and prod-staged only. The other four buckets are
# deliberately left unmanaged for versioning — see locals in variables.tf.
resource "aws_s3_bucket_versioning" "this" {
  for_each = local.versioned_buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption and public access blocking apply to all six. These are AWS
# defaults on new buckets, so all six already have a config to adopt.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3. KMS would add per-request cost.
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle on prod-raw only.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.lifecycle_buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "raw-to-standard-ia"
    status = "Enabled"

    # An empty filter means "all objects". Required in provider v5 — omitting
    # it entirely will fail validation.
    filter {}

    transition {
      days          = var.raw_ia_transition_days
      storage_class = "STANDARD_IA"
    }
  }

  # Versioning is on for this bucket, so superseded versions would otherwise
  # accumulate indefinitely. Note the retention implication: a version older
  # than this window is gone, which caps how far back a backfill can replay.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Glue writes shuffle and spill data to _glue-temp/ and does not clean up
# after itself. Seven days is well beyond any job's lifetime here (the job
# timeout is 15 minutes) while leaving room to inspect a failed run's
# artefacts.
resource "aws_s3_bucket_lifecycle_configuration" "staged_temp" {
  for_each = {
    for k, v in local.buckets : k => v if v.layer == "staged"
  }

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "expire-glue-temp"
    status = "Enabled"

    filter {
      prefix = "_glue-temp/"
    }

    expiration {
      days = 7
    }

    # Multipart uploads that failed mid-write leave parts behind that are
    # invisible in the console and still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}
