# Incident 001 — Terraform state loss during backend migration

- **Date:** 2026-08-23
- **Duration:** ~1 hour from first error to full recovery
- **Severity:** Low — no data loss, no cost impact, no production dependency
- **Author:** Platform owner

---

## Summary

While migrating Terraform state from a local file to an S3 backend, the
backend was initialised with `terraform init` instead of
`terraform init -migrate-state`. This created an **empty** remote state
rather than migrating the existing one.

The next `terraform apply` therefore saw configuration describing ~48
resources and a state file describing none, and attempted to create all of
them. Resources with globally unique names were rejected by AWS. Resources
without a uniqueness constraint were created — producing ten duplicate
network resources alongside the originals.

All duplicates were destroyed and state was rebuilt by re-importing every
resource. No data was lost and no cost was incurred.

---

## Impact

**What broke:** Terraform's record of the infrastructure. The infrastructure
itself was untouched — the Glue job continued to work throughout, pointing at
the real buckets.

**What was created in error:** ten resources, all free.

| Resource | Duplicate ID | Original ID |
|---|---|---|
| VPC | `vpc-0c9e506897af14f9b` | `vpc-07ea06521ec2bc50b` |
| Subnet (private1) | `subnet-074200529a10781cf` | `subnet-07735066c27bfeb8d` |
| Subnet (private2) | `subnet-016787d54730423ac` | `subnet-05b550e3b3323162d` |
| Route table (private1) | `rtb-083a31392b46ee86b` | `rtb-08886e03d03888075` |
| Route table (private2) | `rtb-0d276e0d945648965` | `rtb-0c376bff5a28f1e83` |
| Security group | `sg-09d8e9193950e84ff` | `sg-08e15fc43664b6ddb` |
| S3 gateway endpoint | `vpce-075fbb27474e149b1` | `vpce-05ec6e403b5e035db` |
| 2 route table associations | — | — |

**Cost impact:** zero. VPCs, subnets, route tables, security groups and
gateway endpoints carry no charge. Had the platform used a NAT gateway, an
interface endpoint, or any EC2-backed resource, the duplication would have
started billing immediately and silently.

**Data impact:** none. No S3 bucket, IAM role or Glue job was modified —
those all failed with 409 Conflict, which in this case acted as an
unintentional safety net.

---

## Timeline

| Step | What happened |
|---|---|
| 1 | State bucket created. First attempt failed with `MissingNamespaceHeader` — the `-an` suffix marks an account-regional namespace bucket, which requires `--bucket-namespace account-regional`. Fixed and created. |
| 2 | `backend "s3"` block uncommented in `providers.tf`. |
| 3 | **`terraform init` run instead of `terraform init -migrate-state`.** Terraform initialised an empty remote state. No warning that an existing local state was being abandoned. |
| 4 | `terraform apply` run. Terraform saw ~48 resources in config and 0 in state, and planned to create everything. |
| 5 | Apply partially failed: 409 `EntityAlreadyExists` on IAM roles and the OIDC provider, 400 `MissingNamespaceHeader` on all six S3 buckets, `AlreadyExistsException` on the Glue connection. Ten VPC-family resources were created successfully. Two EventBridge rules were silently overwritten in place (`PutRule` is an upsert). |
| 6 | Diagnosis: `terraform state list` returned 12 resources instead of ~48. |
| 7 | `list-object-versions` on the state bucket returned nothing under `platform/`, confirming the remote state had never been populated from the local one. |
| 8 | Local `terraform.tfstate` contained only the 8 newly-created resources. `terraform.tfstate.backup` had been deleted after the migration, on the assumption the migration had worked. |
| 9 | Resource IDs in state compared against known originals — confirmed every one was a duplicate. |
| 10 | The two EventBridge rules removed from state with `terraform state rm`, so the destroy could not delete them (they were originals, not duplicates). |
| 11 | `terraform destroy` run against the remaining ten. Verified the plan contained no original IDs before applying. |
| 12 | A complete import file regenerated covering all resources. `terraform plan` showed 62 to import, 1 to add, 0 to destroy. |
| 13 | Applied. State rebuilt. |

---

## Root cause

`terraform init` and `terraform init -migrate-state` differ by one flag and
produce radically different outcomes when a backend block is added to a
configuration that already has local state.

