# ADR 0011 — Terraform for the Snowflake storage integration, DDL by hand

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

Snowflake needs to read Parquet from the staged S3 buckets. That is done with
a storage integration: a Snowflake object that assumes an AWS IAM role.

The setup has a circular dependency. Snowflake generates an IAM user ARN and
an external ID when the integration is created, and those values must go into
the AWS role's trust policy. But the integration itself needs the role ARN.
So by hand the procedure is:

1. Create the IAM role with a placeholder trust policy
2. Create the integration in Snowflake referencing that role
3. `DESC INTEGRATION` to read the generated ARN and external ID
4. Go back and update the trust policy with the real values

Four steps, two systems, and step 4 is easy to get subtly wrong or skip.

Separately, there is a broader question: should Snowflake objects generally —
warehouses, databases, schemas, roles — be managed in Terraform at all?

## Decision

**Terraform for the storage integration and its IAM role.** Both sides of the
trust in one configuration.

**DDL by hand for warehouses, databases, schemas and roles.** Run once in a
worksheet, recorded in `snowflake/setup/` as `.sql` files so it is
reproducible.

## Rationale

**The circular dependency is exactly what Terraform is good at.** The role
ARN is predictable — I know the name I am giving it — so the integration can
reference a constructed ARN string while the role's trust policy references
the integration's computed outputs. Terraform works out the ordering. The
four-step manual dance becomes one apply.

More importantly it makes the bidirectional trust visible in one file. Split
across a worksheet and the AWS console, the relationship exists only in
whoever set it up.

**DDL is one-off and Terraform adds little.** A warehouse is created once and
changed rarely. Expressing `CREATE WAREHOUSE` in HCL is a translation
exercise, not a management improvement, and the Snowflake provider had a
breaking v2 rewrite so most examples online no longer apply. Learning that
against a 30-day trial clock is time spent on the wrong thing.

Committing the SQL gives most of the benefit — reproducible, reviewable, in
version control — without the provider learning curve.

**Blast radius.** Snowflake resources would join a state file that already
covers both AWS environments. Keeping DDL out of it limits what one bad apply
can touch.

## Consequences

**The split needs explaining.** "Some infrastructure is in Terraform and some
is not" looks inconsistent unless the line is drawn deliberately. The line
here is: anything spanning AWS and Snowflake goes in Terraform, because that
is where the coordination problem is. Anything living purely inside Snowflake
is DDL.

**Snowflake DDL is not drift-detected.** Change a warehouse size in the UI and
nothing notices. Accepted — the committed SQL is documentation of intent, not
enforcement.

**The Snowflake Terraform provider still gets used**, for the integration, so
the provider version and auth still have to be configured. The learning curve
is reduced, not avoided.

**Two credentials at apply time.** Terraform needs AWS credentials and
Snowflake credentials in the same run. Snowflake auth uses the key-pair
described in ADR 0010.

## Alternatives considered

**Everything in Terraform, including DDL.** The purist answer, and correct on
a platform where Snowflake objects change often or where multiple people
create them. Rejected on the learning-curve and blast-radius points above,
under time pressure I would not accept on a real platform.

**Everything by hand, including the integration.** Fewer moving parts. Rejected
because the four-step trust dance is precisely the kind of thing that gets
half-done and then produces an opaque permissions error weeks later.

**A separate Terraform state for Snowflake.** Would isolate blast radius while
keeping everything in code. Genuinely reasonable, and the better answer if
Snowflake config grows. Rejected for now because the integration spans both
systems, so splitting state would reintroduce the coordination problem in a
different form.

## Follow-ups

- If Snowflake config grows beyond the integration — resource monitors,
  network policies, more roles — revisit and consider a separate state.
- Record the DDL in `snowflake/setup/` with a README explaining run order.



## Amendment — 2026-08-24: reversed. The integration is hand-run DDL too.

The original decision was to manage the storage integration in Terraform
while leaving other Snowflake objects as hand-run SQL. The reasoning was
sound — the integration's bidirectional trust is genuinely circular, and
Terraform resolves that in one apply where by hand it takes four steps.

