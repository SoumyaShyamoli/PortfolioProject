# UK Retail Data Platform

A data platform on AWS and Snowflake, built to production standards:
environment separation, least-privilege IAM, infrastructure as code,
enforced reconciliation, and a written record of every decision.

Built solo under a hard cloud budget of £10. Several design decisions below
are a direct consequence of that constraint and are documented as such rather
than presented as unconstrained best practice.

---

## The data

**[Online Retail II](https://archive.ics.uci.edu/dataset/502/online+retail+ii)** —
about 1.06 million real transactions from a UK online gift-ware retailer,
December 2009 to December 2011, across 38 countries. Genuinely messy:
cancellations, negative quantities, missing customer IDs, zero prices,
duplicates.

**World Bank country API** — metadata, GDP and population, joined on country
for per-capita and regional analysis.

---

## Architecture

```
    Online Retail II (CSV)
          │
          │  local conversion → daily NDJSON
          │
          ├──────────────────────────┐
          ▼                          ▼
  ┌─────────────────┐      ┌──────────────────────┐
  │  S3  raw        │      │  Kinesis Firehose    │  ← not built
  │  orders/        │      │  (held-back records  │
  │  NDJSON, daily  │      │   replayed as events)│
  │  immutable      │      └──────────┬───────────┘
  └────────┬────────┘                 │
           │                          ▼
           │              ┌──────────────────────┐
           │              │  S3  raw             │  ← not built
           │              │  orders_stream/      │
           │              └──────────┬───────────┘
           │                         │
           ▼                         │
  ┌─────────────────┐                │
  │  AWS Glue       │                │
  │  NDJSON→Parquet │                │
  │  + reconciliation│               │
  └────────┬────────┘                │
           ▼                         │
  ┌─────────────────┐                │
  │  S3  staged     │                │
  │  Parquet, y/m   │                │
  │  + _audit/recon │                │
  └────────┬────────┘                │
           │                         │
           └────────────┬────────────┘
                        │  COPY INTO / Snowpipe
                        ▼
              ┌─────────────────┐
              │   Snowflake     │
              │  dbt: staging   │  ← batch + stream union here,
              │  → int → marts  │    deduped on invoice line key
              └────────┬────────┘
                       ▼
                   Superset
```
Both ingestion paths converge in dbt staging, unioned and deduplicated on
invoice line key, so everything downstream is source-agnostic. The
streaming path replays records held back from the historical dataset —
simulated order events, not live ingestion.


Compute runs in private subnets with no NAT gateway and no internet gateway.
S3 is reached through a free gateway VPC endpoint, so data traffic never
leaves the AWS network.

---

## Status

| Component | State |
|---|---|
| Local CSV → NDJSON conversion | Done |
| S3 storage layers (dev + prod) | Done |
| IAM roles, GitHub OIDC | Done |
| VPC, subnets, security group, S3 endpoint | Done |
| Terraform — all infrastructure, remote state | Done |
| Glue job: NDJSON → Parquet with reconciliation | Done, running in dev |
| World Bank reference ingestion | Done |
| CI/CD: PR checks, dev smoke test, gated prod deploy | Done |
| Alerting: CloudWatch → SNS | Done |
| Streaming path (Firehose) | Not started |
| Snowflake + dbt | Not started |
| Airflow orchestration | Not started |
| Superset | Not started |
| Cost/performance case study | Partial |

---

## Documentation

- **[Product requirements](docs/PRD.md)** — scope, requirements, what is
  deliberately excluded
- **[Architecture decisions](docs/adr/)** — why each choice was made
- **[Runbooks](docs/runbooks/)** — operational procedures
- **[Incidents](docs/incidents/)** — postmortems

### Decision records

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-brownfield-terraform-adoption.md) | Adopt console-created infrastructure into Terraform rather than rebuild |
| [0002](docs/adr/0002-shared-vpc-iam-isolation.md) | Share one VPC across dev and prod; isolate at the IAM layer |
| [0003](docs/adr/0003-no-nat-gateway.md) | No NAT gateway; reach S3 through a gateway VPC endpoint |
| [0004](docs/adr/0004-iam-role-segregation.md) | Segregate IAM roles by function; no long-lived keys for CI/CD |
| [0005](docs/adr/0005-s3-layout-and-raw-immutability.md) | Bucket per layer per environment; raw is immutable NDJSON |
| [0006](docs/adr/0006-glue-over-emr.md) | AWS Glue rather than EMR for Spark workloads |
| [0007](docs/adr/0007-monthly-partitions-and-enforced-recon.md) | Monthly staged partitions; reconciliation enforced, not logged |
| [0008](docs/adr/0008-oidc-trust-immutable-ids.md) | Pin GitHub OIDC trust to immutable owner and repository IDs |
| [0009](docs/adr/0009-alerting-strategy.md) | Alerting on pipeline failures |

