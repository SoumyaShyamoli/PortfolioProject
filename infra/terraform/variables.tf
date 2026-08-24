variable "region" {
  description = "AWS region for all platform resources"
  type        = string
  default     = "eu-west-2"
}



variable "account_id" {
  description = "AWS account ID — part of the globally-unique bucket names"
  type        = string
  default     = "009073574996"
}

variable "name_suffix" {
  description = "Short owner suffix used in bucket names"
  type        = string
  default     = "an"
}

variable "raw_ia_transition_days" {
  description = "Days before raw objects move to Standard-IA"
  type        = number
  default     = 30
}

variable "noncurrent_version_expiration_days" {
  description = "Days before superseded object versions are deleted"
  type        = number
  default     = 90
}

locals {
  environments = ["dev", "prod"]
  layers       = ["raw", "staged", "curated"]

  # Cartesian product -> six buckets, keyed "dev-raw", "prod-curated", etc.
  buckets = {
    for pair in setproduct(local.environments, local.layers) :
    "${pair[0]}-${pair[1]}" => {
      env   = pair[0]
      layer = pair[1]
      name  = "sd-retail-${pair[0]}-${pair[1]}-${var.account_id}-${var.region}-${var.name_suffix}"
    }
  }

  # --- Deliberate scoping -------------------------------------------------
  # Versioning and lifecycle are applied to a subset of buckets only, matching
  # what was configured by hand. Terraform manages ONLY these; the remaining
  # buckets have no versioning/lifecycle resource at all, so Terraform will
  # neither create nor correct that setting on them.
  #
  # Trade-off accepted: unmanaged buckets can drift (someone enables
  # versioning in the console and Terraform will not notice). Documented in
  # docs/adr/0004-s3-configuration-drift.md.

  versioned_bucket_keys = ["prod-raw", "prod-staged"]
  lifecycle_bucket_keys = ["prod-raw"]

  versioned_buckets = {
    for k, v in local.buckets : k => v
    if contains(local.versioned_bucket_keys, k)
  }

  lifecycle_buckets = {
    for k, v in local.buckets : k => v
    if contains(local.lifecycle_bucket_keys, k)
  }
}
