# Study Guide — Part 3: Decision Log

Every decision made, in the order made, with what was chosen, what was
rejected, and what changed later. Use this to trace *why* the platform looks
the way it does — the ADRs give the polished argument, this gives the path.

---

## Project shape

| Decision | Chose | Rejected | Why |
|---|---|---|---|
| Number of projects | One integrated platform, three deliverables | Three unrelated projects | Depth over breadth; shows iteration on a real system |
| Dataset | Online Retail II | TfL+ONS, Amazon Reviews, Land Registry | Real, messy, transactional, UK, ~1M rows fits the budget |
| Reference data | World Bank country API | ONS postcode directory | Postcodes have nothing to join on — retail data is country-grain only |
| Warehouse | Snowflake + dbt | Databricks | Faster to productive, most-requested UK combo; Databricks becomes Project 2 |
| Spark engine | Glue | EMR, EMR Serverless, pandas-in-Lambda | Idle cost on a bursty job; Glue appears at least as often in UK specs |
| CI/CD | GitHub Actions | Azure DevOps | AWS-native stack; no benefit from a second toolchain |
| Orchestration | Airflow in Docker locally | MWAA, EC2-hosted | ~£250/mo and ~£30/mo respectively, against a £10 budget |
| BI layer | Self-hosted Superset | Power BI, Tableau | Open source, no licence cost |

### Changed along the way

- **EMR was in, then swapped for Redshift's slot, then dropped entirely.**
  Final position: Glue, with the Snowflake-vs-Redshift comparison deferred to
  a standalone write-up.
- **DuckDB-first was planned, then abandoned.** Original plan was to build dbt
  models against DuckDB for free and port to Snowflake at the end. Dropped in
  favour of building directly against Snowflake inside one 30-day trial
  window, with all AWS-side work completed before starting that clock.

---

## Storage

| Decision | Chose | Why |
|---|---|---|
| Bucket layout | Six: env × layer | Bucket-scoped IAM is simpler and safer than prefix-scoped |
| Raw format | NDJSON | Spark/Glue/Snowflake all read it natively and can split it |
| Staged format | Parquet + Snappy | ~50× smaller; columnar projection and partition pruning |
| Raw mutability | Immutable | Replay point for every downstream correction |
| Cleaning location | dbt staging | Cleaning at ingest destroys the replay point |
| Raw partitions | Daily (`event_date=`) | Honest arrival grain; a bad day can be re-dropped alone |
| Staged partitions | Monthly (`year=/month=`) | Avoids ~730 × 30KB files; 25 runs instead of 730 |
| Curated | Reserved for Project 2 | Snowflake path has no S3 curated layer; documented as a known gap |
| Versioning | Two of six buckets | Adopted inherited drift explicitly rather than normalising silently |
| Lifecycle | Standard-IA at 30d, non-current expiry at 90d | Caps replay window — a real retention trade-off |

### Changed along the way

- **Staged partitioning went daily → monthly** after working through
  small-file and per-run-cost implications. The Glue job was rewritten and
  ADR 0005 corrected.
- **Curated was initially unassigned.** The gap was spotted when mapping the
  medallion pattern onto a Snowflake-based platform, where curated marts live
  in the warehouse rather than S3.

---

## Networking

| Decision | Chose | Why |
|---|---|---|
| Environment isolation | Shared VPC, IAM boundary | S3 isn't in the VPC; a second VPC costs money without moving the boundary |
| Internet egress | None | No NAT (~£30/mo), no IGW |
| S3 access | Gateway endpoint | Free, and keeps traffic off the public internet |
| Glue interface endpoint | Deferred, never needed | Bills hourly per AZ; the job ran fine without it |
| Subnets | Two private, two AZs | AZ redundancy at no cost |
| Glue SG | Self-referencing rule added | Workers need to reach each other; the console SG had no inbound rules at all |

---

## IAM

