# ADR 0007 — Monthly staged partitions; reconciliation enforced, not logged

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

Raw arrives as one NDJSON file per invoice date — roughly 730 daily files
across the December 2009 to December 2011 dataset. The Glue job converts raw
to Parquet in the staged layer, and two questions had to be answered: what
partition grain staged uses, and what happens when the row counts do not
agree.

Both were initially answered the obvious way (mirror raw's daily grain; log
quality metrics) and both were changed after thinking through the failure
modes.

## Decision

**Staged is partitioned by `year` / `month`, not by `event_date`.** Raw stays
daily. One Glue job run reads one month of daily raw files and writes exactly
one staged partition.

**Reconciliation is enforced.** The job computes three independent counts and
fails if they do not balance:

```
source_lines = corrupt_rows + undated_rows + rows_written_back
```

1. `source_lines` — the raw files read as plain text and counted. Ground
   truth for "how many records arrived", independent of parsing.
2. `corrupt_rows` — captured via `_corrupt_record` in PERMISSIVE mode.
3. `rows_written_back` — the written Parquet partition read back from S3.

A JSON audit record per run is written to `_audit/recon/` in the staged
bucket.

## Rationale

### Why monthly rather than daily

**Daily partitions produce the small-file problem.** At roughly 1,400 rows
per day, each daily Parquet file would be about 30 KB, and there would be 730
of them. Object listing dominates read time at that shape, and query planners
handle a few hundred small files badly. Monthly gives about 40,000 rows and
1–2 MB per partition across 25 partitions — still small in Spark terms, but
defensible.

**Yearly was considered and rejected.** Three partitions is not enough to
demonstrate partition pruning meaningfully, and three increments is not an
incremental loading story.

**Cost.** Glue bills per DPU-second with a one-minute minimum, so a short job
costs roughly 2–3p regardless of how little work it does. 730 daily runs is
£15–20 against a £10 total budget; 25 monthly runs is under £1. The minimum
billing increment, not the compute, is what makes fine-grained runs
expensive.

### Why raw stays daily

Daily raw is the honest representation of how event data arrives, keeps the
replay point fine-grained, and lets a single bad day be re-dropped without
touching its neighbours. The grain mismatch between layers is deliberate:
raw optimises for fidelity and replay, staged optimises for query.

### One run owns one partition

This is the constraint that makes idempotency work. The job writes with
`spark.sql.sources.partitionOverwriteMode=dynamic` and `mode("overwrite")`,
which replaces only the partitions present in the write. If a run processed a
single day while partitioning by month, that write would replace the entire
month with one day's rows — silently destroying correct data.

Two guards enforce it. The job takes `--year` and `--month` rather than a
file key, so a caller cannot point it at a single day. And partition keys are
derived from `invoice_date` in the data rather than from the arguments, with
a check that fails the run if any row falls outside the target month — a
November-dated row inside a December file would otherwise create a
`year=2010/month=11` partition containing only that row, overwriting
November's real data.

Concurrency is capped at one run per job for the same reason.

### Why reconciliation fails the job rather than logging

**A silent shortfall is indistinguishable from success.** If a Glue run drops
5% of a month's rows, every downstream check still passes — dbt tests run
against what loaded, dashboards render, nothing errors. The only way to
notice is to have known the expected count beforehand, which is exactly what
the recon computes. Logging it means the number exists but nobody looks; the
failure mode this guards against is precisely the one where nobody looks.

**Counting the DataFrame is not proof of a write.** The third count reads the
written partition back from S3 deliberately. An in-memory count confirms
Spark's intent, not S3's state.

**`_corrupt_record` is not optional.** Without it, PERMISSIVE mode turns
unparseable lines into all-null rows that pass through into the data. The
column makes malformed input countable rather than invisible.

An escape hatch exists — `--fail_on_recon_mismatch false` — for the case
where a known-bad day must be pushed through deliberately. The default is to
fail.

## Consequences

**Backfilling a month is a single run.** Re-running any month replaces that
month's partition; no manual cleanup, no duplicate rows. This is the
practical payoff of the idempotency work.

**Reprocessing granularity is a month.** Correcting a single day means
reprocessing its whole month. Acceptable at this volume; it would not be at
a scale where a month is hours of compute.

**The audit records become a dataset.** One JSON per run accumulates into
something queryable — via Athena over the `_audit` prefix, and loaded into
Snowflake as an operations table. That enables an end-to-end chain where every
hop has a number: local profiling counts, Glue recon counts, Snowflake load
counts, dbt staging counts. A dbt test comparing staging row counts against
the sum of `rows_written_back` for the same periods is a real control rather
than a claim.

The recorded quality metrics also become test thresholds: staging drops
cancellations and null customer ids, and the audit record says how many there
should have been.

**Rows with an unparseable `invoice_date` are excluded from the write.** They
have no partition key and would land in `__HIVE_DEFAULT_PARTITION__`. They
are subtracted explicitly in the recon equation rather than absorbed into a
tolerance, so a non-zero count is visible. Follow-up: route them to a
quarantine prefix instead of discarding.

**A failed reconciliation blocks the pipeline.** By design, but it means a
genuine data anomaly stops processing until a human looks. That is the right
trade for a platform where correctness matters more than availability, and
the wrong one for a platform where it does not — worth stating which
assumption is being made.

## Alternatives considered

**Daily staged partitions matching raw.** Symmetrical and simpler to reason
about. Rejected on the small-file problem and per-run cost above.

**Yearly partitions.** Cheapest and fewest runs. Rejected — three partitions
demonstrate nothing about pruning or incremental loading.

**Log reconciliation without failing.** The common approach, and the reason
silent data loss is common. Rejected as above.

**Trust Spark's write and skip the read-back.** Saves one S3 read per run.
Rejected: the read-back is the only step that confirms what is actually in
the bucket, which is the thing downstream consumers will read.

## Follow-ups

- Route undated rows to a quarantine prefix rather than excluding them.
- Add `job_run_seconds` and `output_bytes` to the audit record, so the ops
  table carries cost/performance evidence per month rather than a few
  manually noted figures.
- Register the `_audit/recon` prefix in the Glue Data Catalog so it is
  queryable via Athena without a schema definition per query.
