-- 09 — RETAIL_READER grant audit
--
-- Checks whether RETAIL_READER (created in 07_resource_monitor.sql for
-- Superset/dashboard use) currently has access to line-level fact tables,
-- which is a bigger exposure than any single column mask — a dashboard
-- role seeing individual transaction rows is more data than a BI tool
-- legitimately needs, regardless of whether customer_id is masked on them.

SHOW GRANTS TO ROLE RETAIL_READER;

-- If FCT_ORDER_LINES (line-level, most granular) appears in that list,
-- revoke it — RETAIL_READER should see rollups (FCT_ORDERS,
-- FCT_REVENUE_MONTHLY, the dimensions) but not raw line-level detail.
-- Uncomment and run if the SHOW GRANTS output above includes it:

-- REVOKE SELECT ON TABLE RETAIL_DEV.MARTS.FCT_ORDER_LINES FROM ROLE RETAIL_READER;
-- REVOKE SELECT ON TABLE RETAIL_PROD.MARTS.FCT_ORDER_LINES FROM ROLE RETAIL_READER;

-- The original 07_resource_monitor.sql grant was SELECT on all tables/views
-- in MARTS via ALL TABLES / FUTURE TABLES — which means it DOES currently
-- include FCT_ORDER_LINES. This was written before fct_order_lines existed
-- (marts weren't built yet at that point) and was never revisited once
-- they were. The grant should be narrowed to specific rollup objects
-- rather than "everything in the schema" — see the fix below.

-- Narrower fix: revoke the broad schema-level grant, grant explicitly to
-- only the rollup-level objects.
REVOKE SELECT ON ALL TABLES IN SCHEMA RETAIL_DEV.MARTS FROM ROLE RETAIL_READER;
REVOKE SELECT ON FUTURE TABLES IN SCHEMA RETAIL_DEV.MARTS FROM ROLE RETAIL_READER;

GRANT SELECT ON TABLE RETAIL_DEV.MARTS.FCT_ORDERS           TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_DEV.MARTS.FCT_REVENUE_MONTHLY  TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_DEV.MARTS.DIM_CUSTOMER         TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_DEV.MARTS.DIM_PRODUCT          TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_DEV.MARTS.DIM_COUNTRY          TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_DEV.MARTS.DIM_DATE             TO ROLE RETAIL_READER;
-- Deliberately NOT granting FCT_ORDER_LINES — line-level detail, not a
-- dashboard's job to expose row by row.

-- Repeat for prod once the same objects exist there.
REVOKE SELECT ON ALL TABLES IN SCHEMA RETAIL_PROD.MARTS FROM ROLE RETAIL_READER;
REVOKE SELECT ON FUTURE TABLES IN SCHEMA RETAIL_PROD.MARTS FROM ROLE RETAIL_READER;

GRANT SELECT ON TABLE RETAIL_PROD.MARTS.FCT_ORDERS           TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_PROD.MARTS.FCT_REVENUE_MONTHLY  TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_PROD.MARTS.DIM_CUSTOMER         TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_PROD.MARTS.DIM_PRODUCT          TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_PROD.MARTS.DIM_COUNTRY          TO ROLE RETAIL_READER;
GRANT SELECT ON TABLE RETAIL_PROD.MARTS.DIM_DATE             TO ROLE RETAIL_READER;

SHOW GRANTS TO ROLE RETAIL_READER;