Terraform does prompt for confirmation when it detects state that could be
migrated — but the prompt is easy to accept or dismiss without reading, and
there is no post-hoc warning that a previously-populated state is now empty.

### Contributing factors

**1. The backup was deleted before the migration was verified.** The setup
instructions said to remove `terraform.tfstate` and
`terraform.tfstate.backup` after migrating. That step was correct in
principle and badly ordered in practice — it should have come after
`terraform state list` confirmed the remote state was populated. Removing the
backup turned a two-minute recovery into an hour-long rebuild.

**2. No verification step between `init` and `apply`.** Running
`terraform state list` immediately after `init` would have shown an empty
state and caught this before any AWS API call was made.

**3. The plan output was not read carefully.** A plan proposing to *create*
48 resources that were known to already exist is an unmistakable signal. It
was treated as routine.

**4. AWS resource naming semantics are inconsistent.** S3 buckets, IAM roles,
Glue connections and OIDC providers have uniqueness constraints and rejected
the duplicate creates. VPCs, subnets, route tables and security groups have
no such constraint — names are tags, not identifiers — so duplication
succeeded silently. This asymmetry is why the damage was partial rather than
total, and it is not obvious in advance which resources fall into which
category.

---

## What went well

- **Zero-cost blast radius.** Every duplicated resource was free. This was
  luck rather than design, but it was luck created by earlier decisions — the
  architecture deliberately avoids NAT gateways, interface endpoints and EC2
  instances, so there was nothing expensive available to duplicate.

- **409 errors as an accidental safety net.** Globally unique names prevented
  the duplication of everything that actually holds data or grants
  permissions.

- **Fast, confident diagnosis.** `terraform state list` returning 12 instead
  of 48 immediately localised the problem to state rather than
  infrastructure.

- **Correct handling of the EventBridge rules.** Recognising that `PutRule`
  is an upsert — and therefore that those two resources were originals rather
  than duplicates — prevented `terraform destroy` from deleting real
  infrastructure. This was the single most dangerous moment in the recovery.

- **Import blocks were recoverable.** Because every import ID was
  reconstructible from AWS and from git history, rebuilding state was
  mechanical rather than investigative.

---

## What went badly

- **A destructive step was taken on an unverified assumption.** Deleting the
  local state files assumed the migration had succeeded, without checking.

- **The failure was silent at the point it occurred.** Nothing failed during
  `init`. The consequence surfaced one command later, in a form that looked
  like a permissions or naming problem rather than a state problem.

- **Recovery involved a `terraform destroy`,** which is inherently risky. It
  was safe only because the resource IDs had been verified individually
  first.

---

## Corrective actions

| Action | Status |
|---|---|
| Verify `terraform state list` after any `init` that changes the backend, before any plan or apply | Adopted |
| Never delete local state or backup files until remote state is confirmed populated | Adopted |
| Keep an out-of-band copy (`terraform.tfstate.safety`, gitignored) during migration | Adopted |
| Treat a plan proposing to create known-existing resources as a stop condition, not a routine diff | Adopted |
| Enable versioning on the state bucket before first use | Already in place — did not help here, since the bucket was never written to, but would have made recovery trivial in the more common corruption case |
| Document the migration as a runbook rather than a set of instructions | Done — `docs/runbooks/terraform-state-migration.md` |
| Add a CI check that fails when a plan contains destroy or replace operations | Done — implemented in the PR checks workflow |

---

## Lessons

**State is the most fragile part of a Terraform setup, and the least
protected.** The infrastructure survived intact throughout; it was the record
of it that broke. Backups of state deserve the same care as backups of data,
and for the same reason — losing the map is nearly as bad as losing the
territory.

**Verify after every step that changes where state lives.** The cost of
`terraform state list` is a second. The cost of skipping it was an hour.

**Read the plan.** Every piece of information needed to catch this was in the
plan output before anything was applied.

**Know which resources have uniqueness constraints.** It determines whether a
mistake fails loudly or succeeds silently. Loud failure is the better
outcome, and it is not something you get to choose.

**A near-miss with no cost is the cheapest lesson available.** The same
mistake on a platform with NAT gateways, RDS instances or interface endpoints
would have duplicated billable infrastructure and possibly gone unnoticed
until the invoice arrived.
