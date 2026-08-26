-- 06 — World Bank reference data
--
-- The World Bank Lambda writes NDJSON to the RAW bucket, but the storage
-- integration created in 04 only allows the STAGED bucket. Both sides of the
-- trust need widening: STORAGE_ALLOWED_LOCATIONS here, and the IAM role
-- policy in infra/terraform/snowflake_integration.tf.
--
-- Do the Terraform change FIRST. Widening Snowflake's allowed locations
-- without the matching IAM permission produces an access-denied on LIST
-- that looks like an integration problem rather than a policy one.

-- ==========================================================================
-- PART A — widen the integration (ACCOUNTADMIN)
-- ==========================================================================
--
-- ALTER ... SET STORAGE_ALLOWED_LOCATIONS REPLACES the entire list. The
-- existing staged prefixes must be repeated or they are silently dropped
-- and every existing stage stops working.

USE ROLE ACCOUNTADMIN;

ALTER STORAGE INTEGRATION RETAIL_DEV_S3_INTEGRATION SET
  STORAGE_ALLOWED_LOCATIONS = (
    's3://sd-retail-dev-staged-009073574996-eu-west-2-an/orders/',
    's3://sd-retail-dev-staged-009073574996-eu-west-2-an/_audit/',
    's3://sd-retail-dev-raw-009073574996-eu-west-2-an/worldbank/'
  );

ALTER STORAGE INTEGRATION RETAIL_PROD_S3_INTEGRATION SET
  STORAGE_ALLOWED_LOCATIONS = (
    's3://sd-retail-prod-staged-009073574996-eu-west-2-an/orders/',
    's3://sd-retail-prod-staged-009073574996-eu-west-2-an/_audit/',
    's3://sd-retail-prod-raw-009073574996-eu-west-2-an/worldbank/'
  );

-- Confirm the list is what you expect before moving on.
DESC INTEGRATION RETAIL_DEV_S3_INTEGRATION;

-- ==========================================================================
-- PART B — stages and tables (RETAIL_TRANSFORMER_DEV)
-- ==========================================================================

USE ROLE RETAIL_TRANSFORMER_DEV;
USE WAREHOUSE RETAIL_WH;
USE DATABASE RETAIL_DEV;

CREATE STAGE IF NOT EXISTS RAW.STG_WORLDBANK
  STORAGE_INTEGRATION = RETAIL_DEV_S3_INTEGRATION
  URL                 = 's3://sd-retail-dev-raw-009073574996-eu-west-2-an/worldbank/'
  FILE_FORMAT         = (TYPE = JSON)
  COMMENT             = 'World Bank country metadata and indicators, NDJSON';

LIST @RAW.STG_WORLDBANK;

-- --------------------------------------------------------------------------
-- Countries
-- --------------------------------------------------------------------------
-- Loaded as flat columns rather than VARIANT: the Lambda already flattens
-- the API's nested region/incomeLevel objects, so the shape is stable and
-- there is nothing to gain from deferring the shred.
--
-- Note this includes AGGREGATES — 'World', 'Euro area', 'Arab World' — which
-- the Lambda deliberately does not filter (ADR 0005: raw takes what the
-- source returns). They are identifiable by region_id = 'NA' and are
-- excluded in the dbt staging model, not here.

