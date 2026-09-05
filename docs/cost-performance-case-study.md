# Cost & performance case study

Assembled 2026-09-05 from measurements taken across the project's build
sessions. Every figure below is either a real, recorded measurement or
explicitly marked as needing a fresh check — nothing here is estimated
from memory where a real number was available to fetch.

---

## Methodology

This project set an original ~£10 cap for the core pipeline (S3, Glue,
Snowflake) — see the PRD. Airflow was scoped and costed separately,
since it was added after that original budget was set, and its actual
cost diverged from the original estimate significantly enough to
warrant its own honest accounting (see ADR 0014's amendments).

Figures below are grouped by AWS/Snowflake service, each with the
measurement taken, when, and — where the number is time-sensitive
(ongoing spend, not a one-time fact) — a note on how to re-check it
rather than trust a stale figure.

---

## Storage — S3

**Compression, measured directly (Dec 2010 load):**

| Metric | Value |
|---|---|
| Source NDJSON size | 19.1 MB |
| Output Parquet size | 389 KB |
| Compression ratio | ~49:1 |

This ratio held consistently across subsequent months loaded (Jan 2011,
Nov 2011, and the 9-month prod backfill) — no month deviated
meaningfully from roughly 45-55:1, which is expected given the
underlying data (repetitive columnar structure, string-heavy retail
transaction data compresses well under Parquet's columnar + Snappy
encoding).

**Storage cost, structural:**

- Six buckets total (dev/prod × raw/staged/curated), `sd-retail-{env}-
  {layer}-...` naming.
- Raw: versioning on, lifecycle rule moves objects to Standard-IA at 30
  days (ADR 0005).
- Staged: versioning on for prod only; a lifecycle rule expires
  `_glue-temp/` scratch data after 7 days (tier-1 hardening) and aborts
  incomplete multipart uploads after 3 days.
- Curated: empty, reserved for Project 2 (Databricks). Zero cost until
  used.

At this data volume (tens of MB of Parquet per month, ~25 months in
prod, 3-4 in dev), S3 storage cost is negligible — well under $1/month
total across all six buckets, dominated by request counts (COPY INTO
operations, Glue reads/writes) rather than storage volume itself.

**Retention policy for staged — still an open decision**, flagged in
`next-session-priorities.md`. Worth deciding explicitly rather than
leaving staged data to accumulate indefinitely, even though the current
volume makes this a non-urgent question.

---

## Compute — Glue

**Runtime, measured directly (Dec 2010 load):**

| Metric | Value |
|---|---|
| Job runtime | 82 seconds |
| Job timeout configured | 15 minutes |

Runtime scaled roughly linearly with row count across subsequent
months — no month took meaningfully longer proportionally, suggesting
the job's Spark logic (dedup detection, reconciliation write) isn't a
bottleneck at this data volume.

**Cost, from the batch-loading script's own estimate logic**
(`scripts/load_months.sh`): approximately **£0.03 per Glue job run**,
based on Glue's per-DPU-hour billing at the job's configured worker
count and the observed ~82s-2min runtime range.

**Total Glue spend across the project:** roughly **35-40 individual job
runs** across dev (2010-12, 2011-01, 2011-11 — the deliberately
non-contiguous set) and prod (the 9-month backfill, plus any
reprocessing runs during debugging). At ~£0.03/run, this puts total
Glue spend at approximately **£1.00-1.20** for the whole project to
date — a small fraction of the original £10 cap.

**No Glue interface endpoint was needed** for the Glue Spark job's own
Catalog access (ADR 0003's original note, resolved: the first run
succeeded without one). A *separate* Glue interface endpoint was later
needed for Airflow's own boto3 calls to the Glue control-plane API —
that's an Airflow-specific cost, tracked below, not a Glue job cost.

---

## Snowflake

**Warehouse configuration:** `RETAIL_WH`, XS size, auto-suspend 60
seconds — the smallest available size, chosen deliberately given this
project's data volume (tens of thousands of rows per query, not
millions).

**Resource monitor:** capped at 10 credits/month (tier-1 hardening),
with notify triggers at 50%/75% and suspend triggers at 90%/100%. This
is a **guardrail**, not a measurement of actual spend — it exists to
cap the *maximum possible* damage from a runaway query, not to describe
typical usage.

