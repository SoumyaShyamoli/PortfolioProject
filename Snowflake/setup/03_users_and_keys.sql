-- 03 — Users, key registration, defaults
--
-- Run as ACCOUNTADMIN, after 02.
--
-- Two users, two key pairs, two roles. Per ADR 0010, separate keys are what
-- make "the prod key is never on disk" enforceable — with one shared key,
-- that rule collapses the moment a copy is kept locally for dev.

USE ROLE ACCOUNTADMIN;

-- --------------------------------------------------------------------------
-- Prod service user
-- --------------------------------------------------------------------------
-- TYPE = SERVICE means no password, no MFA, no UI login — key-pair only.
-- Snowflake enforces this at the account level, which is a stronger control
-- than remembering not to set a password.

CREATE USER IF NOT EXISTS RETAIL_PROD_USER
  TYPE                 = SERVICE
  DEFAULT_ROLE         = RETAIL_TRANSFORMER_PROD
  DEFAULT_WAREHOUSE    = RETAIL_WH
  DEFAULT_NAMESPACE    = RETAIL_PROD.STAGING
  COMMENT              = 'dbt production runs. Key from SSM at runtime, never on disk.';

GRANT ROLE RETAIL_TRANSFORMER_PROD TO USER RETAIL_PROD_USER;

-- Paste the PUBLIC key body only — strip the BEGIN/END lines and remove
-- newlines. From ~/.snowflake/rsa_key_prod.pub.
ALTER USER RETAIL_PROD_USER SET RSA_PUBLIC_KEY = '<PROD_PUBLIC_KEY_BODY>';

-- --------------------------------------------------------------------------
-- Dev user
-- --------------------------------------------------------------------------
-- NOTE: soumyadeep007 is also the human login for this account, so it holds
-- both ACCOUNTADMIN and the dev transformer role. That mixes human and
-- service identity, which cuts against the segregation applied everywhere
-- else on this platform (ADR 0004).
--
-- Accepted for dev on a solo project: creating a second user to run dbt
-- against a rebuildable database adds friction without changing what is at
-- risk. The line is drawn at prod, which has a dedicated service user with
-- no interactive login at all.
--
-- If a second person ever gets access, split this.

GRANT ROLE RETAIL_TRANSFORMER_DEV TO USER SOUMYADEEP007;

ALTER USER SOUMYADEEP007 SET
  DEFAULT_ROLE      = RETAIL_TRANSFORMER_DEV,
  DEFAULT_WAREHOUSE = RETAIL_WH,
  DEFAULT_NAMESPACE = RETAIL_DEV.STAGING;

-- From ~/.snowflake/rsa_key_dev.pub, same formatting rules as above.
ALTER USER SOUMYADEEP007 SET RSA_PUBLIC_KEY = '<DEV_PUBLIC_KEY_BODY>';

-- --------------------------------------------------------------------------
-- Verify
-- --------------------------------------------------------------------------
-- Both should show a value for RSA_PUBLIC_KEY_FP. Empty means the key did
-- not register — usually a formatting problem in the pasted body.

DESC USER RETAIL_PROD_USER;
DESC USER SOUMYADEEP007;

-- Confirm the default role took. dbt can override this, but a sensible
-- default means a forgotten config does not silently run as ACCOUNTADMIN.
SHOW GRANTS TO USER RETAIL_PROD_USER;
SHOW GRANTS TO USER SOUMYADEEP007;
