# ADR 0001 — Adopt console-created infrastructure into Terraform rather than rebuild

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

The first tranche of infrastructure for this platform — six S3 buckets across
two environments and three layers, five IAM roles, a GitHub OIDC identity
provider, a VPC with two private subnets, a security group and an S3 gateway
endpoint — was created by hand through the AWS console. That was a deliberate
trade at the time: the goal was to understand what each resource actually does
before expressing it as code.

That left the platform in a state most real teams recognise: working
infrastructure with no source of truth. Nothing was reviewable, nothing was
reproducible, and the only record of why a setting was chosen was in the
person who clicked it.

Bringing it under IaC left two options.

## Decision

Adopt the existing resources into Terraform state using `import` blocks,
rather than destroying and recreating them from new Terraform configuration.

Configuration for the IAM resources was generated from the live account with
`terraform plan -generate-config-out`, so the committed HCL reflects what AWS
actually holds rather than a reconstruction from memory. S3 configuration was
written by hand, because the bucket set is regular enough to express with
`for_each` and generated config would have been six near-identical blocks.

## Rationale

**Adoption preserves the audit trail.** Recreating would have produced
identical-looking resources with new creation timestamps and, for the OIDC
provider, would have briefly broken CI/CD trust. The buckets are empty today,
but the habit of destroy-and-recreate does not survive contact with a bucket
that holds data.

**Import surfaces drift, recreation hides it.** See consequences below.

**Brownfield adoption is the common case.** Greenfield IaC is the tutorial
scenario. Most teams inherit click-ops and have to bring it under management
without downtime, so practising the harder path is the more useful exercise.

## Consequences

### Configuration drift was surfaced, then made explicit

The import revealed that versioning had been enabled on `prod-raw` and
`prod-staged` but not on the other four buckets, and that a lifecycle rule
believed to exist on `prod-raw` had never actually saved — the import failed
with "Cannot import non-existent remote object". Neither would have been
noticed without this exercise; both are exactly the kind of gap that only
shows up during an incident.

The drift was resolved deliberately rather than silently normalised:
versioning is now scoped to the two buckets that had it, declared through an
explicit `versioned_bucket_keys` list, and the missing lifecycle rule is now
created by Terraform. The four unversioned buckets have no versioning resource
at all, which means Terraform will not correct them if someone enables
versioning by hand later. That is an accepted, documented gap rather than an
oversight — revisit it if the raw layer starts holding data that cannot be
regenerated.

### Import blocks must survive until after `apply`

A first attempt deleted `imports.tf` after a successful `plan` but before
`apply`. Terraform then saw configuration with no corresponding state and
tried to create everything, failing with `EntityAlreadyExists` on all five
roles and the OIDC provider. Nothing was created and nothing was left
half-applied, because IAM rejected each call outright.

The rule this establishes: import blocks are consumed at apply time, not plan
time. They are removed only once `terraform plan` reports no changes against
the post-apply state.

### Generated configuration needs review, not blind trust

`-generate-config-out` emitted the OIDC provider's URL without its scheme,
which the AWS provider's own validator then rejected. Generated config is a
starting point that reflects the API response, not necessarily valid HCL.

### Managed policy attachments are separate resources

`AWSGlueServiceRole` is attached to both pipeline execution roles. These
import as `aws_iam_role_policy_attachment` with the ID form
`role-name/policy-arn`, distinct from inline policies which use
`role-name:policy-name`. Worth noting that this AWS-managed policy is broader
than the inline policies alongside it; whether to keep it or rely on the
scoped inline policy alone is deferred until the Glue job runs successfully.

### The S3 resource model is not what older documentation suggests

Since AWS provider v4, versioning, encryption, lifecycle and public access
blocking are each separate resources rather than inline blocks on
`aws_s3_bucket`. Six buckets therefore became twenty resources, each needing
its own import block. Guides written before that change are actively
misleading here.

## Alternatives considered

**Destroy and recreate from new Terraform.** Fastest to a clean codebase, and
tempting while the buckets are empty. Rejected because it would have masked
the drift described above, and because it teaches a workflow that cannot be
used once the platform holds real data.

**Terraformer (bulk config generation).** Generates configuration for a whole
account in one pass. Rejected: it produces sprawling, unidiomatic HCL — one
flat resource block per object, no `for_each`, no variables — and cleaning
that up would have taken longer than writing the S3 configuration by hand.

**Leave it as console-managed and start Terraform only for new resources.**
Rejected. A platform split between click-ops and IaC has the drawbacks of
both, and the split tends to be permanent.

## Follow-ups

- VPC, subnets, security group and S3 gateway endpoint remain unmanaged and
  should be adopted the same way.
- Role naming is asymmetric: `retail-cicd-deploy-role` is the production role
  while its counterpart is `retail-dev-cicd-deploy-role`. Normalise in a
  separate change, since renaming an IAM role means destroy-and-recreate.
- Inline policy naming is inconsistent (some suffixed `Policy`, some not).
  Same treatment.
- State is currently local. Move to an S3 backend with `use_lockfile` before
  any second machine or CI runner touches it.