# ADR 0005 — Bucket-per-layer-per-environment; raw is immutable NDJSON

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

The source data is Online Retail II: a single CSV of roughly 1.06 million
transactions from a UK online retailer, December 2009 to December 2011. It
carries the messiness of a real extract — cancellations, negative quantities,
missing customer identifiers, zero prices, duplicate rows.

Two questions had to be settled before any pipeline code was written: how
storage is partitioned across environments and processing stages, and what
format each stage holds.

## Decision

**Six buckets**, one per environment per layer:

```
sd-retail-{dev,prod}-{raw,staged,curated}-<account>-eu-west-2-an
```

**Raw** holds NDJSON, one object per invoice date, partitioned Hive-style
(`event_date=YYYY-MM-DD/`). It is written once and never modified. No
cleaning happens on ingest: cancellations, nulls, negative quantities and
duplicates all land as they arrive.

**Staged** holds Parquet, Snappy-compressed, partitioned by year/month, produced by a Glue job reading a month of raw. The grain deliberately differs from raw — see ADR 0007.

**Curated** holds modelled marts.

The CSV-to-NDJSON conversion runs **locally**, not in the cloud.

## Rationale

**Separate buckets rather than prefixes within one bucket.** Bucket-level IAM
policies are simpler to write and easier to audit than prefix-scoped ones, and
prefix conditions are easy to get subtly wrong. Lifecycle rules and
versioning also apply per bucket, so different retention for raw versus
curated falls out naturally. The cost is six buckets to manage instead of one,
which Terraform makes irrelevant.

**Raw is immutable because it is the replay point.** Every downstream
correction — a bug in the cleaning logic, a changed business rule about what
counts as a cancellation — is recoverable by reprocessing from raw. If raw
were cleaned on ingest, the original would be gone and the mistake permanent.
This is the single most consequential decision in the storage design, and it
is the reason the conversion script deliberately preserves the mess.

**NDJSON rather than a JSON array.** Spark, Glue and Snowflake all read
line-delimited JSON natively and can split it across workers. A single
`[{...},{...}]` array must be parsed whole and is awkward in every one of
those tools.

**JSON at raw and Parquet at staged, rather than Parquet throughout.** JSON
is the format an order-events API would actually emit, so raw reflects the
shape data arrives in rather than a shape already convenient for analytics.
The conversion to columnar Parquet is then a real transformation step with a
measurable effect — expect the dataset to fall from roughly 200–300 MB of
JSON to well under 50 MB of Parquet, a figure worth capturing for the
cost/performance write-up.

**Daily partitions give the pipeline something honest to be incremental
about.** The source is a static historical file. Splitting it into one object
per invoice date and dropping days in sequence produces a genuine watermark
column, genuine incremental models, idempotent reruns, and a late-arriving
data scenario — none of which a single bulk load would exercise.

**Local conversion keeps the cloud bill at zero for a step that gains nothing
from being remote.** A one-off reshaping of a 1M-row file is a laptop-sized
problem.

## Consequences

**Raw grows and is never pruned by the pipeline.** Lifecycle rules handle it
instead: transition to Standard-IA after 30 days, expire non-current versions
after 90. That second rule caps how far back a replay can reach, which is the
retention question this design should be able to answer under questioning.

**Versioning is inconsistent across the six buckets.** Enabled on `prod-raw`
and `prod-staged` only, as inherited from the console build and deliberately
frozen there rather than silently normalised — see ADR 0001. The four
unversioned buckets are not managed for versioning at all, so drift on them
will not be corrected.

**Local conversion is a manual step outside CI.** The NDJSON files are not
committed (`data/` is gitignored), so reproducing the pipeline from a clean
clone requires downloading the source CSV and running the script by hand. The
script is committed and documented; the artefacts are not.

**Partitioning by `event_date` bakes in an assumption.** Queries filtering by
invoice date prune efficiently; queries filtering by customer or product scan
everything. Reasonable for a time-series retail workload, and worth stating
as a choice rather than leaving implicit.

**The staged layer duplicates raw.** Roughly 1M rows exist twice in different
formats. Acceptable at this size, and the compression means the second copy is
much smaller than the first.

## Alternatives considered

**One bucket, prefixes for environment and layer.** Fewer resources and one
place to look. Rejected: prefix-scoped IAM is more error-prone than
bucket-scoped, and per-layer lifecycle and versioning become harder to
express.

**Clean the data during conversion.** Would make every downstream step
simpler. Rejected outright — it destroys the replay point and hides exactly
the data-quality problems the project is meant to demonstrate handling.

**Parquet from the start, skipping JSON.** Faster and cheaper. Rejected
because it removes the format-conversion step, which is both the honest
representation of how event data arrives and the clearest justification for
using Spark at all on a dataset this size.

**Convert in the cloud (Lambda or Glue) rather than locally.** Rejected on
cost for a step that runs once and needs no distributed compute.

## Follow-ups

- Record the actual JSON-to-Parquet size and query-time delta for the
  cost/performance case study.
- Decide and document a retention policy for the staged layer, which
  currently has neither lifecycle rules nor a stated position.
