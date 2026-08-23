# Runbook — Migrating Terraform state to an S3 backend

Written after incident 001, where this procedure went wrong. Every
verification step below exists because its absence caused a real problem.

**Read the whole runbook before starting.**

---

## Preconditions

- `terraform plan` currently reports **No changes**. Do not migrate state
  that does not match reality — you will not be able to tell afterwards
  whether a diff came from the migration or was already there.
- You have the AWS profile that can write to the state bucket.
- Nobody else is applying against this configuration.

---

## Step 1 — Create the state bucket by hand

The state bucket cannot be managed by the Terraform whose state it holds.
That dependency loop would make `terraform destroy` capable of deleting the
state it is currently using.

```bash
export AWS_PROFILE=retail-dev
BUCKET=sd-retail-tfstate-009073574996-eu-west-2-an

aws s3api create-bucket --bucket $BUCKET \
  --bucket-namespace account-regional \
  --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2
```

`--bucket-namespace account-regional` is required for any bucket name ending
`-ACCOUNTID-REGION-an`. Without it S3 returns `MissingNamespaceHeader`.

```bash
# Versioning is NOT optional. It is the only recovery path for a corrupted
# or truncated state file.
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### Verify

```bash
aws s3api get-bucket-versioning --bucket $BUCKET
```
Must return `"Status": "Enabled"`. Do not continue otherwise.

---

## Step 2 — Take a safety copy

```bash
cd infra/terraform
cp terraform.tfstate ~/terraform.tfstate.safety
grep -c '"mode"' ~/terraform.tfstate.safety
```

Note that count — it is how many resources you should see after migrating.

Outside the repo deliberately, so it cannot be committed and cannot be
removed by a `git clean`.

---

## Step 3 — Add the backend block

In `providers.tf`:

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

`use_lockfile` gives native S3 locking. Older guides require a DynamoDB
table; that has not been necessary since Terraform 1.10.

---

## Step 4 — Migrate

```bash
terraform init -migrate-state
```

**The `-migrate-state` flag is the entire point of this runbook.**

Plain `terraform init` will initialise an **empty** remote state and abandon
your local one. Nothing fails at that moment. The consequence appears on the
next apply, when Terraform tries to create every resource in your
configuration.

Terraform will prompt:

```
Do you want to copy existing state to the new backend?
```

Answer `yes`. Read the prompt rather than reflexively accepting it.

---

## Step 5 — Verify before anything else

**Do not run `plan` or `apply` until all three of these pass.**

```bash
terraform state list | wc -l
```
Must match the count from Step 2. If it is 0 or small, the migration did not
happen — go to Recovery below.

```bash
aws s3api list-object-versions --bucket $BUCKET --prefix platform/ \
  --query "Versions[].{Key:Key,Size:Size,Modified:LastModified}" --output table
```
Must show a state object of non-trivial size. An empty result means nothing
was written.

```bash
terraform plan
```
Must report **No changes**. A plan proposing to *create* resources you know
exist is the signature of an empty state. **Stop immediately** — do not
apply.

---

## Step 6 — Clean up (only after Step 5 passes)

```bash
rm terraform.tfstate terraform.tfstate.backup
```

Keep `~/terraform.tfstate.safety` for at least a few days and a few
successful applies. Deleting it early is what turned a two-minute recovery
into an hour-long rebuild during incident 001.

---

## Recovery — state is empty after migration

### If you have not run `apply`

You are fine. Restore and retry:

```bash
cp ~/terraform.tfstate.safety terraform.tfstate
terraform state push -force terraform.tfstate
terraform state list        # verify the count
terraform plan              # verify No changes
```

### If you have run `apply`

Some resources may have been duplicated. Only those **without** name
uniqueness constraints — VPCs, subnets, route tables, security groups,
endpoints. S3 buckets, IAM roles, Glue connections and OIDC providers will
have failed with 409, unharmed.

**1. Identify what is in state and whether it is original or duplicate.**

```bash
terraform state list
terraform state show aws_vpc.main | grep -E "^\s+id\s+="
```

Compare every ID against the known originals. Record them.

**2. Watch for upsert-semantics resources.** EventBridge `PutRule`, and
anything else where creation overwrites rather than conflicts, will be your
**original** resource now sitting in state. Remove it before destroying, or
the destroy will delete real infrastructure:

```bash
terraform state rm 'aws_cloudwatch_event_rule.example["dev"]'
```

**3. Destroy the duplicates.**

```bash
terraform plan -destroy -out=destroyplan
terraform show destroyplan | grep -E "will be destroyed|^\s+id"
```

Verify every ID is a duplicate before applying. If any original appears,
stop.

```bash
terraform apply destroyplan
```

**4. Rebuild state by importing.** Write an import block for every resource.
Import IDs that are easy to get wrong:

| Resource | ID format |
|---|---|
| `aws_iam_role_policy` | `role-name:policy-name` |
| `aws_iam_role_policy_attachment` | `role-name/policy-arn` |
| `aws_glue_connection` | `account-id:connection-name` |
| `aws_s3_object` | `bucket/key` |
| `aws_cloudwatch_event_target` | `rule-name/target-id` |
| `aws_lambda_permission` | `function-name/statement-id` |
| `aws_route_table_association` | `subnet-id/rtb-id` |

```bash
terraform plan -out=tfplan       # verify 0 to destroy
terraform apply tfplan
terraform plan                   # must say No changes
rm imports.tf                    # only now
```

---

## Rules

1. `terraform init -migrate-state`, never bare `init`, when adding a backend.
2. `terraform state list` after every `init` that changes the backend.
3. Never delete a state backup until remote state is verified populated.
4. A plan that creates known-existing resources is a stop condition.
5. Import blocks stay in place until after `apply`, not after `plan`.