CREATE TABLE IF NOT EXISTS RAW.WORLDBANK_COUNTRIES (
    country_id        VARCHAR,   -- ISO3
    iso2_code         VARCHAR,
    country_name      VARCHAR,
    region_id         VARCHAR,   -- 'NA' marks an aggregate, not a country
    region_name       VARCHAR,
    admin_region_id   VARCHAR,
    income_level_id   VARCHAR,
    income_level_name VARCHAR,
    lending_type_id   VARCHAR,
    capital_city      VARCHAR,
    longitude         VARCHAR,   -- the API returns these as strings
    latitude          VARCHAR,
    source_system     VARCHAR,
    ingested_at       TIMESTAMP_TZ,
    source_file       VARCHAR,
    loaded_at         TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- The Lambda overwrites the same key on every run (ADR 0010's reference-data
-- exception), so reference data is replaced wholesale rather than appended.
-- TRUNCATE + FORCE mirrors that: the table reflects the current pull, not an
-- accumulation of every pull.
TRUNCATE TABLE RAW.WORLDBANK_COUNTRIES;

COPY INTO RAW.WORLDBANK_COUNTRIES (
    country_id, iso2_code, country_name, region_id, region_name,
    admin_region_id, income_level_id, income_level_name, lending_type_id,
    capital_city, longitude, latitude, source_system, ingested_at, source_file
)
FROM (
    SELECT
        $1:country_id::VARCHAR,
        $1:iso2_code::VARCHAR,
        $1:country_name::VARCHAR,
        $1:region_id::VARCHAR,
        $1:region_name::VARCHAR,
        $1:admin_region_id::VARCHAR,
        $1:income_level_id::VARCHAR,
        $1:income_level_name::VARCHAR,
        $1:lending_type_id::VARCHAR,
        $1:capital_city::VARCHAR,
        $1:longitude::VARCHAR,
        $1:latitude::VARCHAR,
        $1:source_system::VARCHAR,
        $1:ingested_at::TIMESTAMP_TZ,
        METADATA$FILENAME
    FROM @RAW.STG_WORLDBANK
)
PATTERN = '.*countries/.*[.]json'
FILE_FORMAT = (TYPE = JSON)
FORCE = TRUE
ON_ERROR = 'ABORT_STATEMENT';

-- --------------------------------------------------------------------------
-- Indicators (GDP and population)
-- --------------------------------------------------------------------------
-- One table for both. They have identical shape and differ only by
-- indicator_id, so separate tables would mean duplicated DDL and a union in
-- every downstream model.

CREATE TABLE IF NOT EXISTS RAW.WORLDBANK_INDICATORS (
    country_id      VARCHAR,
    country_name    VARCHAR,
    indicator_id    VARCHAR,   -- NY.GDP.MKTP.CD or SP.POP.TOTL
    indicator_name  VARCHAR,
    year            VARCHAR,
    value           FLOAT,     -- null where the World Bank has no figure
    source_system   VARCHAR,
    ingested_at     TIMESTAMP_TZ,
    source_file     VARCHAR,
    loaded_at       TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

TRUNCATE TABLE RAW.WORLDBANK_INDICATORS;

COPY INTO RAW.WORLDBANK_INDICATORS (
    country_id, country_name, indicator_id, indicator_name,
    year, value, source_system, ingested_at, source_file
)
FROM (
    SELECT
        $1:country_id::VARCHAR,
        $1:country_name::VARCHAR,
        $1:indicator_id::VARCHAR,
        $1:indicator_name::VARCHAR,
        $1:year::VARCHAR,
        $1:value::FLOAT,
        $1:source_system::VARCHAR,
        $1:ingested_at::TIMESTAMP_TZ,
        METADATA$FILENAME
    FROM @RAW.STG_WORLDBANK
)
PATTERN = '.*(gdp|population)/.*[.]json'
FILE_FORMAT = (TYPE = JSON)
FORCE = TRUE
ON_ERROR = 'ABORT_STATEMENT';

-- ==========================================================================
-- Verify
-- ==========================================================================

-- ~300 rows, of which roughly 50 are aggregates rather than countries.
SELECT
    COUNT(*)                                              AS total_rows,
    COUNT_IF(region_id = 'NA')                            AS aggregates,
    COUNT_IF(region_id <> 'NA' OR region_id IS NULL)      AS actual_countries
FROM RAW.WORLDBANK_COUNTRIES;

-- Two indicators, one year each. Null values are expected and normal —
-- the World Bank has no figure for every country-year.
SELECT
    indicator_id,
    year,
    COUNT(*)              AS rows,
    COUNT(value)          AS non_null_values,
    COUNT(*) - COUNT(value) AS null_values
FROM RAW.WORLDBANK_INDICATORS
GROUP BY 1, 2
ORDER BY 1;

-- The join that matters. Every mappable country in the retail data should
-- resolve to a World Bank country. Anything appearing here is a mapping
-- problem to fix before building dim_country.
SELECT
    m.retail_country,
    m.worldbank_country_id,
    m.mapping_type,
    c.country_name AS worldbank_name
FROM STAGING.COUNTRY_MAPPING m
LEFT JOIN RAW.WORLDBANK_COUNTRIES c
    ON c.country_id = m.worldbank_country_id
WHERE m.mapping_type <> 'unmappable'
  AND c.country_id IS NULL;
