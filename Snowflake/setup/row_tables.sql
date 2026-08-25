-- 05 — RAW tables and initial load
--
-- Run as RETAIL_TRANSFORMER_DEV (not ACCOUNTADMIN — this is the role dbt
-- will use, so if it cannot do this, dbt cannot either).
--
-- RAW holds what lands from S3, typed but not cleaned. Cancellations, null
-- customer ids and negative quantities all arrive intact — cleaning happens
-- in dbt staging, per ADR 0005.

USE ROLE RETAIL_TRANSFORMER_DEV;
USE WAREHOUSE RETAIL_WH;
USE DATABASE RETAIL_DEV;

-- ==========================================================================
-- Orders
-- ==========================================================================
--
-- IMPORTANT: year and month are NOT columns in the Parquet files. Spark
-- writes Hive-partitioned output as directory names — year=2011/month=1/ —
-- and omits them from the file itself to avoid storing the same value on
-- every row.
--
-- So they have to be parsed out of METADATA$FILENAME on load. Getting this
-- wrong produces nulls in the partition columns and a load that looks
-- successful.
--
-- source_file and loaded_at are lineage columns. When a count does not match
-- the recon record, the first question is always "which file did this row
-- come from", and without source_file there is no answer.

CREATE TABLE IF NOT EXISTS RAW.ORDERS (
    invoice_no      VARCHAR,
    stock_code      VARCHAR,
    description     VARCHAR,
    quantity        NUMBER,
    invoice_date    TIMESTAMP_NTZ,
    unit_price      FLOAT,
    customer_id     VARCHAR,
    country         VARCHAR,
    source_system   VARCHAR,
    ingested_at     TIMESTAMP_TZ,

    -- Parsed from the S3 path, not from the file
    partition_year  NUMBER,
    partition_month NUMBER,

    -- Lineage
    source_file     VARCHAR,
    loaded_at       TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw orders from staged Parquet. Uncleaned by design.';

-- --------------------------------------------------------------------------
-- Load
-- --------------------------------------------------------------------------
-- COPY INTO is idempotent by default: Snowflake tracks loaded files and
-- skips them on re-run, for 64 days. That means running this twice does not
-- duplicate rows — but it also means a corrected file with the same name
-- will be SKIPPED. Use FORCE = TRUE deliberately when reprocessing, and
-- truncate the affected partition first.
--
-- $1:column_name is how Parquet fields are addressed. MATCH_BY_COLUMN_NAME
-- would be simpler but does not let us add the parsed path columns.

COPY INTO RAW.ORDERS (
    invoice_no, stock_code, description, quantity, invoice_date,
    unit_price, customer_id, country, source_system, ingested_at,
    partition_year, partition_month, source_file
)
FROM (
    SELECT
        $1:invoice_no::VARCHAR,
        $1:stock_code::VARCHAR,
        $1:description::VARCHAR,
        $1:quantity::NUMBER,
        $1:invoice_date::TIMESTAMP_NTZ,
        $1:unit_price::FLOAT,
        $1:customer_id::VARCHAR,
        $1:country::VARCHAR,
        $1:source_system::VARCHAR,
        $1:ingested_at::TIMESTAMP_TZ,

        -- METADATA$FILENAME looks like:
        --   orders/year=2011/month=1/part-0000-....snappy.parquet
        -- REGEXP_SUBSTR with a capture group pulls out the digits.
        REGEXP_SUBSTR(METADATA$FILENAME, 'year=([0-9]+)', 1, 1, 'e', 1)::NUMBER,
        REGEXP_SUBSTR(METADATA$FILENAME, 'month=([0-9]+)', 1, 1, 'e', 1)::NUMBER,

        METADATA$FILENAME
    FROM @RAW.STG_ORDERS
)
FILE_FORMAT = (TYPE = PARQUET)
PATTERN = '.*part-.*[.]snappy[.]parquet'
ON_ERROR = 'ABORT_STATEMENT';

-- ON_ERROR = ABORT_STATEMENT, not CONTINUE. A partial load that silently
-- skips bad rows is the same failure mode the Glue reconciliation exists to
-- prevent. Fail, look at why, fix it.

-- ==========================================================================
-- Reconciliation audit records
-- ==========================================================================
--
-- The JSON written by the Glue job on every run. Loaded as VARIANT and
-- flattened in dbt rather than shredded here, so a change to the audit
-- record shape does not require a DDL change.

CREATE TABLE IF NOT EXISTS OPS.GLUE_RECON_RAW (
    recon_record  VARIANT,
    source_file   VARCHAR,
    loaded_at     TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Glue job reconciliation records. One row per job run.';

COPY INTO OPS.GLUE_RECON_RAW (recon_record, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @OPS.STG_RECON
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = 'ABORT_STATEMENT';

-- ==========================================================================
-- Verify — this is the point of the exercise
-- ==========================================================================
--
-- The first hop of the end-to-end reconciliation chain. Glue said it wrote
-- N rows; Snowflake should agree. If these disagree, stop and find out why
-- before building anything on top.

SELECT
    partition_year,
    partition_month,
    COUNT(*) AS rows_in_snowflake
FROM RAW.ORDERS
GROUP BY 1, 2
ORDER BY 1, 2;

-- What Glue recorded, for the same periods
SELECT
    recon_record:period::VARCHAR       AS period,
    recon_record:rows_written_back::NUMBER AS rows_glue_wrote,
    recon_record:balanced::BOOLEAN     AS glue_balanced,
    recon_record:source_lines::NUMBER  AS source_lines
FROM OPS.GLUE_RECON_RAW
ORDER BY 1;

-- The two together. difference should be 0 on every row.
SELECT
    g.recon_record:period::VARCHAR          AS period,
    g.recon_record:rows_written_back::NUMBER AS glue_wrote,
    s.rows_in_snowflake,
    s.rows_in_snowflake - g.recon_record:rows_written_back::NUMBER AS difference
FROM OPS.GLUE_RECON_RAW g
LEFT JOIN (
    SELECT
        LPAD(partition_year, 4, '0') || '-' || LPAD(partition_month, 2, '0') AS period,
        COUNT(*) AS rows_in_snowflake
    FROM RAW.ORDERS
    GROUP BY 1
) s ON s.period = g.recon_record:period::VARCHAR
ORDER BY 1;

-- Sanity check on the partition parsing. If partition_year or
-- partition_month is null anywhere, the REGEXP did not match and the
-- filename format has changed.
SELECT COUNT(*) AS rows_with_null_partition
FROM RAW.ORDERS
WHERE partition_year IS NULL OR partition_month IS NULL;