---

## Three things worth pointing at

**Raw is immutable, and nothing cleans on ingest.** Cancellations, nulls and
duplicates land untouched and are handled in dbt staging. Every downstream
correction is therefore recoverable by reprocessing from raw. The pipeline
execution role has no delete permission on raw — it is structurally incapable
of destroying its own replay point.

**Reconciliation fails the job rather than logging a warning.** Each Glue run
computes three independent counts — source lines read as text, rows parsed
versus malformed, and rows read back from the written Parquet — and fails if
they do not balance. A silent shortfall is otherwise indistinguishable from
success, because every downstream check passes against whatever loaded.

**The infrastructure was adopted, not rebuilt.** It was first built by hand in
the console, then brought under Terraform with import blocks. That surfaced
real drift — inconsistent bucket versioning, and a lifecycle rule that had
never actually saved. Destroying and recreating would have hidden both.

---

## Repository layout

```
├── docs/
│   ├── PRD.md                Product requirements
│   ├── adr/                  Architecture decision records
│   ├── runbooks/             Operational procedures
│   ├── incidents/            Postmortems
│   └── study/                Interview prep notes
├── ingestion/
│   ├── local/                CSV → NDJSON conversion
│   ├── worldbank/            Reference data Lambda
│   └── stream/               Simulated order stream
├── glue/jobs/                PySpark jobs
├── dbt/                      Snowflake transformation models
├── infra/
│   ├── terraform/            All infrastructure as code
│   └── policies/             IAM policy exports, for review
├── orchestration/            Airflow DAGs
└── .github/workflows/        CI/CD
```

---

## Running it

Requires an AWS account, AWS CLI with a named profile, Terraform 1.10+, and
Python 3.12+.

```bash
export AWS_PROFILE=retail-dev

# 1. Infrastructure
cd infra/terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 2. Convert the source CSV to daily NDJSON (data/ is gitignored)
python ingestion/local/convert_ndjson.py \
  --input data/raw/online_retail_II.csv --outdir data/json

# 3. Upload one month to the raw bucket
aws s3 cp data/json/batch/ s3://<raw-bucket>/orders/ --recursive \
  --exclude "*" --include "event_date=2010-12-*"

# 4. Run the conversion for that month
aws glue start-job-run --job-name retail-dev-json-to-parquet \
  --arguments '{"--year":"2010","--month":"12"}'
```

Re-running any month is safe. The write replaces that month's partition
rather than appending to it.

---

## Measurements

Recorded as taken, not estimated.

| Metric | Value |
|---|---|
| December 2010, raw NDJSON | 19.1 MB |
| December 2010, staged Parquet | 389 KB |
| Compression ratio | ~50× |
| Glue job runtime (one month, 2× G.1X) | 82 s |
| January 2011 rows reconciled | 35,147, difference 0 |

The compression figure combines Snappy, columnar encoding, and the fact that
NDJSON repeats every field name on every line while Parquet stores the schema
once.

---

## Known gaps

Stated deliberately rather than left for a reviewer to find. Full list in the
[PRD](docs/PRD.md).

- **`curated` buckets are empty.** Reserved for the Databricks lakehouse
  variant (a planned second project). In the Snowflake path, curated marts
  live inside the warehouse.
- **dev and prod share a VPC.** Isolation is at IAM. ADR 0002 covers why, and
  when that stops being adequate.
- **Versioning is inconsistent across buckets** — enabled on two of six,
  inherited from the console build and deliberately frozen rather than
  silently normalised. ADR 0001.
- **Production deploys gate on a branch and my own approval.** A team would
  require a different reviewer.
- **The streaming path is simulated.** The source dataset is historical, so
  streaming means replaying held-back records through Firehose. Framed as
  simulated order events, not presented as live ingestion.
- **1.06 million rows is not big data.** This demonstrates production
  discipline — environments, IaC, testing, reconciliation, cost control — not
  horizontal scale.
