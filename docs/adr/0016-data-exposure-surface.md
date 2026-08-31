# ADR 0016 — Data exposure surface across the platform, not just the warehouse

- **Status:** Accepted
- **Date:** 2026-08-28

## Context

A masking-policy request for `customer_id` in Snowflake prompted a wider
question worth answering properly rather than narrowly: where else in
this platform could row-level customer data be exposed, beyond the
warehouse columns a masking policy directly controls? Masking one column
in one layer is easy to over-trust as "solved" if the same data is
sitting unmasked somewhere else entirely — a log, a cache, a state file.

This ADR treats data exposure as a property of the whole platform, layer
by layer, and records what was found, fixed, and knowingly left as-is.

## Decision

### Layer 1 — Snowflake marts (the original request)

`customer_id` is masked via a dynamic masking policy on
`dim_customer` and `fct_order_lines`, applied at the **mart** layer only
— not staging or raw, where `RETAIL_TRANSFORMER_{DEV,PROD}` legitimately
needs the real value for joins and RFM calculations.

**Hash, not null.** `RETAIL_READER` (Superset/dashboard use) needs to
`GROUP BY`/`COUNT DISTINCT` customer_id for cohort-style analysis without
seeing the real identifier — a deterministic hash preserves that; a
null-out would not. Separate salts per environment, so a dev-side hash
can never be matched against a prod-side hash even if both were somehow
exposed together.

See `snowflake/setup/08_masking_policy.sql`.

### Layer 2 — Snowflake grants (found while checking, not the original ask)

Auditing `RETAIL_READER`'s actual grants surfaced a real gap: the
original grant (`07_resource_monitor.sql`, written before marts existed)
used `ALL TABLES`/`FUTURE TABLES` on the `MARTS` schema — which, once
`fct_order_lines` was built, silently gave the dashboard role access to
**line-level transaction detail**, not just the intended rollups. This is
a bigger exposure than any single masked column: full row-level access
to who bought what, when, regardless of whether `customer_id` on those
rows is masked.

**Fixed:** narrowed to explicit grants on the rollup objects
(`fct_orders`, `fct_revenue_monthly`, the dimensions), with
`fct_order_lines` deliberately excluded. See
`snowflake/setup/09_reader_grant_audit.sql`.

**The lesson:** a broad `ALL TABLES`/`FUTURE TABLES` grant written before
a schema is fully built is a standing risk — it silently expands scope
every time a new table lands in that schema, without anyone re-approving
the expansion. Worth checking any other `FUTURE TABLES` grant in this
project for the same drift.

### Layer 3 — S3 / raw data

**No masking applied, deliberately.** Raw is immutable NDJSON/Parquet
(ADR 0005); masking at rest would mean transforming on write, which
breaks "raw reflects exactly what the source produced." Exposure here is
an access-control question, not a masking one, and is already narrowly
scoped — Glue's pipeline role, Snowflake's storage integration role, and
the human admin role are the only identities with read access to raw at
all.

### Layer 4 — CloudWatch Logs (Glue, Airflow)

**Audited via `scripts/audit_data_exposure.sh`**, a grep-based check for
row-level print/log statements. This is a starting point, not a
guarantee — grep proves the absence of an obvious pattern, not the
absence of a problem. The Airflow DAG's own logging was designed from
the start to push only counts and status strings via XCom (visible
directly in `retail_pipeline.py` — `_send_status_email` builds its report
from `fct_pipeline_reconciliation`, an aggregate table, never from a
row-level query). The Glue script needs the same confirmation by direct
read, not by memory of what it was meant to do — recorded as a follow-up
since this ADR cannot confirm content it doesn't have current sight of.

### Layer 5 — Airflow's own metadata (SQLite, on-instance)

Task logs and the XCom store live in `/opt/airflow/` on the EC2 instance,
covered by disk-level encryption (`gp3`, `encrypted = true`) but not
separately access-controlled beyond SSH/SSM access to the box itself. As
long as tasks only push aggregate values via XCom (current design), this
layer carries no additional row-level exposure. This is a property to
maintain going forward, not a one-time check — any future task that logs
or pushes query results wholesale would need the same scrutiny applied
here retroactively.

### Layer 6 — Terraform state (S3)

**Checked, not applicable.** This project's Terraform manages
infrastructure (buckets, roles, instances) exclusively — no resource
captures row-level data as an attribute, and no `local-exec` output in
this codebase touches data. Recorded as checked rather than silently
assumed safe.

### Layer 7 — GitHub (PR comments, Actions logs)

**Checked, low risk by construction.** `terraform plan` output posted to
PRs contains no data. dbt test failures in this project's test suite
compare counts and sums (`assert_marts_dedup_reconciles`,
`assert_marts_revenue_reconciles`, and others) rather than selecting raw
rows — a deliberate pattern from how those tests were written, which
happens to also keep CI logs free of row-level content. Worth stating
explicitly as a reason those tests were shaped the way they were, not
purely a data-quality consideration.

## Known, accepted limitation

**Quasi-identifier re-identification via `country` + hashed
`customer_id` is not solved by this ADR.** A masked role seeing a hashed
ID repeated across rows, combined with a low-volume country (a handful
of Online Retail II countries have very few customers — Iceland, the
Channel Islands), could infer "this hash = the one customer from
[country]" without ever seeing the real ID. A correct fix (suppression
or generalization for low-volume country/ID combinations) is
disproportionate engineering for a public research dataset and is not
built. Documented here so it's a known, reasoned gap — same treatment
ADR 0013 gives every other accepted gap — rather than an unnoticed one.

## Consequences

**The Layer 2 finding is the one that mattered most.** It was found only
because this ADR's scope was widened past "just add the masking policy"
to "check the whole surface" — a narrower request would have shipped a
masked column while a broader, unnoticed exposure sat right next to it.

**Grep-based log auditing is a floor, not a ceiling.** `audit_data_exposure.sh`
catches obvious patterns; it does not replace reading the actual Glue
script and a real CI failure log by eye at least once.

## Follow-ups

- Confirm the Glue script directly (this ADR could not, without current
  sight of its content) — no `.show()`/`.collect()` debug calls left in.
- Run `audit_data_exposure.sh` and read its output, including the manual
  checks it cannot automate.
- Check every other `FUTURE TABLES`/`ALL TABLES` grant in the project for
  the same silent-scope-expansion pattern found in Layer 2.
- Verify the masking policy and narrowed grants in a live session —
  query as `RETAIL_READER` and confirm both the hash and the
  `fct_order_lines` restriction are actually in effect, not just applied.
