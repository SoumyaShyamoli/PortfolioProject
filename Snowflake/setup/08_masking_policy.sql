-- 08 — customer_id masking policy, dev and prod
--
-- Applied at the MART layer only (dim_customer, fct_order_lines) — not
-- staging or raw. A policy on staging/raw would also mask customer_id for
-- RETAIL_TRANSFORMER_DEV/PROD, which legitimately needs the real value
-- during model builds (joins, RFM calculations in dim_customer.sql all
-- operate on the true customer_id).
--
-- Hash, not null-out: a masked role can still GROUP BY / COUNT DISTINCT
-- customer_id for aggregate analysis (customer counts, cohort sizes)
-- without ever seeing the real identifier. Full null-out would break
-- RETAIL_READER's actual use case (Superset dashboards that legitimately
-- need "how many distinct customers", not "which specific customer").
--
-- KNOWN LIMITATION, not fixed here (see ADR 0016): country combined with a
-- hashed customer_id is still a quasi-identifier for low-volume countries
-- — a masked role could infer "this hash = the one customer from Iceland"
-- without ever seeing the real ID. Documented as accepted, not solved.

USE ROLE ACCOUNTADMIN;
USE DATABASE RETAIL_DEV;

CREATE MASKING POLICY IF NOT EXISTS STAGING.MASK_CUSTOMER_ID AS
  (val NUMBER) RETURNS NUMBER ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'RETAIL_TRANSFORMER_DEV') THEN val
      ELSE ABS(HASH(val, 'retail-platform-salt-dev'))  -- deterministic, joinable, not reversible to the real ID
    END;

ALTER TABLE RETAIL_DEV.MARTS.DIM_CUSTOMER
  MODIFY COLUMN customer_id
  SET MASKING POLICY STAGING.MASK_CUSTOMER_ID;

ALTER TABLE RETAIL_DEV.MARTS.FCT_ORDER_LINES
  MODIFY COLUMN customer_id
  SET MASKING POLICY STAGING.MASK_CUSTOMER_ID;

-- Repeat for prod, separate salt so a dev-side hash can never be matched
-- against a prod-side hash even if both were somehow exposed together.

USE DATABASE RETAIL_PROD;

CREATE MASKING POLICY IF NOT EXISTS STAGING.MASK_CUSTOMER_ID AS
  (val NUMBER) RETURNS NUMBER ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'RETAIL_TRANSFORMER_PROD') THEN val
      ELSE ABS(HASH(val, 'retail-platform-salt-prod'))
    END;

ALTER TABLE RETAIL_PROD.MARTS.DIM_CUSTOMER
  MODIFY COLUMN customer_id
  SET MASKING POLICY STAGING.MASK_CUSTOMER_ID;

ALTER TABLE RETAIL_PROD.MARTS.FCT_ORDER_LINES
  MODIFY COLUMN customer_id
  SET MASKING POLICY STAGING.MASK_CUSTOMER_ID;

-- ==========================================================================
-- Verify — run as RETAIL_READER (or any role other than ACCOUNTADMIN /
-- the transformer roles) to confirm masking is active.
-- ==========================================================================
-- USE ROLE RETAIL_READER;
-- SELECT customer_id FROM RETAIL_DEV.MARTS.DIM_CUSTOMER LIMIT 5;
-- Expect: large hashed integers, not the original small customer IDs.

-- And as the transformer role, to confirm it still sees real values:
-- USE ROLE RETAIL_TRANSFORMER_DEV;
-- SELECT customer_id FROM RETAIL_DEV.MARTS.DIM_CUSTOMER LIMIT 5;
-- Expect: real customer IDs, unchanged.
