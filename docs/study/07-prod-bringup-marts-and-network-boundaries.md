# Study Guide 07 — prod bring-up, marts, data exposure, and Airflow's real network boundaries

Picks up where 06 left off (the IAM permission chain for Airflow's DAG
deploy). Covers: standing up prod for the first time, building marts,
the full data-exposure audit, and the multi-day chase to understand
exactly what Airflow can and cannot reach from inside a NAT-less subnet
— arguably the single most technically dense debugging arc in this
project.

---

## Prod bring-up — "exists in dev" is not "exists in prod"

Prod had been provisioned by Terraform from the start, but almost
nothing had ever actually *run* against it. Every gap below surfaced
one command at a time, each producing a different, superficially
unrelated error — until a systematic diff made the pattern obvious.

### The gaps, in the order they were hit

1. **`STAGING.COUNTRY_MAPPING` did not exist** — a dbt *seed*, not raw
   S3 data. `dbt seed --target prod` had simply never been run.
2. **The Snowflake service user's role grant was missing** —
   `RETAIL_TRANSFORMER_PROD` existed but was never granted to
   `RETAIL_PROD_USER`. A **Snowflake-side** identity gap, not an AWS IAM
   one — different failure mode (`Role ... is not assigned to the
   executing user`), same underlying pattern.
3. **`OPS.GLUE_RECON_RAW` did not exist in prod** — a raw table fed by
   Glue's own audit output, never dbt-managed, easy to forget precisely
   because dbt can't create it and there's no automated reminder that
   it's missing.
4. **`RETAIL_READER`'s original grant was already too broad by the time
   marts existed** (see the data-exposure section below) — found during
   this same sweep, not a separate investigation.

### The fix that stopped the one-at-a-time discovery

```sql
-- Compare object listings across both databases in one pass, rather
-- than discovering gaps individually via runtime errors.
SHOW SCHEMAS IN DATABASE RETAIL_DEV;   SHOW SCHEMAS IN DATABASE RETAIL_PROD;
SHOW TABLES  IN DATABASE RETAIL_DEV;   SHOW TABLES  IN DATABASE RETAIL_PROD;
SHOW VIEWS   IN DATABASE RETAIL_DEV;   SHOW VIEWS   IN DATABASE RETAIL_PROD;
SHOW STAGES  IN DATABASE RETAIL_DEV;   SHOW STAGES  IN DATABASE RETAIL_PROD;
SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_DEV;
SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_PROD;
```

Row counts matter too — a table can exist in both and be empty in one,
which no `SHOW` command reveals:

```sql
SELECT 'dev' env, COUNT(*) FROM RETAIL_DEV.RAW.ORDERS
UNION ALL
SELECT 'prod', COUNT(*) FROM RETAIL_PROD.RAW.ORDERS;
```

**A real diffing technique worth remembering:** `SHOW GRANTS` output
isn't directly comparable across two calls. Capture both via
`RESULT_SCAN(LAST_QUERY_ID())` into temp tables, **normalize `DEV`→`PROD`
in object names first**, then diff — otherwise every environment-specific
name difference looks like a missing grant.

```sql
SHOW GRANTS TO ROLE RETAIL_TRANSFORMER_DEV;
CREATE OR REPLACE TEMPORARY TABLE _dev_grants AS
SELECT "privilege", "granted_on",
       REPLACE("name", 'RETAIL_DEV', 'RETAIL_PROD') AS normalized_name
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
-- repeat for prod without the REPLACE, then LEFT JOIN and filter WHERE prod IS NULL
```

**The actual lesson:** a 78-vs-66 grant count difference initially looked
alarming. The real diff showed every missing "grant" was `OWNERSHIP` on
an object that simply didn't exist yet — not a permissions gap at all.
Always check *what kind* of difference a count implies before assuming
the worst category of problem.

### A real key-management near-miss

