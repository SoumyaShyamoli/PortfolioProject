# UK Retail Data Platform

A production-grade data platform on AWS and Snowflake, built to the
standards of a real company's data team: environment separation,
least-privilege IAM, infrastructure as code, enforced reconciliation, and
documented architecture decisions.

Built solo, under a hard cloud budget of £10 total. Several design decisions
below are a direct consequence of that constraint, and are documented as
such rather than presented as unconstrained best practice.

---

## The data

**[Online Retail II](https://archive.ics.uci.edu/dataset/502/online+retail+ii)** —
approximately 1.06 million real transactions from a UK online gift-ware
retailer, December 2009 to December 2011, across 38 countries. Genuinely
messy: cancellations, negative quantities, missing customer identifiers,
zero prices, duplicate rows.

**World Bank country API** — country metadata, GDP and population, joined on
country to enable per-capita and regional analysis.

---

## Architecture

```
  Online Retail II (CSV)
          │
          │  local conversion → one NDJSON file per invoice date
          ▼
  ┌─────────────────┐
  │  S3  raw        │   NDJSON, event_date=YYYY-MM-DD, immutable
  └────────┬────────┘
           │  AWS Glue (PySpark) — format conversion + reconciliation
           ▼
  ┌─────────────────┐
  │  S3  staged     │   Parquet + Snappy, year=/month=
  └────────┬────────┘   plus _audit/recon/ run records
           │  COPY INTO
           ▼
  ┌─────────────────┐
  │   Snowflake     │   dbt: staging → intermediate → marts
  └────────┬────────┘
           │
           ▼
       Superset
```

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
| Terraform adoption of all of the above | Done |
| Glue job: NDJSON → Parquet with reconciliation | Done, running in dev |
| Lambda + EventBridge trigger | Not started |
| World Bank reference ingestion | Not started |
| Snowflake + dbt | Not started |
| Data quality / observability layer | Partial (recon in place) |
| Superset | Not started |

---

## Design decisions

Reasoning is recorded in [`docs/adr/`](docs/adr/). Each ADR states the
decision, why, what it costs, and what was rejected.

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-brownfield-terraform-adoption.md) | Adopt console-created infrastructure into Terraform rather than rebuild |
| [0002](docs/adr/0002-shared-vpc-iam-isolation.md) | Share one VPC across dev and prod; isolate at the IAM layer |
| [0003](docs/adr/0003-no-nat-gateway.md) | No NAT gateway; reach S3 through a gateway VPC endpoint |
| [0004](docs/adr/0004-iam-role-segregation.md) | Segregate IAM roles by function; no long-lived keys for CI/CD |
| [0005](docs/adr/0005-s3-layout-and-raw-immutability.md) | Bucket per layer per environment; raw is immutable NDJSON |
| [0006](docs/adr/0006-glue-over-emr.md) | AWS Glue rather than EMR for Spark workloads |
| [0007](docs/adr/0007-monthly-partitions-and-enforced-recon.md) | Monthly staged partitions; reconciliation enforced, not logged |
| [0007](docs/adr/0007-monthly-partitions-and-enforced-recon.md) | Monthly staged partitions; reconciliation enforced, not logged |
| [0008](docs/adr/0008-oidc-trust-immutable-ids.md) | Pin GitHub OIDC trust to immutable owner and repository IDs |

---

## Two properties worth highlighting

**Raw is immutable, and nothing cleans on ingest.** Cancellations, nulls and
duplicates land untouched and are handled in dbt staging. Every downstream
correction is therefore recoverable by reprocessing from raw. The pipeline
execution role deliberately has no delete permission on the raw buckets.

**Reconciliation fails the job rather than logging a warning.** Each Glue run
computes three independent counts — source lines read as text, rows parsed
versus malformed, and rows read back from the written Parquet — and fails if
they do not balance. A silent shortfall is otherwise indistinguishable from
success, because every downstream check passes against whatever loaded.

---

## Repository layout

```
├── docs/
│   └── adr/                  Architecture decision records
├── ingestion/
│   ├── local/                CSV → NDJSON conversion
│   ├── worldbank/            Reference data pull
│   └── stream/               Simulated order stream
├── glue/jobs/                PySpark jobs
├── lambda/                   Event-driven triggers
├── dbt/                      Snowflake transformation models
├── infra/
│   ├── terraform/            All infrastructure as code
│   └── policies/             IAM policy exports, for review
├── orchestration/            Airflow DAGs
└── tests/
```

---

## Running it

Requires an AWS account, the AWS CLI configured with a named profile,
Terraform 1.7+, and Python 3.11+.

```bash
# 1. Infrastructure
cd infra/terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 2. Convert the source CSV to daily NDJSON (data/ is gitignored)
python ingestion/local/convert_to_ndjson.py \
  --input data/raw/online_retail_II.csv --outdir data/json

# 3. Upload one month to the raw bucket
aws s3 cp data/json/batch/ s3://<raw-bucket>/orders/ --recursive \
  --exclude "*" --include "event_date=2010-12-*"

# 4. Run the conversion for that month
aws glue start-job-run --job-name retail-dev-json-to-parquet \
  --arguments '{"--year":"2010","--month":"12"}'
```

Re-running any month is safe — the write replaces that month's partition
rather than appending to it.

---

## Measurements

Recorded as they are taken, rather than estimated.

| Metric | Value |
|---|---|
| December 2010, raw NDJSON | 19.1 MB |
| December 2010, staged Parquet | 389 KB |
| Compression ratio | ~50× |
| Glue job runtime (one month, 2× G.1X) | 82 s |

The compression figure combines Snappy, columnar encoding, and the fact that
NDJSON repeats every field name on every line while Parquet stores the schema
once.

---

## Known gaps

Stated deliberately rather than left for a reviewer to find.

- **`curated` buckets are empty.** They are provisioned for the Databricks
  lakehouse variant (a planned second project). In the Snowflake path,
  curated marts live inside the warehouse.
- **dev and prod share a VPC.** Isolation is enforced at IAM. See ADR 0002
  for why, and for when that stops being adequate.
- **Versioning is inconsistent across buckets.** Enabled on two of six, as
  inherited from the original console build and deliberately frozen rather
  than silently normalised. See ADR 0001.
- **Production deploys are gated on a branch, not a reviewer.** Adequate for
  a solo project; a team would add an environment protection rule.
- **The streaming path is simulated.** The source dataset is historical, so
  "streaming" means replaying it through Kinesis Firehose. Framed as
  simulated order events rather than presented as live ingestion.
- **1.06 million rows is not big data.** The platform demonstrates production
  discipline — environments, IaC, testing, reconciliation, cost control —
  not horizontal scale.
