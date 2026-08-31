-- 05 (prod) — RAW.ORDERS table + load, mirrors dev's 05_raw_tables.sql
--
-- Prod's RAW schema currently has the World Bank tables and both stages,
-- but no ORDERS table — this creates it and loads whatever Parquet Glue
-- has already written to the staged bucket.

USE ROLE RETAIL_TRANSFORMER_PROD;
USE WAREHOUSE RETAIL_WH;
USE DATABASE RETAIL_PROD;

-- --------------------------------------------------------------------------
-- Table
-- --------------------------------------------------------------------------
-- Same shape as RETAIL_DEV.RAW.ORDERS. partition_year/partition_month are
-- parsed from the Parquet file path via METADATA$FILENAME at load time —
-- this is what ADR 0012's reprocessing logic (DELETE by
-- partition_year/partition_month, then COPY...FORCE) keys off, so the
-- column names and population method must match dev exactly.

CREATE TABLE IF NOT EXISTS RAW.ORDERS (
    invoice_no       VARCHAR,
    stock_code       VARCHAR,
    description      VARCHAR,
    quantity         NUMBER,
    invoice_date     TIMESTAMP_NTZ,
    unit_price       FLOAT,
    customer_id      VARCHAR,
    country          VARCHAR,
    source_system    VARCHAR,
    ingested_at      TIMESTAMP_TZ,
    partition_year   NUMBER,
    partition_month  NUMBER,
    source_file      VARCHAR,
    loaded_at        TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- --------------------------------------------------------------------------
-- Load — whatever Parquet is currently in the staged bucket
-- --------------------------------------------------------------------------
-- PATTERN excludes the zero-byte Hadoop directory marker
-- (year=YYYY_$folder$) that broke the very first dev load — see ADR 0012's
-- note on this. ON_ERROR = ABORT_STATEMENT so a bad file fails loudly
-- rather than silently skipping rows.
--
-- FORCE = TRUE: this is a first load into an empty table, so there is no
-- "already loaded" file history to worry about overriding — included for
-- consistency with the reprocessing pattern, not because it matters here.

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
        REGEXP_SUBSTR(METADATA$FILENAME, 'year=([0-9]+)', 1, 1, 'e', 1)::NUMBER,
        REGEXP_SUBSTR(METADATA$FILENAME, 'month=([0-9]+)', 1, 1, 'e', 1)::NUMBER,
        METADATA$FILENAME
    FROM @RAW.STG_ORDERS
)
PATTERN = '.*part-.*[.]snappy[.]parquet'
FILE_FORMAT = (TYPE = PARQUET)
FORCE = TRUE
ON_ERROR = 'ABORT_STATEMENT';

-- --------------------------------------------------------------------------
-- Verify
-- --------------------------------------------------------------------------

SELECT
    partition_year,
    partition_month,
    COUNT(*) AS row_count,
    MIN(invoice_date) AS min_date,
    MAX(invoice_date) AS max_date
FROM RAW.ORDERS
GROUP BY 1, 2
ORDER BY 1, 2;

-- Confirm no zero-byte marker rows snuck through (would show as a row with
-- null/garbage partition values).
SELECT COUNT(*) AS suspect_rows
FROM RAW.ORDERS
WHERE partition_year IS NULL OR partition_month IS NULL;