```bash
aws ssm get-parameter --name /retail/prod/... > ~/.snowflake/rsa_key_prod.p8
```

This failed with `ParameterNotFound` — **but the `>` redirect had
already truncated the target file to zero bytes before the command even
ran.** Shell redirection happens at parse time, independent of whether
the command succeeds. The working prod key was gone, with no local
backup. Recovered by regenerating the key pair and re-registering the
public half in Snowflake — the private key itself is never recoverable
once lost; only the source of truth (SSM, or the paired Snowflake user)
being correct still lets you replace it.

**The lesson, worth internalizing:** never pipe/redirect a fetch command
directly over a file you don't already have a second copy of. Fetch to a
temp path first, verify it's non-empty, then move it into place.

---

## Marts — grain, dedup, and a real reconciliation gap closed

Full design: one date spine, three dimensions, one line-level fact, one
order-level fact, one monthly rollup.

### The dedup rule, and why it lives in exactly one place

```sql
-- fct_order_lines.sql — the ONLY place this filter appears
where duplicate_occurrence = 1
```

Every other mart builds on `fct_order_lines`, never re-filters
`stg_orders` directly. One filter, one place, everything downstream
inherits it correctly by construction rather than by convention.

### The reconciliation gap this closed

`ops.fct_pipeline_reconciliation` proves source → S3 → Snowflake →
staging agree. Nothing proved **staging → marts** agreed — specifically,
that the dedup step removed exactly the right rows. Two new singular
tests, same pattern as the existing recon tests (join two independently
derived aggregates, fail on disagreement), one layer further up:

```sql
-- assert_marts_dedup_reconciles.sql — row counts
-- assert_marts_revenue_reconciles.sql — dollar sums, catches value-level
-- bugs a row-count check alone would miss (a join that changes values
-- without changing row count, a rounding error introduced in the mart)
```

### A real data-quality finding, investigated rather than dismissed

`dbt_utils.accepted_range` on `dim_product.avg_unit_price` failed:

```
stock_code 'B', description 'Adjust bad debt', avg_unit_price -3687.35
```

Confirmed genuine — a bad-debt write-off adjustment code, not a real
product. **Fix chosen deliberately: exclude the known code from the test
condition, not widen the range to hide it:**

```yaml
tests:
  - dbt_utils.accepted_range:
      min_value: 0
      config:
        where: "stock_code != 'B'"
```

Same discipline as ADR 0012's duplicate-rate finding: a real anomaly gets
named and excluded explicitly, never absorbed into a looser bound that
would also hide a genuinely new problem later.

---

## ADR 0016 — data exposure across the whole platform, not just one column

A request to mask `customer_id` in Snowflake was deliberately widened to
"where else could row-level customer data leak, across every layer."

### The finding that mattered more than the original ask

Auditing `RETAIL_READER`'s actual grants (not just adding the mask)
found: the role's original grant used `ALL TABLES`/`FUTURE TABLES` on
the whole `MARTS` schema, written *before* `fct_order_lines` existed.
Once that table was built, the dashboard role silently gained access to
**line-level transaction detail** — a bigger exposure than the masked
column itself, and nobody re-approved the expansion when it happened.

**The lesson:** a broad `FUTURE TABLES` grant is a standing risk that
silently widens scope every time a new object lands in that schema,
with no re-approval step. Fixed by revoking the broad grant and
explicitly listing only the intended rollup objects.

### The masking policy, and a real type-mismatch bug

```
COLUMN data type VARCHAR(16777216) does not match with masking policy data type FIXED.
```

The policy was written assuming `customer_id` was `NUMBER`; it's
actually `VARCHAR` end to end (never cast anywhere in the pipeline).
Snowflake requires exact type match between a masking policy and its
target column. Fixed by rewriting the policy as `VARCHAR -> VARCHAR`,
using `HASH()` wrapped in `TO_VARCHAR()` for masked roles.

