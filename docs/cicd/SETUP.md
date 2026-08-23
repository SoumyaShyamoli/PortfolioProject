# CI/CD setup

Order matters: state bucket, then backend migration, then workflows.

## 1. Create the state bucket by hand

The state bucket is the one resource that cannot manage itself — Terraform
needs somewhere to put state before it can create anything. Chicken-and-egg
is normal here and expected.

```bash
export AWS_PROFILE=retail-dev
BUCKET=sd-retail-tfstate-009073574996-eu-west-2-an

aws s3api create-bucket --bucket $BUCKET \
  --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2

# Versioning is NOT optional here. State corruption is recoverable only if
# previous versions exist.
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

This bucket is deliberately left OUT of Terraform. Managing your own state
backend creates a dependency loop and makes `terraform destroy` capable of
deleting the state it is currently using.

## 2. Migrate state

Uncomment the `backend "s3"` block in `providers.tf`, then:

```bash
cd infra/terraform
terraform init -migrate-state
```

Terraform will ask whether to copy the existing local state to S3. Say yes.

```bash
terraform plan     # must still say "No changes"
```

That is the proof the migration worked. Then remove the local state files —
they are now stale copies, and leaving them around invites confusion:

```bash
rm terraform.tfstate terraform.tfstate.backup
```

`use_lockfile = true` gives native S3 locking. Older guides tell you to
create a DynamoDB table for this; that has not been necessary since
Terraform 1.10.

## 3. Add the state bucket to the CI/CD role policies

Both deploy roles need read and write on the state object, and on the lock
file beside it. Already included in the updated `iam.tf`.

## 4. The permissions tension

**Worth understanding before you wire this up.** A CI role that runs
`terraform apply` across the whole platform needs permission to manage every
resource type in it — S3, IAM, VPC, Glue, Lambda. That is close to
administrative, which sits awkwardly next to a project whose stated principle
is least privilege.

There is no clean way around it. The options are:

1. **Narrow CI, broad human.** CI deploys application artifacts (the Glue
   script, the Lambda zip) and runs `terraform plan` read-only on PRs;
   `terraform apply` for infrastructure changes is run by a human locally.
   This is a real pattern in regulated environments, and it keeps the CI role
   genuinely least-privilege.

2. **Broad CI.** The deploy role gets what it needs to apply. Standard in
   most teams, justified by the branch-scoped trust policy and the fact that
   the code being applied is reviewed.

**This setup uses option 1**, because it is the more defensible position for
a platform that makes least privilege a stated principle — and because being
able to explain *why* CI cannot apply infrastructure is a better interview
answer than having given it admin without noticing the tension.

The PR workflow uses `ReadOnlyAccess` plus state bucket access, which is
enough to produce a plan. The merge workflow deploys artifacts only.

If you would rather have full CI apply, attach `PowerUserAccess` plus
`IAMFullAccess` to the deploy roles and swap the merge workflow to run
`terraform apply`. Document whichever you choose.
