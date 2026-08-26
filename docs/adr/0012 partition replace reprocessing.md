# ADR 0012 — Partition-replace reprocessing, end to end

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

Reprocessing a month has to mean the same thing at every layer, or the
warehouse and S3 drift apart and "what is currently true" depends on which
query you happen to write.

Glue already had an answer: dynamic partition overwrite. Re-run a month and
that month's S3 partition is replaced. The problem surfaced when data started
landing in Snowflake, because two things there do not naturally work that
way.

**`COPY INTO` tracks loaded files, not partitions.** Snowflake remembers
which files it has ingested and skips them for 64 days. That stops the same
file loading twice, which sounds like idempotency but is not the same thing.
When Glue reprocesses a month it writes a NEW file — a different
`part-00000-<uuid>.snappy.parquet` — into the same partition, having deleted
the old one. Snowflake has never seen the new filename, so it loads it, and
now `RAW.ORDERS` holds both the old rows and the new ones. S3 is correct and
the warehouse has doubled.

**Every Glue run appends an audit record.** Reprocessing 2011-01 leaves two
reconciliation records for that period. Comparing staging counts against all
of them double-counts; comparing against an arbitrary one might pick up a
stale failure and report a mismatch that no longer exists.

## Decision

**One meaning of reprocessing, at every layer: the period is replaced.**

| Layer | Mechanism |
|---|---|
| S3 | `spark.sql.sources.partitionOverwriteMode=dynamic` with `mode("overwrite")` |
| Snowflake RAW | delete the partition before `COPY INTO ... FORCE = TRUE` |
| dbt staging | `incremental_strategy='delete+insert'`, `unique_key='period'` |
| Recon records | history retained; `stg_glue_recon` takes the latest per period |

The dbt config is the part worth explaining:

```sql
{{ config(
    materialized = 'incremental',
    incremental_strategy = 'delete+insert',
    unique_key = 'period'
) }}
```

`unique_key` is the **period**, not an invoice line key. dbt's `delete+insert`
deletes rows matching the unique key of what it is about to insert, so a
period-level key makes the operation a partition swap.

An invoice-line key would look more natural and would be wrong. It would
delete only the rows present in the incoming batch — so if a corrected run
produced 34,000 rows where the original produced 35,147, the 1,147 rows that
no longer exist would remain in staging forever. The bug would be invisible:
counts would be too high, not obviously broken, and only the reconciliation
against Glue's record would catch it.

Reprocessing is explicit rather than inferred:

```bash
dbt run -s stg_orders --vars '{"reprocess_periods": ["2011-01"]}'
```

Without that variable the model takes anything loaded since its last build.

## Rationale

**One mental model beats three correct ones.** Each layer could have used a
different idempotency mechanism and each would have worked in isolation. But
then explaining the system means explaining three mechanisms and their
interactions, and reasoning about a failure means checking which one applies
where. "Reprocess a month, that month is replaced, everywhere" is a sentence
that holds at every layer.

**Append-and-dedupe was the main alternative, and it fails on truth.** Keep
every version in the warehouse, dedupe downstream on the latest load
timestamp. It preserves history and avoids deletes. But it means the
warehouse holds rows that S3 no longer has, and every downstream query must
remember to apply the dedupe — miss it once and the number is wrong. The
warehouse would no longer be a representation of the source; it would be an
accumulation of everything the source has ever said.

**Deletes are safe here because raw is the replay point.** ADR 0005 makes S3
raw immutable, and the Glue pipeline role has no delete permission on it. So
deleting from `RAW.ORDERS` or from staging destroys nothing that cannot be
rebuilt. That is what makes the aggressive option acceptable.

**Recon history is kept even though current truth is deduped.** The raw audit
table holds every run; the view exposes the latest. Reruns and failed runs
stay visible, which is exactly what you want when investigating why a period
was reprocessed in the first place.

## Consequences

**`COPY INTO` needs `FORCE = TRUE` and a manual delete when reprocessing.**
This is the sharpest edge in the design, because the default behaviour looks
safe and is not. The load-file history makes a naive re-run appear
idempotent — it skips files it has seen — while a reprocessed partition
brings new filenames that get loaded on top. Reprocessing must therefore be:

```sql
DELETE FROM RAW.ORDERS WHERE partition_year = 2011 AND partition_month = 1;
COPY INTO RAW.ORDERS ... FORCE = TRUE;
```

Not automated yet. It should be, and it should live in the Airflow DAG
rather than in someone's memory.

**Reprocessing granularity is a month.** Correcting a single day means
reprocessing its whole month. Fine at this volume; it would not be at a
scale where a month is hours of compute.

**Staging is rebuilt for a whole period, not incrementally within one.**
A month arriving in pieces would rebuild that month's staging rows on each
arrival. Acceptable because the source is monthly-batched; would need
rethinking for genuinely continuous arrival, which the streaming path will
force a decision on.

**The recon test depends on the dedupe.** `assert_staging_matches_glue_recon`
compares against `stg_glue_recon`, which is the latest record per period.
Comparing against the raw table would fail every time a month is
reprocessed, for no real reason.

## A note on zero-byte files

Not a decision, but it cost time and belongs somewhere findable.

The first `COPY INTO` failed with `Parquet file size is 0 bytes`. The
culprit was `orders/year=2010_$folder$` — a directory marker written by
older Hadoop S3 filesystem implementations, not by Spark itself.

Two fixes applied: the object was deleted, and the COPY now filters with
`PATTERN = '.*part-.*[.]snappy[.]parquet'`. The pattern is the one that
matters, because deleting markers once does not stop them reappearing when
the load runs unattended.

`ON_ERROR = 'ABORT_STATEMENT'` is what surfaced this. With `CONTINUE` or
`SKIP_FILE` the load would have succeeded quietly and the marker would have
gone unnoticed — the same silent-success failure mode the reconciliation
exists to prevent.

## Follow-ups

- Automate the delete-then-`FORCE` reload in the Airflow DAG, so reprocessing
  is one action rather than a remembered sequence.
- Decide what reprocessing means for the streaming path, where arrival is
  continuous and "the period" is not a natural unit.
- Add a test asserting no duplicate `(period, source_file)` combinations in
  `RAW.ORDERS`, which would catch the double-load failure directly rather
  than via a count mismatch.


**Discovered characteristic (2026-08-25):** the source's true exact-duplicate rate is ~30%, not the ~1% originally assumed when the duplicate-stability test was written. Verified genuine against raw Parquet — identical invoice, stock code, quantity, timestamp (to the millisecond) and price. The reconciliation chain does not and cannot catch this, since Glue counts duplicate rows as rows; source lines, S3 writes, and Snowflake loads all agree regardless. This is the boundary of what row-count reconciliation proves: no rows lost in transit, not that arriving rows match expectation. Marts must deduplicate explicitly (filter duplicate_occurrence = 1) to produce a true order count; staging keeps every row per ADR 0005.