# ADR 0006 — AWS Glue rather than EMR for Spark workloads

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

The pipeline needs one Spark workload: converting daily NDJSON partitions in
the raw layer to Snappy-compressed Parquet in the staged layer. It is bursty
— a short job per partition, triggered by object arrival — and small, since
the whole dataset is roughly 1.06 million rows.

EMR was originally in the design, chosen partly for CV coverage. Under a hard
sub-£10 total cloud budget that choice needed re-examining, since an EMR
cluster bills for every hour it exists whether or not a job is running.

## Decision

Use AWS Glue. No EMR cluster.

## Rationale

**Idle cost is the deciding factor for a bursty workload.** EMR bills for the
cluster; Glue bills per DPU-hour of actual execution. For a job that runs for
a few minutes on object arrival and then does nothing, the difference between
paying for execution and paying for existence is the difference between a few
pounds and the entire budget. Glue is expected to be the largest line item
regardless, at roughly £5–8 across the build at minimum 2 DPU.

**The transferable skill is nearly identical.** Glue jobs are PySpark. The
DataFrame API, partitioning strategy, schema handling and Spark-side
debugging are the same in both. What EMR adds is cluster lifecycle
management — sizing, bootstrap actions, YARN tuning — which is genuinely
EMR-specific but not exercised by a workload this small.

**The workload does not justify a cluster.** 1M rows is not a big-data
problem; it fits comfortably on a laptop. Standing up a managed Hadoop
cluster for it and then claiming distributed-processing experience would not
survive a follow-up question. The defensible framing is that Spark is used
for the format conversion and partitioning, at a scale where the tool choice
was about operational cost rather than about needing horizontal scale.

**"Why not EMR" is a better interview answer than "I used EMR".** Choosing
serverless to avoid idle cost on a bursty job is a cost-versus-control
judgment. Running a cluster because it looks impressive is not a judgment at
all.

## Consequences

**No cluster-management experience from this project.** Bootstrap actions,
instance fleet selection, spot interruption handling and YARN configuration
are not covered. If a target role specifically requires EMR, this is a
genuine gap and should be addressed separately rather than papered over.

**Glue's abstractions can obscure Spark.** Job bookmarks, DynamicFrames and
the managed runtime hide mechanics that are visible on EMR. Mitigated by
using plain Spark DataFrames rather than DynamicFrames wherever possible, so
the code stays recognisably PySpark.

**Version and library constraints are Glue's, not yours.** The Spark version
is whatever the chosen Glue version provides, and adding Python dependencies
means `--extra-py-files` rather than `pip install` — which matters more here
because the job runs in a private subnet with no internet route (ADR 0003).

**Cost control still requires discipline.** Serverless is not free. Minimum
DPU allocation, no development endpoints left running, and a bounded number
of job runs during testing.

## Alternatives considered

**EMR on EC2.** Rejected on idle cost for a bursty workload, as above.

**EMR Serverless.** A closer comparison — it also bills per execution and
removes the idle-cost objection. Rejected on the narrower margin: Glue
integrates more directly with the Data Catalog and with S3 event triggers via
Lambda, which is the orchestration path this pipeline uses, and Glue appears
at least as often as EMR in UK job specifications.

**No Spark at all — pandas in Lambda.** Genuinely viable at 1M rows, and
cheaper still. Rejected because the partitioned, columnar conversion is the
step that makes the storage design meaningful, and because a pipeline with no
distributed processing component would not exercise a skill the project is
meant to demonstrate. Worth acknowledging that this is a portfolio
consideration rather than a purely technical one.

**Databricks.** Deferred rather than rejected — planned as a separate
re-platforming exercise, which is where the Spark-native and lakehouse
comparison belongs.

## Follow-ups

- Record actual Glue job cost and runtime for the cost/performance case
  study, alongside the JSON-to-Parquet compression ratio.
- If the job fails on Glue API connectivity from the private subnet, see the
  interface endpoint follow-up in ADR 0003.
