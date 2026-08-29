# ADR 0014 — Airflow on two small EC2 instances, stopped between uses

- **Status:** Accepted
- **Date:** 2026-08-26

## Context

The platform needed an orchestrator to chain Glue → Snowflake load → dbt
staging → a reconciliation gate → dbt marts, and to email a run status
report regardless of outcome. Three hosting options were considered.

**MWAA** was ruled out in the PRD on cost (~£250/month) before this decision
was reached.

**Local Docker Compose**, for both dev and prod, was the first choice —
free, and it mirrors how the Snowflake dev key is handled (a local
convenience layered on a real source of truth). It was rejected once the
CI implication was worked through: GitHub Actions can reach AWS via OIDC,
but it cannot deploy anything to a laptop. Every other component on this
platform follows a specific pattern — a change is tested in dev, proves
itself, and is then promoted to prod, automatically, via CI (`deploy.yml`
for the Glue script, `dbt-ci.yml` for dbt models). Local-Docker dev would
have been the one component where that pattern silently stopped applying:
dev could only ever be tested by hand.

**A single shared EC2 instance** running both dev and prod DAGs was
considered next, mainly on cost. Rejected because it requires both
environments' Snowflake keys to be present on the same box simultaneously,
directly contradicting ADR 0010's separation of dev and prod credentials,
and because a single scheduler failure would take down both environments at
once — a shared failure domain nothing else in this platform has.

## Decision

**Two EC2 instances, one per environment, each running Airflow with
`SequentialExecutor` and a SQLite metadata database.** Created once, never
destroyed in normal operation, toggled between `running` and `stopped` via a
Terraform variable.

## Rationale

**Two instances is what keeps the CI pattern intact.** A DAG change is
tested against dev, exactly as a dbt model or a Glue script is. Only once
that succeeds does the same file get pushed to prod. That symmetry is worth
paying for.

**SequentialExecutor, not LocalExecutor.** This pipeline is a single linear
chain — nothing in it benefits from running two tasks at once, and no
second DAG runs alongside it. LocalExecutor's parallelism is capability this
workload never uses, and on a t3.small, reserving memory for concurrent task
slots that stay empty is the wrong trade. SequentialExecutor is not a
downgrade here; it is sized to the actual shape of the work.

**SQLite, not Postgres.** SequentialExecutor requires SQLite — the two are
not independent choices. This also removes a second running process
(a database server) from an already memory-constrained box.

**Stop, not destroy, between uses.** The instance, its installed Airflow, its
DAG files and its SQLite metadata all live on the EBS root volume, which
persists through a stop. `terraform destroy` would discard all of that and
require a full re-bootstrap next time. The Terraform toggle
(`var.airflow_instance_state`) changes only the EC2 power state; the
resource itself is created exactly once and `lifecycle { prevent_destroy =
true }` makes an accidental destroy fail loudly rather than silently
terminate it.

**No inbound network path.** The instances sit in the existing private
subnets (ADR 0003, no NAT, no IGW) with a security group permitting no
inbound traffic at all. The webserver UI and DAG deployment both go through
SSM Session Manager — port forwarding for the UI, `send-command` for
pushing DAG files — rather than SSH or a public IP.

## Consequences

**Real, bounded cost.** Two t3.small instances for roughly a 10-day working
window: approximately £9-10 in compute, negligible EBS. This is on top of
the platform's other AWS spend and pushes the project past a strict reading
of the original £10 cap — worth stating plainly rather than quietly
absorbing. The PRD's cost section should be read as "under £10 for the
core pipeline; Airflow adds roughly £10 more for its working window."

**EBS keeps costing a small amount while stopped.** Stopping the instance
stops compute billing but not the attached volume, which continues to
accrue a small monthly charge until the instance is terminated. "Paused
indefinitely" is not free; it is cheap.

**Not production-grade Airflow.** SequentialExecutor and SQLite are
explicitly unsuitable for a real production deployment with multiple
concurrent DAGs or any meaningful task volume. That is acknowledged rather
than hidden — the honest framing is "sized correctly for this specific
single-DAG workload," not "how I would run Airflow at scale."

**user_data runs once.** Changing the bootstrap script does not update an
existing instance; it only affects a freshly created one. Since the
instances are meant to persist rather than be recreated, a bootstrap change
after first boot needs a manual re-run or a deliberate instance
replacement — not something `terraform apply` will do automatically, which
is also why `ignore_changes = [ami]` is set.

## Alternatives considered

**MWAA.** Ruled out on cost in the PRD before this ADR.

**Local Docker Compose, both environments.** Free, but breaks the CI
promotion pattern used everywhere else on this platform — see Context.

**Single shared instance.** Cheaper, but co-locates dev and prod Snowflake
credentials and creates a shared failure domain. Rejected on the same
reasoning ADR 0010 and ADR 0002 already established for other components.

**LocalExecutor + Postgres, sized for headroom (t3.medium+).** Would be more
conventional and closer to a "real" small deployment. Rejected purely on
cost — roughly double the instance price for concurrency this DAG does not
use.

## Follow-ups

- Document the SSM port-forwarding command for reaching the webserver UI in
  the runbook.
- Decide an SMTP configuration for `EmailOperator` — not yet specified.
  Options: AWS SES (cheap, needs a verified sending identity), or a
  personal SMTP relay. Whichever is chosen, the credential goes through SSM
  per ADR 0010, not into Airflow's config file directly.
- If a second, independent DAG is ever added (e.g. for the streaming path),
  revisit SequentialExecutor — running two unrelated DAGs would serialise
  them even though they do not depend on each other.






---

## Amendment (2026-08-27)

The design in the original decision — SequentialExecutor + SQLite,
configured on the systemd units — was correct. One implementation detail
was not: the bootstrap script wrote configuration to
`/opt/airflow/airflow.cfg.d/executor.cfg`, on the assumption Airflow scans
a directory of config fragments. It does not; there is no such mechanism
in Airflow. This is a carryover habit from tools that do work that way
(nginx's `conf.d`, systemd's `.d` override directories) applied to a tool
that doesn't.

It surfaced as `tee: ... Permission denied` — the directory was created
root-owned before being written to as the `airflow` user — rather than as
a silent no-op, which is the only reason it was caught before it mattered.
Had ownership happened to be correct, the executor and database settings
would never have taken effect and Airflow would have fallen back to
whatever its own defaults are, with no error at all

**Fix:** configuration is set via `AIRFLOW__SECTION__KEY` environment
variables directly in both systemd unit files — Airflow's actual,
documented override mechanism, and consistent with how `AIRFLOW_HOME` and
`RETAIL_ENVIRONMENT` were already being set on those same units.

```ini
Environment=AIRFLOW__CORE__EXECUTOR=SequentialExecutor
Environment=AIRFLOW__CORE__LOAD_EXAMPLES=False
Environment=AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/dags
Environment=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
```

See ADR 0015's amendment for two further, unrelated issues hit while
getting this design running for the first time.