```sql
CREATE OR REPLACE MASKING POLICY MASK_CUSTOMER_ID AS
  (val VARCHAR) RETURNS VARCHAR ->
    CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN', 'RETAIL_TRANSFORMER_DEV')
         THEN val
         ELSE TO_VARCHAR(ABS(HASH(val, 'retail-platform-salt-dev')))
    END;
```

**Hash, not null** — a masked role can still `GROUP BY`/`COUNT DISTINCT`
for aggregate analysis without ever seeing the real ID. Separate salts
per environment so a dev hash can never be matched against a prod hash.

### The known, accepted limitation — stated, not solved

Country combined with a hashed customer ID is still a quasi-identifier
for low-volume countries (a handful of Online Retail II countries have
very few customers). A masked role could infer "this hash = the one
customer from Iceland" without ever seeing the real ID. Documented as an
accepted gap, same as every other entry in ADR 0013 — a correct fix
(suppression for low-volume combinations) is disproportionate
engineering for a public research dataset.

---

## Airflow's real network boundary — three distinct gaps, one pattern

Validating the DAG end to end surfaced three separate "something inside
this subnet needs to reach X" problems. Each looked like a different
kind of bug at first; each was actually the same category.

### Gap 1 — SequentialExecutor spawns tasks via a bare command name

```
FileNotFoundError: [Errno 2] No such file or directory: 'airflow'
```

The scheduler itself started fine (`ExecStart` used a full path). But
`sequential_executor.py`'s `sync()` spawns each task by calling
**`subprocess.check_call(['airflow', 'tasks', 'run', ...])`** — a bare
command name, resolved via `PATH`. The systemd unit never put the
venv's `bin` directory on `PATH`, so every task launch failed, crashing
the scheduler, which `Restart=on-failure` silently restarted — leaving
every queued task orphaned with no error visible anywhere except
`journalctl`.

```ini
Environment=PATH=/opt/airflow/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**The lesson:** "the scheduler is running" and "the scheduler can
execute tasks" are different claims. A crash-loop disguised as a stuck
`queued` task is a genuinely hard failure mode to diagnose from the UI
alone — `journalctl -u airflow-scheduler` was what actually revealed it,
not anything in Airflow's own logs or UI.

### Gap 2 — the first in-subnet call to a *different* AWS API

Once Gap 1 was fixed, `trigger_glue` ran for **191 seconds** before
failing — a real Python exception this time, not a subprocess crash.
The stack trace showed a hang at `sock.connect()` — a raw TCP attempt
that never completed, calling `glue.eu-west-2.amazonaws.com`.

**Why this hadn't surfaced before:** every previous Glue trigger in this
project came from *outside* the VPC — a laptop, or a GitHub Actions
runner, both with full internet access. This was the first time
something *inside* the NAT-less subnet called the Glue control-plane
API directly. SSM already had interface endpoints (needed to reach
Airflow at all); Glue never did, because nothing had needed it to.

```hcl
resource "aws_vpc_endpoint" "glue" {
  service_name      = "com.amazonaws.${var.region}.glue"
  vpc_endpoint_type = "Interface"
  # same toggle, same security group as the existing SSM endpoints
}
```

Fixed; confirmed by the next run failing **instantly** (a config error,
not a hang) rather than after minutes — proof the network path itself
was now real.

### Gap 3 — Snowflake is not an AWS service, and this account can't PrivateLink to it

`load_snowflake_raw` hit the identical `sock.connect()` timeout pattern,
this time against `brtnpnx-ih35235.snowflakecomputing.com`. **No
`com.amazonaws.*` interface endpoint exists for Snowflake — it isn't an
AWS service.** The only AWS-native fix is AWS PrivateLink via a VPC
Endpoint Service Snowflake operates.

```sql
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
-- returned real, populated config — misleadingly suggesting availability
```

Attempting the endpoint failed:

```
InvalidServiceName: The Vpc Endpoint Service '...' does not exist
```

**AWS reports "does not exist" rather than "access denied" for
third-party endpoint services you're not authorized against** —
deliberately vague, standard behavior, not a bug. The real answer:

```sql
SHOW PARAMETERS LIKE 'ENABLE_INTERNAL_STAGES_PRIVATELINK' IN ACCOUNT;
-- false
```

And confirmed via Snowflake's own docs: **PrivateLink requires Business
Critical edition or higher** — an edition restriction, not a pending
activation. `SYSTEM$GET_PRIVATELINK_CONFIG()` returning populated data
does **not** mean PrivateLink is actually usable on your account — it
describes what *would* be configured if the edition supported it. A
genuinely misleading signal, worth remembering: check the parameter and
the edition requirement, not just whether the config function returns
something.

**The decision, made deliberately rather than forced:** no NAT gateway
added. The DAG's scope was redefined instead — Airflow orchestrates only
what it can actually reach (Glue trigger/wait); the Snowflake/dbt half
moved to a scheduled GitHub Actions job (`schedule: cron: '0 * * * *'`),
which runs on infrastructure with unrestricted internet access and was
already proven to work correctly.

```yaml
on:
  schedule:
    - cron: '0 * * * *'
