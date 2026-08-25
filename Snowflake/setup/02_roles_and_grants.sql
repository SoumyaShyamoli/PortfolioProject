-- 02 — Roles and grants
--
-- Run as ACCOUNTADMIN, after 01.
--
-- Two transformer roles with IDENTICAL capabilities, scoped to different
-- databases. Same principle as the AWS pipeline execution roles: the role
-- shape is the same, the blast radius differs.
--
-- Identical capability matters for the dev-to-prod guarantee. If the prod
-- role could do something the dev role could not, a model could pass in dev
-- and fail in prod on a permission error. If dev could do MORE than prod,
-- worse — the failure only appears after merge.

USE ROLE ACCOUNTADMIN;

-- --------------------------------------------------------------------------
-- Roles
-- --------------------------------------------------------------------------

CREATE ROLE IF NOT EXISTS RETAIL_TRANSFORMER_DEV
  COMMENT = 'dbt transformations against RETAIL_DEV';

CREATE ROLE IF NOT EXISTS RETAIL_TRANSFORMER_PROD
  COMMENT = 'dbt transformations against RETAIL_PROD';

-- Read-only role for Superset and ad-hoc inspection. Marts only — nothing
-- downstream of the warehouse needs to see raw or staging.
CREATE ROLE IF NOT EXISTS RETAIL_READER
  COMMENT = 'Read-only on marts. Superset and manual querying.';

-- --------------------------------------------------------------------------
-- Warehouse access
-- --------------------------------------------------------------------------

GRANT USAGE ON WAREHOUSE RETAIL_WH TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT USAGE ON WAREHOUSE RETAIL_WH TO ROLE RETAIL_TRANSFORMER_PROD;
GRANT USAGE ON WAREHOUSE RETAIL_WH TO ROLE RETAIL_READER;

-- --------------------------------------------------------------------------
-- DEV transformer — full control of RETAIL_DEV, nothing in RETAIL_PROD
-- --------------------------------------------------------------------------
-- FUTURE grants matter: dbt creates tables and views that do not exist yet.
-- Without them, every new model would need a manual grant.

GRANT USAGE ON DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT
  ON ALL SCHEMAS IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT
  ON FUTURE SCHEMAS IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;

GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON ALL TABLES IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON FUTURE TABLES IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;

GRANT SELECT ON ALL VIEWS IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT SELECT ON FUTURE VIEWS IN DATABASE RETAIL_DEV TO ROLE RETAIL_TRANSFORMER_DEV;

-- --------------------------------------------------------------------------
-- PROD transformer — same grants, RETAIL_PROD only
-- --------------------------------------------------------------------------
-- Deliberately identical to the block above except for the database name.
-- Keep them that way. Any difference is a dev/prod divergence waiting to
-- surface as a permission error after merge.

GRANT USAGE ON DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT
  ON ALL SCHEMAS IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE STAGE, CREATE FILE FORMAT
  ON FUTURE SCHEMAS IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;

GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON ALL TABLES IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
  ON FUTURE TABLES IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;

GRANT SELECT ON ALL VIEWS IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;
GRANT SELECT ON FUTURE VIEWS IN DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;

-- --------------------------------------------------------------------------
-- Reader — marts only, both environments
-- --------------------------------------------------------------------------

GRANT USAGE ON DATABASE RETAIL_DEV TO ROLE RETAIL_READER;
GRANT USAGE ON SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;

GRANT USAGE ON DATABASE RETAIL_PROD TO ROLE RETAIL_READER;
GRANT USAGE ON SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;

-- --------------------------------------------------------------------------
-- Verify the isolation actually holds
-- --------------------------------------------------------------------------
-- The point of two roles is that neither can reach the other's database.
-- Worth proving rather than assuming.
--
--   USE ROLE RETAIL_TRANSFORMER_DEV;
--   SELECT COUNT(*) FROM RETAIL_PROD.MARTS.FCT_ORDERS;   -- must fail
--
-- If that succeeds, a grant has leaked somewhere and the separation is
-- decorative.

SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_DEV;
SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_PROD;
