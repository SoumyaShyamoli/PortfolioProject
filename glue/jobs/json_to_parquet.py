"""
Glue job: raw NDJSON -> staged Parquet, with reconciliation.

Reads ONE MONTH of daily NDJSON partitions from the raw bucket, converts them
to Snappy-compressed Parquet partitioned by year/month, writes to the staged
bucket, and reconciles source line count against rows written.

Design notes:
  * FORMAT CONVERSION, not cleaning. Cancellations, null customer ids,
    negative quantities and duplicates pass through untouched — cleaning
    belongs in dbt staging, with raw as the replay point (docs/adr/0005).
  * Raw stays daily; staged is monthly. Daily partitions at this volume would
    produce ~1,400-row Parquet files, i.e. the small-file problem. Monthly
    gives ~40k rows per partition and 25 partitions across the dataset.
  * ONE RUN OWNS ONE OUTPUT PARTITION. The job reads a whole month and writes
    that month. Running it against a single day while partitioning by month
    would dynamic-overwrite the rest of the month out of existence.
  * Idempotent: dynamic partition overwrite means re-running a month replaces
    that month rather than appending a second copy.
  * Reconciliation is enforced, not logged. A silent shortfall looks
    identical to success in every downstream check.

Job parameters:
  --input_bucket   raw bucket name
  --year           e.g. 2010
  --month          e.g. 12  (1-12, zero-padding optional)
  --output_bucket  staged bucket name
  --fail_on_recon_mismatch  "true" (default) | "false"
"""

import json
import sys
from datetime import datetime, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import col, to_timestamp
from pyspark.sql.functions import month as month_of
from pyspark.sql.functions import year as year_of
from pyspark.sql.types import (
    DoubleType,
    IntegerType,
    StringType,
    StructField,
    StructType,
)

# --- Job setup -----------------------------------------------------------

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "input_bucket", "output_bucket", "year", "month"],
)
fail_on_mismatch = args.get("fail_on_recon_mismatch", "true").lower() != "false"

target_year = int(args["year"])
target_month = int(args["month"])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# Idempotency: with mode("overwrite") this replaces ONLY the partitions in
# this write. Without it, overwrite wipes the entire output path.
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

run_id = args.get("JOB_RUN_ID", "local")

# Raw is partitioned daily; glob one month of it.
input_path = (
    f"s3://{args['input_bucket']}/orders/"
    f"event_date={target_year}-{target_month:02d}-*/*.json"
)
output_path = f"s3://{args['output_bucket']}/orders/"

print(f"Target period: {target_year}-{target_month:02d}")
print(f"Reading: {input_path}")

# --- Schema --------------------------------------------------------------
# _corrupt_record captures lines Spark cannot parse as JSON. Without it,
# malformed lines silently become all-null rows and vanish into the data.

CORRUPT_COL = "_corrupt_record"

schema = StructType([
    StructField("invoice_no", StringType(), True),
    StructField("stock_code", StringType(), True),
    StructField("description", StringType(), True),
    StructField("quantity", IntegerType(), True),
    StructField("invoice_date", StringType(), True),
    StructField("unit_price", DoubleType(), True),
    StructField("customer_id", StringType(), True),
    StructField("country", StringType(), True),
    StructField("source_system", StringType(), True),
    StructField("ingested_at", StringType(), True),
    StructField(CORRUPT_COL, StringType(), True),
])

# =========================================================================
# RECON POINT 1 — source line count
# =========================================================================
# Read as plain text and count lines. NDJSON is one record per line, so this
# is ground truth for "how many records arrived", independent of parsing.

source_lines = spark.read.text(input_path).count()
print(f"RECON source_lines={source_lines}")

if source_lines == 0:
    raise ValueError(
        f"No lines read from {input_path}. "
        f"Check that raw partitions exist for {target_year}-{target_month:02d}."
    )

# --- Read as JSON --------------------------------------------------------

df = (
    spark.read
    .schema(schema)
    .option("mode", "PERMISSIVE")
    .option("columnNameOfCorruptRecord", CORRUPT_COL)
    .json(input_path)
)

df.cache()

# =========================================================================
# RECON POINT 2 — parsed vs corrupt
# =========================================================================

parsed_total = df.count()
corrupt_rows = df.filter(col(CORRUPT_COL).isNotNull()).count()
good_rows = parsed_total - corrupt_rows

print(f"RECON parsed_total={parsed_total} good_rows={good_rows} "
      f"corrupt_rows={corrupt_rows}")

if corrupt_rows > 0:
    print("Sample corrupt records:")
    for r in df.filter(col(CORRUPT_COL).isNotNull()).select(CORRUPT_COL).take(3):
        print(f"  {r[CORRUPT_COL][:200]}")

# --- Transform -----------------------------------------------------------

clean = df.filter(col(CORRUPT_COL).isNull()).drop(CORRUPT_COL)

clean = (
    clean
    .withColumn("invoice_date", to_timestamp("invoice_date"))
    .withColumn("ingested_at", to_timestamp("ingested_at"))
    # Partition keys derived from the DATA, not from the job arguments, so a
    # misfiled object lands in the correct partition rather than inheriting a
    # wrong one from the input path.
    .withColumn("year", year_of("invoice_date"))
    .withColumn("month", month_of("invoice_date"))
)