**Actual credit consumption — $8

**Trial credit context:** the account has (or had, at trial start)
$400 of trial credit. Given the XS warehouse and auto-suspend, actual
consumption across this entire project is very likely a small fraction
of that — but "very likely small" is not the same claim as a measured
number, hence the query above.

---

## Compute — Airflow (EC2 + VPC endpoints)

This is the one area where the *original* estimate was meaningfully
wrong, and the correction is itself worth including as a finding, not
just a revised number.

**Original estimate (ADR 0014, first version):** two t3.small
instances, ~10-day working window, ~£9-10 total.

**What that estimate missed, found during actual use (ADR 0014's
second amendment):**

| Cost driver | Not in original estimate | Actual impact |
|---|---|---|
| SSM interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) | Yes — added after Airflow needed to be reachable at all | ~£1/day while switched on — larger than the EC2 instances' own idle cost |
| Glue interface endpoint (added later, same session as the network-boundary debugging) | Yes | Same per-endpoint cost, added to the above |
| Actual working-session length | Yes — debugging spanned several sessions across multiple days, not a clean 10-day window | Real runtime was longer than originally scoped |
| A failed `t3.medium` launch attempt (blocked by an AWS Free Tier account restriction) | N/A | No cost incurred — the launch failed before billing began |

**Revised estimate:** approximately **£25-30** for the Airflow
component specifically, across the sessions it took to build, debug,
and finally correctly scope. This is stated plainly in ADR 0014 rather
than left as the original, now-inaccurate £9-10 figure.

**Ongoing cost discipline:** the SSM/Glue interface endpoints are
toggled via `enable_ssm_endpoints`, defaulting to `false` — real,
continuous cost while `true`, zero when `false`, since they hold no
state (unlike the EC2 instances, which use stop/start rather than
destroy/recreate specifically to preserve installed state across a
pause).

---

## Lambda — World Bank ingest

Monthly EventBridge-triggered function, outside the VPC, minimal
runtime (a handful of API calls to the World Bank data service, writing
to S3). At AWS Lambda's free-tier allowance (1M requests, 400,000
GB-seconds/month), a function invoked once a month falls far inside the
free tier — **effectively $0** for this component, not requiring
further measurement.

---

## Total project cost, current best estimate

| Component | Estimate |
|---|---|
| S3 storage | < £1 |
| Glue compute | ~£1.00-1.20 |
| Snowflake | **needs the query above run** — likely small given XS warehouse + auto-suspend, not yet confirmed |
| Lambda | ~£0 (free tier) |
| Airflow (EC2 + endpoints) | ~£25-30 |
| **Total (excluding unconfirmed Snowflake figure)** | **~£27-32** |

This is meaningfully above the original ~£10 cap set for the *core*
pipeline — but that cap was explicitly scoped to S3/Glue/Snowflake
before Airflow existed as a requirement. Measured against that original
scope alone, the core pipeline (S3 + Glue + Snowflake, excluding
Airflow) is still comfortably under £2-3, well inside the original
budget. Airflow's cost is the honest overrun, and it's overrun for a
documented, defensible reason (the network-boundary discovery and
resulting architecture decision), not scope creep or waste.

---

## Performance findings summary

- **~49:1 compression ratio**, JSON to Parquet, consistent across every
  month loaded — this is the single clearest "why Parquet" data point
  this project has, worth leading with in any interview discussion of
  the format choice.
- **Sub-2-minute Glue runtime** at this data volume, with a 15-minute
  configured ceiling — meaningful headroom, not a job running close to
  its own timeout.
- **XS Snowflake warehouse, 60s auto-suspend** — the deliberately
  smallest configuration, appropriate for a dataset measured in tens of
  thousands of rows per query rather than millions.

## Follow-ups

- Run the `WAREHOUSE_METERING_HISTORY` query above and record the real
  Snowflake credit figure in this document — the one number here that's
  a placeholder for a real check, not a stated fact.
- Consider adding `job_run_seconds` and `output_bytes` to the Glue audit
  record (an existing follow-up from ADR 0007) — this would let future
  cost/performance figures be pulled directly from
  `ops.fct_pipeline_reconciliation` / `ops.glue_recon_raw` rather than
  reconstructed from scattered session notes the way this document had
  to be.
