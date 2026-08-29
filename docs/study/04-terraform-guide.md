# Terraform — What We Built and Why

A ground-up explanation of every Terraform concept used in this platform,
written for someone new to the tool. Each section explains the concept, then
shows exactly where and why it appears in this codebase.

---

## 1. The mental model

Terraform holds three things, and almost every confusion comes from mixing
them up:

| | What it is | Where it lives |
|---|---|---|
| **Configuration** | What you *want* — the `.tf` files | Your repo |
| **State** | What Terraform *believes* exists | `terraform.tfstate` (local or S3) |
| **Reality** | What actually exists in AWS | AWS |

`terraform plan` compares all three and shows the difference.
`terraform apply` changes reality to match configuration, then updates state.

**The critical insight:** state is not a cache. It is the authoritative
record of which real resource corresponds to which config block. Lose it and
Terraform doesn't know your infrastructure exists — it will try to create
everything again. That is exactly what happened in incident 001.

---

## 2. Providers

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

A **provider** is the plugin that translates Terraform's resource model into
API calls. `hashicorp/aws` knows how to create an S3 bucket; Terraform itself
does not.

`~> 5.0` means "5.x, but not 6.0" — allows bug fixes, blocks breaking
changes.

`required_version = ">= 1.10"` was added after a real failure: we used
`use_lockfile` in the backend, which needs 1.10+, while CI was pinned to
1.9.8. Without the floor, that surfaced as a confusing "unsupported argument"
error rather than a clear version message.

### Provider configuration and credentials

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "retail-data-platform"
      ManagedBy = "terraform"
      Owner     = "data-platform"
    }
  }
}
```

**No `profile` argument** — deliberately, and this took two rounds to get
right.

Originally this was `profile = "retail-dev"`. That works on one laptop and
breaks everywhere else: the GitHub runner has no such profile, so Terraform
looked for credentials that didn't exist. The second attempt used a
conditional (`var.aws_profile != "" ? var.aws_profile : null`), which also
misbehaved.

The correct answer is to omit it entirely and let the **standard AWS
credential chain** resolve it:

- Locally: `export AWS_PROFILE=retail-dev`
- In CI: `configure-aws-credentials` places assumed-role credentials in the
  environment

Same configuration, both environments, no branching. **Interview point:**
hardcoding environment-specific values in provider config is a common
mistake that only shows up the first time something else runs your code.

`default_tags` applies tags to every resource the provider creates. That is
what makes cost allocation by tag possible later, without tagging each
resource by hand.

---

## 3. Resources, data sources, and locals

### Resource

```hcl
resource "aws_s3_bucket" "this" {
  bucket = "some-name"
}
```

Something Terraform creates and manages. `aws_s3_bucket` is the type, `this`
is the local name used to reference it (`aws_s3_bucket.this.id`).

### Data source

```hcl
data "archive_file" "worldbank" {
  type        = "zip"
  source_file = "${path.module}/../../ingestion/worldbank/fetch_worldbank.py"
  output_path = "${path.module}/.build/fetch_worldbank.zip"
}
```

Something Terraform **reads or computes** but does not own. This one zips the
Lambda source at plan time. Terraform will never delete it.

### Locals

```hcl
locals {
  environments = ["dev", "prod"]
  layers       = ["raw", "staged", "curated"]

  buckets = {
    for pair in setproduct(local.environments, local.layers) :
    "${pair[0]}-${pair[1]}" => {
      env   = pair[0]
      layer = pair[1]
      name  = "sd-retail-${pair[0]}-${pair[1]}-${var.account_id}-${var.region}-${var.name_suffix}"
    }
  }
}
```

Computed values, evaluated once and reused. `setproduct` gives the Cartesian
product of environments and layers — six buckets from two short lists, with
the naming convention expressed exactly once.

**Why this matters:** if the naming convention changes, you edit one line
rather than six resource blocks. And a typo in a hand-written bucket name
would be a silently different bucket rather than an error.

### Variables

```hcl
variable "region" {
  description = "AWS region for all platform resources"
  type        = string
  default     = "eu-west-2"
}
```

Inputs. Set by `-var`, a `.tfvars` file, or the `TF_VAR_<name>` environment
variable.

**`locals` vs `variables`:** variables are inputs that can change per
invocation; locals are derived values that shouldn't. Bucket names are locals
because they're computed from the naming convention, not supplied.

---

## 4. `for_each` — the pattern used throughout

```hcl
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value.name

  tags = {
    Environment = each.value.env
    Layer       = each.value.layer
    DataClass   = each.value.layer == "raw" ? "pii-restricted" : "internal"
  }
}
```

One block creates six buckets, addressed as
`aws_s3_bucket.this["dev-raw"]`, `aws_s3_bucket.this["prod-staged"]`, etc.

`each.key` is the map key; `each.value` is the map value.

### `for_each` vs `count`

`count` uses numeric indices, and **that is its problem**: removing the
middle element of a list shifts every subsequent index, so Terraform sees
those resources as changed and may destroy and recreate them.

`for_each` uses stable string keys. Remove `dev-curated` from the map and
only that one is destroyed; the others are untouched.

**Rule: use `for_each` unless you specifically need N identical copies.**

### Filtering a `for_each`

```hcl
versioned_bucket_keys = ["prod-raw", "prod-staged"]