clean.cache()

# --- Guard: the run must own exactly one output partition ----------------
# If raw contains a row whose invoice_date falls outside the target month,
# writing it here would dynamic-overwrite a DIFFERENT month's partition with
# just that stray row — destroying data that was correct.

stray = clean.filter(
    (col("year") != target_year) | (col("month") != target_month)
).filter(col("invoice_date").isNotNull())

stray_count = stray.count()
if stray_count > 0:
    print("Stray rows outside the target month:")
    stray.select("invoice_no", "invoice_date", "year", "month").show(5, False)
    raise ValueError(
        f"{stray_count} rows fall outside {target_year}-{target_month:02d}. "
        f"Writing them would overwrite another month's partition. "
        f"Check the raw partition contents before rerunning."
    )

# --- Quality metrics (observed, NOT enforced) ----------------------------
# Single pass. Should reconcile against the local profiling numbers.

m = clean.selectExpr(
    "count(*)                                              as rows_total",
    "sum(case when invoice_no is null then 1 else 0 end)   as null_invoice_no",
    "sum(case when customer_id is null then 1 else 0 end)  as null_customer_id",
    "sum(case when quantity < 0 then 1 else 0 end)         as negative_quantity",
    "sum(case when unit_price <= 0 then 1 else 0 end)      as non_positive_price",
    "sum(case when invoice_no like 'C%' then 1 else 0 end) as cancellations",
    "sum(case when invoice_date is null then 1 else 0 end) as unparseable_date",
).collect()[0]

print(
    "QUALITY_METRICS "
    f"period={target_year}-{target_month:02d} "
    f"rows_total={m['rows_total']} "
    f"null_invoice_no={m['null_invoice_no']} "
    f"null_customer_id={m['null_customer_id']} "
    f"negative_quantity={m['negative_quantity']} "
    f"non_positive_price={m['non_positive_price']} "
    f"cancellations={m['cancellations']} "
    f"unparseable_date={m['unparseable_date']}"
)

# --- Write ---------------------------------------------------------------
# Rows with no parseable invoice_date have null year/month and would land in
# __HIVE_DEFAULT_PARTITION__. Excluded from the write and accounted for in
# the recon below, rather than quietly polluting the partition scheme.
# Follow-up: route these to a quarantine prefix instead of discarding.

writable = clean.filter(col("invoice_date").isNotNull())
rows_to_write = writable.count()

# coalesce(1): ~40k rows per month is a single small file. Without this Spark
# emits one file per input day — 30 tiny files per month.
print(f"Writing {rows_to_write} rows to {output_path}")

(
    writable.coalesce(1)
    .write
    .mode("overwrite")            # dynamic: only year=/month= for this run
    .partitionBy("year", "month")
    .option("compression", "snappy")
    .parquet(output_path)
)

# =========================================================================
# RECON POINT 3 — read back what actually landed
# =========================================================================
# Counting the DataFrame is not proof the write succeeded. Reading the
# written partition back from S3 is.

part_path = f"{output_path}year={target_year}/month={target_month}"
written_back = spark.read.parquet(part_path).count()

print(f"RECON rows_to_write={rows_to_write} written_back={written_back}")

# --- Reconciliation ------------------------------------------------------
#   source_lines = corrupt_rows + undated_rows + rows_written_back

undated = m["unparseable_date"]
expected = source_lines - corrupt_rows - undated
balanced = written_back == expected

recon = {
    "run_id": run_id,
    "job_name": args["JOB_NAME"],
    "period": f"{target_year}-{target_month:02d}",
    "input_path": input_path,
    "output_partition": part_path,
    "recon_at": datetime.now(timezone.utc).isoformat(),
    "source_lines": source_lines,
    "corrupt_rows": corrupt_rows,
    "undated_rows": undated,
    "expected_rows": expected,
    "rows_written_back": written_back,
    "difference": written_back - expected,
    "balanced": balanced,
    "quality": {k: m[k] for k in m.asDict()},
}

print("RECON_RESULT " + json.dumps(recon))

# Persist the audit record — small JSON per run, queryable later via Athena
# over the _audit prefix. This is the evidence behind the data quality
# deliverable, rather than a claim about it.
s3 = boto3.client("s3")
audit_key = (
    f"_audit/recon/job={args['JOB_NAME']}/"
    f"period={target_year}-{target_month:02d}/{run_id}.json"
)
s3.put_object(
    Bucket=args["output_bucket"],
    Key=audit_key,
    Body=json.dumps(recon, indent=2).encode("utf-8"),
    ContentType="application/json",
)
print(f"Audit record: s3://{args['output_bucket']}/{audit_key}")

df.unpersist()
clean.unpersist()

if not balanced:
    msg = (
        f"RECONCILIATION FAILED for {target_year}-{target_month:02d}: "
        f"expected {expected} rows (source {source_lines} - corrupt "
        f"{corrupt_rows} - undated {undated}), found {written_back} in S3. "
        f"Difference: {written_back - expected}."
    )
    if fail_on_mismatch:
        raise ValueError(msg)
    print("WARNING: " + msg)

job.commit()