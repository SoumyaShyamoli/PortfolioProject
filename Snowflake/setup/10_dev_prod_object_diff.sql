-- 10 — dev vs prod object diff
--
-- Run each pair and compare the output by eye — this catches every
-- "exists in dev, never mirrored to prod" gap in one pass instead of
-- discovering them one Runtime Error at a time. Run as ACCOUNTADMIN so
-- nothing is hidden by a role's own limited grants.

USE ROLE ACCOUNTADMIN;

-- ==========================================================================
-- Schemas — confirm both databases have the same schema set
-- ==========================================================================

SHOW SCHEMAS IN DATABASE RETAIL_DEV;
SHOW SCHEMAS IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- Tables — every table in every schema, both databases
-- ==========================================================================

SHOW TABLES IN DATABASE RETAIL_DEV;
SHOW TABLES IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- Views
-- ==========================================================================

SHOW VIEWS IN DATABASE RETAIL_DEV;
SHOW VIEWS IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- Stages
-- ==========================================================================

SHOW STAGES IN DATABASE RETAIL_DEV;
SHOW STAGES IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- File formats (if any were created explicitly, beyond inline TYPE=... )
-- ==========================================================================

SHOW FILE FORMATS IN DATABASE RETAIL_DEV;
SHOW FILE FORMATS IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- Masking policies — relevant now that ADR 0016 is in progress
-- ==========================================================================

SHOW MASKING POLICIES IN DATABASE RETAIL_DEV;
SHOW MASKING POLICIES IN DATABASE RETAIL_PROD;

-- ==========================================================================
-- Role grants — the two gaps found tonight (service user role grant,
-- human user role grant) were both grant-related, not object-related.
-- Worth diffing these explicitly too.
-- ==========================================================================

SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_DEV;
SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_PROD;

SHOW GRANTS TO USER RETAIL_DEV_USER;
SHOW GRANTS TO USER RETAIL_PROD_USER;

SHOW GRANTS TO ROLE RETAIL_READER;

-- ==========================================================================
-- Row counts on every RAW table that should now hold real data — a table
-- can EXIST in both and still be empty in one, which none of the SHOW
-- commands above would catch.
-- ==========================================================================

SELECT 'dev'  AS env, 'RAW.ORDERS'               AS obj, COUNT(*) AS row_count FROM RETAIL_DEV.RAW.ORDERS
UNION ALL
SELECT 'prod', 'RAW.ORDERS',               COUNT(*) FROM RETAIL_PROD.RAW.ORDERS
UNION ALL
SELECT 'dev',  'RAW.WORLDBANK_COUNTRIES',  COUNT(*) FROM RETAIL_DEV.RAW.WORLDBANK_COUNTRIES
UNION ALL
SELECT 'prod', 'RAW.WORLDBANK_COUNTRIES',  COUNT(*) FROM RETAIL_PROD.RAW.WORLDBANK_COUNTRIES
UNION ALL
SELECT 'dev',  'RAW.WORLDBANK_INDICATORS', COUNT(*) FROM RETAIL_DEV.RAW.WORLDBANK_INDICATORS
UNION ALL
SELECT 'prod', 'RAW.WORLDBANK_INDICATORS', COUNT(*) FROM RETAIL_PROD.RAW.WORLDBANK_INDICATORS
UNION ALL
SELECT 'dev',  'STAGING.COUNTRY_MAPPING',  COUNT(*) FROM RETAIL_DEV.STAGING.COUNTRY_MAPPING
UNION ALL
SELECT 'prod', 'STAGING.COUNTRY_MAPPING',  COUNT(*) FROM RETAIL_PROD.STAGING.COUNTRY_MAPPING
ORDER BY 2, 1;