# existing job-level `if:` conditions (build: event_name != 'pull_request')
# already satisfy this correctly — schedule events aren't pull_request
# events, so no job-level change was needed, only the trigger addition.
```

**The reframe worth being able to state cleanly:** this is not a
downgrade or an abandoned plan. Airflow does the part it's positioned
to do well (AWS-native orchestration); CI does the part it's positioned
to do well (anything needing real internet access). Duplicating a
working, internet-connected system inside a network-constrained one
just to keep "one tool orchestrates everything" would have been the
worse design, not the better one.

---

## The pattern across all three gaps, worth stating once, clearly

**"Can this code run" and "can this code reach the network it needs" are
different questions, and a NAT-less subnet makes the second one a live
concern for literally everything, one API/hostname at a time.** Every
gap here was found only when something *new* tried to reach *outside*
the subnet for the first time — SSM (to be reachable at all), Glue (the
first in-subnet API call), Snowflake (the first non-AWS destination).
There was no way to find all three in advance by review; each was only
discoverable by actually running the thing and watching precisely where
it hung or failed.

---

## `tfsec` — first real run, and what a "44 findings" number actually means

```bash
tfsec .
# 174 passed, 44 potential problems — 3 critical, 26 high, 11 medium, 4 low
```

**Two fixed outright, cheap and real:**

- IMDSv2 not enforced (`metadata_options { http_tokens = "required" }`)
  — closes a known SSRF-to-credential-theft pattern, zero functional
  impact, applies to a running instance without replacement.
- SNS topics unencrypted — unlike S3's KMS tradeoff, SNS's AWS-managed
  key is free (`kms_master_key_id = "alias/aws/sns"`), so there's no
  reason to accept this one the way S3's CMK question is accepted.

**Everything else triaged individually, not as a block** — each finding
got either a pointer to existing ADR reasoning (KMS on `Resource = "*"`
→ ADR 0010's `ViaService` argument; S3 CMK → ADR 0013's existing
section) or a fresh "accepted, here's why, here's the revisit trigger"
entry, same discipline as every other line in ADR 0013.

**The one genuinely interesting judgment call:** security-group egress
to `0.0.0.0/0` flagged as CRITICAL by tfsec, but confirmed to be
egress-only, port-443-only — the exact mechanism by which HTTPS reaches
AWS/Snowflake/PyPI at all. A static scanner cannot distinguish "wide
open" from "wide open but harmless by construction" — that judgment
needs a human reading the actual rule, not trusting the severity label
alone.

**Also worth knowing:** tfsec itself was deprecated in May 2025 (merged
into Trivy), receiving no new rules since. This triage reflects a frozen
ruleset's view — a real limitation, stated once rather than caveated on
every individual finding.