versioned_buckets = {
  for k, v in local.buckets : k => v
  if contains(local.versioned_bucket_keys, k)
}
```

```hcl
resource "aws_s3_bucket_versioning" "this" {
  for_each = local.versioned_buckets
  ...
}
```

This is how versioning applies to only two of six buckets. Note the
consequence: the other four have **no versioning resource at all**, so
Terraform will neither create nor correct that setting on them. That is
accepted, documented drift — see ADR 0001.

---

## 5. Dependencies

### Implicit (preferred)

```hcl
resource "aws_iam_role_policy" "dev_pipeline_exec" {
  role = aws_iam_role.dev_pipeline_exec.id
  ...
}
```

Referencing `aws_iam_role.dev_pipeline_exec.id` tells Terraform the role must
exist first. It builds a dependency graph from these references and
parallelises everything unrelated.

**This is why the IAM policies reference `aws_iam_role.x.arn` rather than a
literal ARN string.** The first version of `iam.tf` had hardcoded ARNs —
correct output, but Terraform didn't know about the relationship, and the
ARNs could drift from reality.

### Explicit

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  ...
  depends_on = [aws_s3_bucket_versioning.this]
}
```

For dependencies Terraform can't infer. Here the lifecycle rule expires
non-current versions, which only makes sense once versioning is on — but
nothing in the configuration references the versioning resource, so it must
be stated.

Use sparingly. Implicit dependencies are self-documenting; `depends_on` is a
manual override.

---

## 6. The S3 resource model (a common trap)

In AWS provider v3 and earlier, a bucket was one resource with inline blocks.
Since v4, each concern is a **separate resource**:

```hcl
resource "aws_s3_bucket" "this"                                   { ... }
resource "aws_s3_bucket_versioning" "this"                        { ... }
resource "aws_s3_bucket_server_side_encryption_configuration" "this" { ... }
resource "aws_s3_bucket_public_access_block" "this"               { ... }
resource "aws_s3_bucket_lifecycle_configuration" "this"           { ... }
```

Six buckets became roughly twenty resources. Every one needed its own import
block during adoption.

**Any tutorial written before 2022 will be wrong about this**, and it's a
frequent source of confusion.

---

## 7. State

### What's in it

A JSON document mapping each config block to a real resource ID, plus a
cached copy of that resource's attributes.

**It can contain secrets in plaintext** — database passwords, generated keys,
anything a resource returns. This is why `*.tfstate` is gitignored and why
committing state to a public repo is a genuine security incident.

### Local vs remote

Local (`terraform.tfstate` on disk) works for one person. It fails as soon
as CI needs it, or a second machine, or two people run apply simultaneously.

```hcl
terraform {
  backend "s3" {
    bucket       = "sd-retail-tfstate-009073574996-eu-west-2-an"
    key          = "platform/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

**`use_lockfile = true`** is native S3 locking, available since Terraform
1.10. Older guides tell you to create a DynamoDB table for this — no longer
necessary, and one less resource to pay for.

**Locking matters** because two simultaneous applies would each read state,
make different changes, and the second write would clobber the first.

**The state bucket is deliberately NOT managed by Terraform.** Managing your
own backend creates a dependency loop, and `terraform destroy` would be able
to delete the state it is currently using. It's created by hand — the
chicken-and-egg is normal and expected.

### Migrating to a backend

```bash
terraform init -migrate-state
```

**The `-migrate-state` flag is not optional.** Plain `terraform init` after
adding a backend block initialises an *empty* remote state and abandons the
local one. Nothing fails at that moment; the consequence appears on the next
apply, when Terraform tries to create everything.

That happened here, and produced ten duplicate network resources. Full
account in `docs/incidents/2026-08-23-terraform-state-loss.md`.

**Always verify after:**

```bash
terraform state list | wc -l     # matches what you had before?
terraform plan                   # says "No changes"?
```

---

## 8. Import — adopting existing infrastructure

The infrastructure here was built by hand in the console first, then brought
under Terraform. This is the **brownfield** case, and it's what most real
teams face.

### Import blocks (Terraform 1.5+)

```hcl
import {
  to = aws_vpc.main
  id = "vpc-07ea06521ec2bc50b"
}
```

Declarative — lives in a `.tf` file, applied like anything else. This
replaced the older `terraform import` CLI command, which was imperative and
left no record.

### Config generation

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform reads the live resource and **writes the HCL for you**. Enormously
useful when adopting resources whose exact configuration you don't know — the
IAM policies here were generated this way.

Two caveats learned the hard way:

1. **Doesn't work with `for_each` in import blocks.** That's why the S3
   imports used `for_each` (config was hand-written) while the IAM imports
   were explicit blocks (config was generated).

2. **Generated config isn't always valid.** The OIDC provider's URL came back
   without its `https://` scheme, which the provider's own validator then
   rejected. Generated config reflects the API response, not necessarily
   valid HCL.