| Decision | Chose | Why |
|---|---|---|
| Role split | Five, by function | Runtime / deploy / human are distinct trust boundaries |
| CI/CD auth | GitHub OIDC | No static credential to leak or rotate |
| Prod deploy trust | `main` branch only | A fork's PR cannot obtain prod credentials |
| `PassRole` scope | One role ARN + service condition | Unscoped PassRole is a privilege escalation path |
| Raw access for pipeline | Read-only | Structurally cannot modify its replay point |
| Staged access for pipeline | Read/write/**delete** | Dynamic partition overwrite requires delete |
| Curated access for pipeline | None | Nothing in this pipeline writes there |
| World Bank Lambda | Separate role | It writes to raw, which Glue deliberately cannot |
| Builder identity | Broad, permissions added on demand | Over-restricting a sole builder buys nothing |

### Changed along the way

- **`DeleteObject` was missing** from both pipeline roles. Caught by review
  before the first re-run rather than by a failure.
- **Curated was removed** from the pipeline roles once it was assigned to
  Project 2.
- **The script prefix was wrong** — deploy roles granted `scripts/*` while
  the job read from `_scripts/`. Would have 403'd on the first CI deploy.

---

## The Glue job

| Decision | Chose | Why |
|---|---|---|
| Job scope | Format conversion only | Cleaning belongs downstream |
| Idempotency | Dynamic partition overwrite | Re-running replaces rather than appends |
| Concurrency | `max_concurrent_runs = 1` | Two runs on one partition lose data |
| Job bookmarks | Disabled | Hidden state makes reprocessing harder, not easier |
| Timeout | 15 minutes | Default is 48 hours — a hung job would exceed the budget |
| Retries | 0 | A failure here means bad input; retrying obscures it |
| Partition keys | Derived from data | A misfiled object lands correctly |
| Stray-row guard | Fail before writing | Prevents overwriting another month with one row |
| Output files | `coalesce(1)` | Avoids 30 tiny files per month |
| Schema | Explicit + `_corrupt_record` | Inference costs a pass; corrupt records would otherwise vanish |
| Recon | Three points, enforced | A silent shortfall passes every downstream check |
| Audit trail | JSON to `_audit/recon/` | Written by the job, not captured by whoever ran it |

### Changed from the first draft

The original script had four problems, all found in review:

1. `mode("append")` — every re-run would have duplicated data
2. `year`/`month` partitioning while processing per-day — the second day
   would have erased the first
3. Dropped null `invoice_no` rows — contradicted the raw-immutability design
4. Two `df.count()` calls — three full passes over the data

---

## The World Bank Lambda

| Decision | Chose | Why |
|---|---|---|
| Placement | Outside the VPC | Needs public internet; subnets have none |
| HTTP client | `urllib.request` | No layer or vendored zip to manage |
| Pagination | Implemented | Silent truncation at page 1 would be invisible |
| Retries | 5xx and network only | Retrying a 4xx is pointless |
| Datasets | Metadata + GDP + population | Indicators make the join analytically useful |
| Indicator year | 2010 | Mid-dataset (Dec 2009 – Dec 2011) |
| Write mode | Overwrite in place | Reference data is current-state, not an event stream |
| Aggregates | Not filtered | Raw takes what the source returns |
| Schedule | Monthly, dev enabled / prod disabled | Reference data changes rarely; prod isn't live yet |
| Log retention | 14 days | Lambda log groups default to never expire |

---

## Country mapping

43 distinct values in the source:

- **34 exact** matches
- **6 aliases** — EIRE→IRL, USA→USA, RSA→ZAF, Hong Kong→HKG,
  Czech Republic→CZE, Korea→KOR
- **1 assumed** — Korea, ambiguous between ROK and DPRK; South assumed on
  commercial plausibility, flagged `assumed` rather than `alias`
- **3 unmappable** — Unspecified (756), European Community (61),
  West Indies (54) — kept with null `country_id` so totals still reconcile

Surprise: **Channel Islands is a real World Bank entity** (CHI), so it maps
exactly.

---

## Open questions

Things not yet settled, worth having a position on before they come up.

**The S3-event Lambda trigger.** S3 fires per object, so uploading 31 daily
files triggers 31 Glue runs for the same month — 30 of which fail on the
concurrency limit while still billing the one-minute minimum. Needs
debouncing (DynamoDB, Step Functions, or a scheduled sweeper) before it can
be built safely.

**Terraform state backend.** Still local. Should move to S3 with
`use_lockfile = true` before CI touches it.

**`AWSGlueServiceRole`.** Broader than the inline policy alongside it. Keep
as the AWS baseline, or drop and rely on the scoped policy? Undecided — but
should be a decision, not a default.

**Quarantine for undated rows.** Currently excluded from the write and
counted. Should route to a quarantine prefix.

**Streaming path.** The source is historical, so this means replaying through
Firehose. Honest as "simulated order events"; the weakest part of the design
and the most likely to eat time for the least return.

**Superset hosting.** Needs somewhere to run. Locally in Docker keeps it
free, consistent with the Airflow decision, but means it isn't reachable for
a demo.
