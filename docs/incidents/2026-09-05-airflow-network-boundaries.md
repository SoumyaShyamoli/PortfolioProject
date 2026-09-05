# Incident — Airflow's real network boundary, found the hard way

- **Date:** 2026-09-05
- **Related:** ADR 0003 (both amendments), ADR 0014 (all four amendments)
- **Status:** Resolved — not by fixing the network, but by correctly
  scoping what Airflow is responsible for.

## Summary

Validating the DAG end to end surfaced three separate, genuinely
distinct failures, each one layer deeper than the last: a scheduler bug
that looked like a stuck task, a missing AWS-native network route, and
finally a non-AWS destination this platform's no-NAT design was never
going to be able to reach without a cost tradeoff it had deliberately
avoided. The eventual resolution was architectural, not a patch —
Airflow's scope was redefined to match what it can actually reach.

## Failure 1 — a crash-looping scheduler, disguised as a stuck task

**Symptom:** every DAG task sat in `queued` indefinitely. The UI showed
`running`/`queued` states that never progressed, with no error visible
anywhere in the interface.

**Cause:** the scheduler process itself started fine (`ExecStart` used a
full path to the venv's `airflow` binary). But
`sequential_executor.py`'s `sync()` method spawns each task by calling
`subprocess.check_call(['airflow', 'tasks', 'run', ...])` — a **bare
command name**, resolved via the process's `PATH`. The systemd unit
never put the venv's `bin` directory on `PATH`. Every task launch
attempt failed with `FileNotFoundError: 'airflow'`, which crashed the
scheduler; `Restart=on-failure` silently restarted it every time,
leaving every queued task permanently orphaned with no error surfaced
in Airflow's own logs or UI — only `journalctl -u airflow-scheduler`
revealed the actual traceback.

**Fix:**

```ini
Environment=PATH=/opt/airflow/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Added to both systemd units, and to `airflow_bootstrap.sh.tpl` so future
instances get this from first boot.

**The lesson:** "the scheduler is active" and "the scheduler can
successfully execute a task" are different claims that look identical
from `systemctl status` and the Airflow UI alike. The actual failure was
only visible one layer down, in the OS's own service log.

## Failure 2 — the first in-subnet call to a second AWS API

**Symptom:** once Failure 1 was fixed, `trigger_glue` ran for over three
minutes before failing — a genuine Python exception this time, not a
process crash.

**Cause:** the stack trace showed a hang at `sock.connect()` — a raw TCP
connection attempt to `glue.eu-west-2.amazonaws.com` that never
completed. This was the first time anything running *inside* the
private, NAT-less subnet (ADR 0003) had called the Glue control-plane
API directly. Every previous Glue trigger in this project's history came
from outside the VPC entirely — a laptop, or a GitHub Actions runner,
both with unrestricted internet access. SSM already had interface
endpoints (needed for Airflow to be reachable at all); Glue never did,
because nothing had needed it to until this exact task ran.

**Fix:** a `com.amazonaws.eu-west-2.glue` interface endpoint, same
toggle and security group as the existing SSM endpoints. Confirmed
working when the next attempt failed **instantly** — a real
configuration error (missing DAG-trigger conf), not a network hang —
proof the connection itself was now genuine.

## Failure 3 — Snowflake is not an AWS service, and PrivateLink is not available on this account's edition

**Symptom:** `load_snowflake_raw` hit the identical `sock.connect()`
timeout pattern, this time against
`brtnpnx-ih35235.snowflakecomputing.com`.

**Cause, investigated in stages:**

1. No `com.amazonaws.*` interface endpoint exists for Snowflake — it
   isn't an AWS service, so the fix that worked for Glue structurally
   cannot apply here.
2. The only AWS-native alternative is AWS PrivateLink, via a VPC
   Endpoint Service Snowflake itself operates.
   `SYSTEM$GET_PRIVATELINK_CONFIG()` returned real, populated
   configuration data — which was **misleading**: this function
   describes what PrivateLink *would* look like if the account's
   edition supported it, not whether it's actually usable.
3. Attempting to create the endpoint failed:
   `InvalidServiceName: ... does not exist` — AWS's deliberately vague
   response for a third-party endpoint service the requesting account
   isn't authorized against, rather than a clearer access-denied
   message.
4. `SHOW PARAMETERS LIKE 'ENABLE_INTERNAL_STAGES_PRIVATELINK'` returned
   `false`, and Snowflake's own documentation confirmed why:
   **PrivateLink requires Business Critical edition or higher.** This
   account is on a lower tier. Not a pending-activation state — an
   edition restriction with no support-ticket path around it short of
   an account upgrade.

**No fix applied.** The only remaining AWS-native options were a NAT
gateway (~£30/month, the exact cost ADR 0003 originally chose to avoid)
or moving the instances to a public subnet (a larger architectural
change, and one that weakens the "nothing publicly addressable" design
this platform has maintained throughout). Neither was adopted.

## The resolution — redefine scope, don't force a network fix

`retail_pipeline.py`'s scope was reduced to what these instances can
actually reach: `fetch_snowflake_key >> trigger_glue >> wait_for_glue`.
Everything downstream — the Snowflake load, staging, recon, marts —
already had a working, internet-connected execution path:
`dbt-ci.yml`'s `build`/`build-prod` jobs. A `schedule` trigger
(`cron: '0 * * * *'`) was added so this runs automatically, hourly,
without needing Airflow to reach Snowflake at all.

This is not a workaround adopted for lack of a better option. Airflow
orchestrates the part it's actually positioned to do well; CI does the
part it's positioned to do well. Duplicating a proven, working,
internet-connected system inside a network-constrained instance, purely
to preserve "one tool does everything," would have been the worse
design.

## Why this is worth keeping, not just fixing and moving on

All three failures share one root cause, expressed three different
ways: **"can this code run" and "can this code reach the network it
needs" are different questions**, and a NAT-less private subnet makes
the second one a live, undiscoverable-by-review concern for every new
destination code tries to reach. None of these three gaps were findable
by reading the Terraform or the DAG code in advance — each was only
discoverable by actually running the thing and watching precisely where
and how it hung. The eventual fix for the third gap wasn't a technical
one at all; it was recognizing that the platform's own architecture
(no NAT, by deliberate cost choice) had a real, load-bearing consequence
that needed to shape what Airflow was asked to do, rather than being
treated as an obstacle to route around at any cost.