### The rule that cost an hour

**Import blocks must be present for both `plan` AND `apply`.** They're
consumed at apply time. Deleting them after a successful plan makes Terraform
see config with no state and try to create everything — failing with
`EntityAlreadyExists`.

Remove them only once `terraform plan` reports "No changes" against the
post-apply state.

### Import ID formats

Not uniform, and easy to get wrong:

| Resource | ID format |
|---|---|
| `aws_s3_bucket` and sub-resources | bucket name |
| `aws_iam_role` | role name |
| `aws_iam_role_policy` | `role-name:policy-name` |
| `aws_iam_role_policy_attachment` | `role-name/policy-arn` |
| `aws_iam_openid_connect_provider` | full ARN |
| `aws_glue_connection` | `account-id:connection-name` |
| `aws_s3_object` | `bucket/key` |
| `aws_cloudwatch_event_target` | `rule-name/target-id` |
| `aws_lambda_permission` | `function-name/statement-id` |
| `aws_route_table_association` | `subnet-id/rtb-id` |

---

## 9. Reading a plan

```
Plan: 20 to import, 1 to add, 6 to change, 0 to destroy.
```

| Term | Meaning |
|---|---|
| **import** | Adopting into state. No API change to the resource. |
| **add** | Will be created. |
| **change** | Modified in place. |
| **destroy** | Deleted. **This number must be zero unless you intend otherwise.** |
| **replace** | Destroy then create. Happens when an immutable field changes. |

### Plan then apply the saved file

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

`apply tfplan` executes exactly what you reviewed — no re-planning, no drift
between looking and acting, no confirmation prompt.

Running bare `terraform apply` re-plans against current state, which may
differ from what you just read.

### What forces replacement

Immutable fields. Examples hit in this project:

- **IAM role `name`** — renaming means destroy and recreate, which is why the
  asymmetric role names (`retail-cicd-deploy-role` vs
  `retail-dev-cicd-deploy-role`) were left alone rather than tidied.
- **Security group `description`** — an unremarkable-looking field that
  forces replacement, and replacing an SG breaks its ENI attachments.
- **S3 bucket `bucket`** — the name.

Always check *why* something is being replaced before applying.

---

## 10. Change detection for files

```hcl
resource "aws_s3_object" "glue_script" {
  bucket      = each.value.staged_bucket
  key         = local.glue_script_key
  source      = "${path.module}/../../glue/jobs/json_to_parquet.py"
  source_hash = filemd5("${path.module}/../../glue/jobs/json_to_parquet.py")
}
```

```hcl
resource "aws_lambda_function" "worldbank" {
  filename         = data.archive_file.worldbank.output_path
  source_code_hash = data.archive_file.worldbank.output_base64sha256
}
```

Without `source_hash` / `source_code_hash`, Terraform compares only the
filename — which never changes — and the deployed artifact silently drifts
from the committed source.

With them, editing the script produces a plan diff and a redeploy. You saw
this in action: the ruff newline fix showed up as four resources needing
update.

---

## 11. Cost-safety patterns worth copying

```hcl
resource "aws_glue_job" "json_to_parquet" {
  timeout     = 15   # default is 2880 minutes = 48 HOURS
  max_retries = 0
  execution_property {
    max_concurrent_runs = 1
  }
}
```

- **`timeout`** — the single most important line for cost safety. A hung job
  at the default would exceed the entire project budget.
- **`max_concurrent_runs = 1`** — not just cost. Two runs writing the same
  partition would each overwrite the other; the concurrency limit is what
  makes the idempotency guarantee hold.

```hcl
resource "aws_cloudwatch_log_group" "worldbank" {
  name              = "/aws/lambda/${aws_lambda_function.worldbank[each.key].function_name}"
  retention_in_days = 14
}
```

Lambda creates its log group implicitly with **never expire** retention.
Declaring it explicitly caps that. Small, but it's the kind of cost that is
invisible until it isn't.

---

## 12. Command reference

```bash
terraform init                    # download providers, configure backend
terraform init -migrate-state     # AND migrate existing state to a new backend
terraform init -upgrade           # re-resolve provider versions

terraform validate                # syntax and internal consistency
terraform fmt -recursive          # canonical formatting
terraform fmt -check -recursive   # fail if unformatted (used in CI)

terraform plan                    # what would change
terraform plan -out=tfplan        # save the plan
terraform plan -destroy           # what a destroy would remove
terraform apply tfplan            # apply exactly the saved plan

terraform state list              # everything under management
terraform state show <address>    # one resource's attributes
terraform state rm <address>      # stop managing it (does NOT delete from AWS)
terraform state push <file>       # overwrite remote state — dangerous

terraform show tfplan             # human-readable saved plan
terraform output                  # values from output blocks
```

**`terraform state rm` is the safety valve.** It removes a resource from
state without touching AWS. Used during incident recovery to protect the
EventBridge rules from a `terraform destroy` — they were originals rather
than duplicates, because `PutRule` is an upsert rather than a create.
