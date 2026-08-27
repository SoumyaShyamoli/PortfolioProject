# Two small changes to airflow.tf for the wheelhouse fix

## 1. Pass the staged bucket name into the template

Find the `user_data = templatefile(...)` block and add one line:

```hcl
  user_data = templatefile("${path.module}/../../scripts/airflow_bootstrap.sh.tpl", {
    environment      = each.key
    aws_region       = var.region
    s3_staged_bucket = local.buckets["${each.key}-staged"].name   # ADD THIS LINE
  })
```

## 2. Grant read on the wheelhouse prefix

In `aws_iam_role_policy.airflow`, add a statement alongside the existing
`ListOwnBuckets` one:

```hcl
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
```

Note this reuses the S3 gateway endpoint you already have (ADR 0003) — it
is free and already routes traffic to this bucket, so no new networking is
needed for the fix itself. Only the wheelhouse contents and this IAM grant
are new.

## Apply order

1. `terraform plan -out=tfplan` / `apply` — adds the IAM statement, updates
   the template variable (this alone does NOT relaunch the instances; a
   `templatefile()` change alone does not force replacement unless you also
   `-replace` them, same as before)
2. Run `scripts/build_wheelhouse.sh dev prod` from your laptop — uploads the
   packages the now-updated bootstrap script expects to find
3. `terraform plan -replace='aws_instance.airflow["dev"]' -replace='aws_instance.airflow["prod"]' -out=tfplan`
4. Remember to flip `prevent_destroy` off before this apply and back on
   after, same as last time
5. `terraform apply tfplan`

Step 2 must happen before step 5 — an instance bootstrapping against an
empty `_wheelhouse/` prefix fails cleanly (no packages found) rather than
falling back to PyPI, which is the point of `--no-index`, but it does mean
ordering matters here.