**I reversed it after attempting the implementation.**

What the attempt actually cost:

- The provider had a v2 rewrite, so most examples online no longer apply
- `SNOWFLAKE_ACCOUNT` was dropped in favour of separate organization and
  account variables
- Authentication silently defaults to password; key-pair needs
  `SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT` set explicitly, and the failure
  mode is `password is empty` rather than anything pointing at the cause
- `CURRENT_ACCOUNT()` returns the account *locator*, which is not the
  account *name* the connection string wants — two different identifiers
  for the same thing, and the wrong one produces a 404
- `snowflake_storage_integration` is deprecated in favour of
  `snowflake_storage_integration_aws`
- Which is itself gated behind `preview_features_enabled`

The last point is what decided it. A preview resource may change shape
between provider versions. Building the trust relationship on something
explicitly marked unstable, during a 30-day trial window, to save a
fifteen-minute manual procedure, is the wrong trade.

**The revised split:**

- **Snowflake side** — `snowflake/setup/04_storage_integration.sql`, run by
  hand as ACCOUNTADMIN, committed for review
- **AWS side** — the IAM roles and policies stay in Terraform, taking
  Snowflake's generated `STORAGE_AWS_IAM_USER_ARN` and
  `STORAGE_AWS_EXTERNAL_ID` as input variables

So the line drawn in the original ADR still holds, just in a different
place: **everything inside Snowflake is DDL, everything in AWS is
Terraform.** Simpler to state than the original split, and it removes the
Snowflake provider from the configuration entirely.

**What is lost.** The four-step procedure is back, and step three — putting
the generated values into `terraform.tfvars` — is the one that gets skipped.
Mitigated by the ordering comments in the SQL file and by PART C, a
verification step that fails loudly if the trust is not actually working.

**What is gained.** No Snowflake provider, no preview features, no second
auth mechanism in the Terraform run. The AWS side, which is where the
security-relevant configuration lives, remains fully coded and reviewable.

**The general lesson**, worth keeping: "manage everything in Terraform" is a
default, not a rule. When a provider is immature for a specific resource,
committed SQL with a documented procedure is a legitimate answer — provided
the procedure includes a verification step, because an unverified manual
process is where this genuinely would be worse than IaC.



---

## Amendment (2026-08-28)

This ADR's own follow-up asked to be revisited if Snowflake-side
configuration grew beyond the original storage integration. It has grown
substantially since: a resource monitor, the `RETAIL_READER` role, the
full marts layer, and World Bank raw tables in both dev and prod — all
added as hand-run DDL under `snowflake/setup/`, none of it in Terraform
state.

**Revisited, and the answer is: no change needed.** The DDL-not-Terraform
split has held up cleanly under that growth, for the same reason it was
chosen originally — nothing added since has been the kind of resource
Terraform's Snowflake provider handled poorly (storage integrations,
specifically). Roles, warehouses, tables, and the resource monitor are
all plain SQL, version-controlled, numbered, and run in a documented
order — the pattern scales by adding another numbered file, not by
adding complexity to how it's managed.

**What's actually grown is the number of files, not the need for a
different state strategy.** `snowflake/setup/` now runs `01` through
`06` (plus a `06_worldbank_prod.sql` variant) and a `07_resource_monitor.sql`.
The follow-up this closes out was asking "does this need Terraform or a
separate state file" — the honest answer, confirmed by six months of
files added without friction, is that it doesn't need either. A README
explaining run order remains the right amount of process for this, and
is the one piece from the original follow-ups still owed (see
`docs/next-session-priorities.md`).

**One thing worth watching, not yet a problem:** every file assumes the
correct role/warehouse context is set manually before running (`USE
ROLE`, `USE WAREHOUSE`, `USE DATABASE` at the top of each script). This
has worked because there is one operator running these by hand,
carefully, in order. It would not scale to a team running these
concurrently or out of order — worth naming as an explicit boundary of
this pattern's suitability, the same honest framing ADR 0013 uses for
other solo-project-appropriate gaps.