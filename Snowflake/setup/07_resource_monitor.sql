-- 07 — Resource monitor and the readonly role
--
-- Run as ACCOUNTADMIN.
--
-- The resource monitor is the control that was missing. Snowflake bills per
-- second of warehouse runtime, and nothing in the account currently stops a
-- runaway query or a stuck dbt run from consuming the whole trial credit.
--
-- AUTO_SUSPEND = 60 limits idle burn but does nothing about a query that is
-- genuinely running. This does.

USE ROLE ACCOUNTADMIN;

-- ==========================================================================
-- Resource monitor
-- ==========================================================================
--
-- The trial gives $400 of credit. This project should use a tiny fraction of
-- that, so a 10-credit monthly cap is generous and still catches a runaway
-- long before it matters.
--
-- Triggers, in order of severity:
--   50%  notify   — something is using more than expected, look at it
--   75%  notify   — getting serious
--   90%  SUSPEND  — stop accepting new queries, let running ones finish
--  100%  SUSPEND_IMMEDIATE — kill running queries
--
-- SUSPEND before SUSPEND_IMMEDIATE matters: it gives a chance to intervene
-- without killing a query mid-write. SUSPEND_IMMEDIATE is the backstop.

CREATE RESOURCE MONITOR IF NOT EXISTS RETAIL_MONITOR
  WITH
    CREDIT_QUOTA = 10
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50  PERCENT DO NOTIFY
    ON 75  PERCENT DO NOTIFY
    ON 90  PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE RETAIL_WH SET RESOURCE_MONITOR = RETAIL_MONITOR;

-- Notifications go to account administrators who have enabled them in their
-- Snowsight notification preferences. Worth checking that is on — a monitor
-- whose notifications nobody receives only tells you something at 90%.
SHOW RESOURCE MONITORS;

-- ==========================================================================
-- Statement timeout — a second, independent limit
-- ==========================================================================
--
-- The resource monitor caps total spend; this caps any single query. A dbt
-- model with an accidental cross join would otherwise run until the monthly
-- quota noticed.
--
-- 30 minutes is far longer than anything here legitimately needs — the
-- largest month is 40k rows — so this only fires on something genuinely
-- wrong.

ALTER WAREHOUSE RETAIL_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;

-- Queued queries should not pile up either. If four threads are busy and
-- more arrive, fail rather than queue indefinitely.
ALTER WAREHOUSE RETAIL_WH SET STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 300;

-- ==========================================================================
-- RETAIL_READER — the role ADR 0004 describes but that was never created
-- ==========================================================================
--
-- Documented in the ADR as existing for Superset and ad-hoc querying. It did
-- not exist. A documented role that is absent is worse than not documenting
-- it, because the document is what someone reviews.
--
-- Marts only. Nothing downstream of the warehouse needs raw or staging, and
-- granting them would mean a BI tool could query uncleaned data and present
-- it as fact.

CREATE ROLE IF NOT EXISTS RETAIL_READER
  COMMENT = 'Read-only on marts. Superset and manual querying.';

GRANT USAGE ON WAREHOUSE RETAIL_WH TO ROLE RETAIL_READER;

GRANT USAGE ON DATABASE RETAIL_DEV TO ROLE RETAIL_READER;
GRANT USAGE ON SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL TABLES  IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS   IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA RETAIL_DEV.MARTS TO ROLE RETAIL_READER;

GRANT USAGE ON DATABASE RETAIL_PROD TO ROLE RETAIL_READER;
GRANT USAGE ON SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL TABLES  IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS   IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA RETAIL_PROD.MARTS TO ROLE RETAIL_READER;

-- Also grant OPS read — the reconciliation view is operational metadata that
-- a dashboard should be able to show. Pipeline health is exactly the kind of
-- thing worth putting in front of someone.
GRANT USAGE ON SCHEMA RETAIL_DEV.OPS  TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS    IN SCHEMA RETAIL_DEV.OPS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RETAIL_DEV.OPS TO ROLE RETAIL_READER;
GRANT USAGE ON SCHEMA RETAIL_PROD.OPS TO ROLE RETAIL_READER;
GRANT SELECT ON ALL VIEWS    IN SCHEMA RETAIL_PROD.OPS TO ROLE RETAIL_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA RETAIL_PROD.OPS TO ROLE RETAIL_READER;

-- ==========================================================================
-- Verify
-- ==========================================================================

SHOW RESOURCE MONITORS;
SHOW PARAMETERS LIKE 'STATEMENT%TIMEOUT%' IN WAREHOUSE RETAIL_WH;
SHOW GRANTS TO ROLE RETAIL_READER;

-- Credit consumption so far. Worth recording the number for the
-- cost/performance write-up — it is the Snowflake half of the story that
-- currently only has AWS figures.
SELECT
    DATE_TRUNC('day', START_TIME)      AS day,
    WAREHOUSE_NAME,
    SUM(CREDITS_USED)                  AS credits,
    COUNT(*)                           AS queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC;