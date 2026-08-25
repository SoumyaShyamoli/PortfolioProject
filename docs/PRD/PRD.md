# Product Requirements — UK Retail Data Platform

- **Owner:** Soumyadeep
- **Status:** Active
- **Last updated:** 2026-08-24

---

## Why this exists

I have ten years in data engineering — five as an ETL developer, five
onshore handling operations and maintenance. The gap between that and a
senior data engineering role in the UK is not tooling knowledge. It is
demonstrable judgment: architecture decisions I can defend, production
discipline I can point at, and evidence I have run something end to end
rather than described it.

This platform is that evidence. It is deliberately not a tutorial pipeline.

**The specific thing it is meant to demonstrate:** production discipline —
environments, IaC, testing, reconciliation, cost control, documented
decisions. Not scale. 1.06 million rows is not big data and I do not claim
otherwise.

---

## Success criteria

The project is done when:

1. A pipeline runs end to end — raw file to a queryable mart — without manual
   intervention beyond triggering it.
2. Every architecture decision has a written ADR I can defend under
   questioning.
3. Data quality is provable, not asserted. Numbers reconcile at every hop.
4. Total cloud spend is under £10.
5. A reviewer landing on the repo understands what it is within two minutes.

Criterion 3 is the one that separates this from most portfolio projects.

---

## Users

There is one real user (me) and two imagined ones. The imagined ones drive
design more than the real one.

| User | What they need |
|---|---|
| **Hiring manager / interviewer** | To see judgment, not just working code. Reads the ADRs and the README. Asks why, not how. |
| **A future engineer inheriting this** | To understand the system without me. Needs runbooks, decision records, and honest known-gaps. |
| **Me, six months from now** | To pick it up again without re-deriving every decision. |

Designing for the second user is what produces the artifacts the first user
values. That is not a coincidence.

---

## Scope

### In scope

**Ingestion**
- Batch: Online Retail II, converted locally to daily NDJSON, uploaded to S3
- Streaming: held-back recent data replayed through Kinesis Firehose as
  simulated order events
- Reference: World Bank country metadata, GDP, population via Lambda

**Processing**
- Glue (PySpark) — NDJSON to Parquet, partitioned, with enforced
  reconciliation
- Snowflake + dbt — staging, intermediate, marts
- Incremental models with watermarking, idempotent reruns

**Platform**
- Terraform for all infrastructure
- dev and prod environments
- IAM roles segregated by function, GitHub OIDC for CI/CD
- GitHub Actions: plan on PR, deploy on merge, environment gate on prod
- CloudWatch alarms to SNS on failure

**Evidence**
- ADRs for every non-obvious decision
- Runbooks for operational procedures
- A postmortem for the state-loss incident
- Cost and performance measurements, recorded as taken

**Presentation**
- Superset connected to Snowflake

### Out of scope

Stated explicitly, because scope on this project has expanded four times and
each expansion looked individually reasonable.

- **Separate AWS accounts per environment.** Correct at real scale. Rejected
  on setup overhead. Documented in ADR 0002 as what this approximates.
- **Real streaming.** The source is a historical file. The streaming path
  replays held-back data. Framed as simulated order events, not presented as
  live ingestion.
- **Databricks.** Deferred to Project 2 as a re-platforming comparison.
- **Redshift.** Deferred to a standalone write-up.
- **EMR.** Rejected in ADR 0006 — Glue is the right tool for a bursty,
  low-volume job.
- **Managed orchestration (MWAA).** ~£250/month. Airflow runs locally in
  Docker; the production equivalent is documented.
- **Machine learning.** Phase 4, after the DE stage is complete.
- **Anything requiring a NAT gateway.** ADR 0003.

### Explicitly deferred, not rejected

- Threat model — writing it before the system is complete means rewriting it
- Pentest / exposure review
- The S3-event Lambda trigger — blocked on a fan-out problem (S3 fires per
  object, so 31 daily files would trigger 31 runs for the same month)

---

## Requirements

### Functional

| # | Requirement |
|---|---|
| F1 | Ingest the full Online Retail II dataset into S3 as immutable raw NDJSON |
| F2 | Convert raw to columnar Parquet, partitioned for query pruning |
| F3 | Ingest World Bank reference data and join it to the retail data on country |
| F4 | Load staged data into Snowflake and model it into marts via dbt |
| F5 | Support reprocessing any month without duplication |
| F6 | Union batch and streaming sources into a single staging model |
| F7 | Expose marts through Superset |

### Non-functional

| # | Requirement | How it is met |
|---|---|---|
| N1 | Total cloud spend under £10 | No NAT, no EC2, no idle clusters, Glue timeouts capped, budget alert at £5 |
| N2 | All infrastructure reproducible from code | Terraform, remote state, no console-only resources |
| N3 | Raw data recoverable and replayable | Raw immutable; pipeline role has no delete on raw |
| N4 | No silent data loss | Three-point reconciliation, enforced by job failure |
| N5 | No long-lived credentials in CI | GitHub OIDC, branch and environment scoped |
| N6 | Failures surface without someone looking | CloudWatch alarms to SNS |
| N7 | Every decision defensible | ADRs, including the ones I would do differently |

N4 is the requirement most portfolio projects skip. A pipeline that silently
drops 5% of rows passes every check that is not specifically looking for it.

---

## Constraints

**£10 total cloud spend.** This is the binding constraint on nearly every
infrastructure decision. It rules out NAT gateways, managed Airflow, idle
clusters, and interface endpoints. Several ADRs exist because of it.

**Solo build.** No reviewer, no second pair of eyes. Mitigated by CI checks
and by writing decisions down before I forget the reasoning.

**Snowflake 30-day trial.** All AWS-side work happens before the trial clock
starts. Snowflake work is compressed into one focused block.

**Learning Terraform and git during the build.** Both new to me. This has
cost time — see the state-loss incident — but the mistakes are documented,
which turns them into material rather than waste.

---

## Known gaps

Listed here and in the README so a reviewer does not have to find them.

- dev and prod share a VPC. Isolation is at IAM. See ADR 0002 for when that
  stops being adequate.
- Versioning is inconsistent across buckets — enabled on two of six,
  inherited from the original console build and deliberately frozen rather
  than silently normalised.
- Curated buckets are empty, reserved for Project 2.
- Production deploys gate on a branch and my own approval. A team would
  require a different reviewer.
- The recon alarm's firing path was verified by inspection, not by corrupting
  an input.
- Terraform state covers both environments in one file. A mistake affects
  both.

---

## Open questions

- Whether to build the S3-event trigger with a debounce mechanism, or let
  Airflow trigger Glue on a schedule and drop the event-driven path. Leaning
  toward the latter — one orchestration mechanism is easier to explain than
  two.
- Whether to keep `AWSGlueServiceRole` attached alongside the scoped inline
  policy, now that the job runs successfully.
- Where Superset runs. Locally in Docker keeps it free and consistent with
  the Airflow decision, but means it is not reachable for a demo.
