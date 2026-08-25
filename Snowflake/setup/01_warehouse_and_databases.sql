-- 01 — Warehouse, databases, schemas
--
-- Run as ACCOUNTADMIN. Run once per account.
--
-- The structure is IDENTICAL across RETAIL_DEV and RETAIL_PROD. Same schema
-- names, same layout. That is deliberate: it means a dbt model that builds
-- in dev builds in prod without a single change, because the only thing that
-- differs between targets is which database is addressed.
--
-- Any divergence here — an extra schema in dev, a differently named one in
-- prod — is how "it worked in dev" stops meaning anything.

USE ROLE ACCOUNTADMIN;

-- --------------------------------------------------------------------------
-- Warehouse
-- --------------------------------------------------------------------------
-- One warehouse shared by both environments.
--
-- Separate warehouses per environment would give cleaner cost attribution,
-- but Snowflake bills per second of active time with a 60-second minimum, so
-- two warehouses means two 60-second minimums on any run touching both. For
-- a trial-window project that is the wrong trade. Cost is attributed via
-- QUERY_HISTORY by database instead.
--
-- AUTO_SUSPEND matters far more than WAREHOUSE_SIZE for cost. An idle XS
-- warehouse still bills until it suspends.

CREATE WAREHOUSE IF NOT EXISTS RETAIL_WH
  WAREHOUSE_SIZE       = 'XSMALL'
  AUTO_SUSPEND         = 60
  AUTO_RESUME          = TRUE
  INITIALLY_SUSPENDED  = TRUE
  COMMENT              = 'Shared warehouse for dev and prod dbt runs';

-- --------------------------------------------------------------------------
-- Databases
-- --------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS RETAIL_DEV
  COMMENT = 'Development. Subset of data. Freely rebuildable.';

CREATE DATABASE IF NOT EXISTS RETAIL_PROD
  COMMENT = 'Production. Full dataset.';

-- --------------------------------------------------------------------------
-- Schemas — same five in both, mirroring the S3 layer structure
-- --------------------------------------------------------------------------
--   RAW           what lands from S3, untransformed
--   STAGING       dbt: cleaned, typed, batch + stream unioned
--   INTERMEDIATE  dbt: reusable joins and derivations
--   MARTS         dbt: business-facing facts and dimensions
--   OPS           reconciliation audit records from the Glue job

CREATE SCHEMA IF NOT EXISTS RETAIL_DEV.RAW;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEV.STAGING;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEV.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEV.MARTS;
CREATE SCHEMA IF NOT EXISTS RETAIL_DEV.OPS;

CREATE SCHEMA IF NOT EXISTS RETAIL_PROD.RAW;
CREATE SCHEMA IF NOT EXISTS RETAIL_PROD.STAGING;
CREATE SCHEMA IF NOT EXISTS RETAIL_PROD.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS RETAIL_PROD.MARTS;
CREATE SCHEMA IF NOT EXISTS RETAIL_PROD.OPS;

-- Snowflake creates a PUBLIC schema in every new database. Unused here, and
-- an unused writable schema is somewhere for things to land by accident.
DROP SCHEMA IF EXISTS RETAIL_DEV.PUBLIC;
DROP SCHEMA IF EXISTS RETAIL_PROD.PUBLIC;

-- --------------------------------------------------------------------------
-- Verify
-- --------------------------------------------------------------------------
-- These two should return identical schema lists. If they do not, stop and
-- fix it before writing any dbt models.

SHOW SCHEMAS IN DATABASE RETAIL_DEV;
SHOW SCHEMAS IN DATABASE RETAIL_PROD;
