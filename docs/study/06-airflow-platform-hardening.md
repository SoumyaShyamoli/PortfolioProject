# Study Guide 06 — dbt CI, World Bank, tier-1 hardening, and the Airflow build

Covers what happened after the original dbt scaffold was working. Does not
repeat docs/study/01-05 — read those first for the foundational build.
Organised day by day, in the order things actually happened, including the
wrong turns.

---

## Day 1 — dbt CI, World Bank integration, tier-1 hardening

### dbt CI: compile-on-PR, build-on-merge

**Decision:** two jobs, not one. `compile` runs on every PR (parses, no
warehouse writes). `build` runs only on merge to `main` (actually runs
models and tests against dev).

```bash
dbt deps
dbt parse
dbt compile
```

**Why `dbt build`, not `dbt run` then `dbt test`:** `build` interleaves
models and their tests in dependency order — a failing test stops
downstream models from being built on top of bad data. `run` then `test`
builds everything first and only then discovers the problem. For a
pipeline whose whole design is reconciliation gating, that ordering is the
point, not a style preference.

### The key generated-schema-name bug

dbt's default schema naming **concatenates** the profile schema with the
model's configured schema (`staging` + `staging` → `STAGING_STAGING`).
Fixed with a `generate_schema_name` macro that uses the model's schema
verbatim.

```sql
-- macros/generate_schema_name.sql
{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- if custom_schema_name is none -%}
    {{ target.schema }}
  {%- else -%}
    {{ custom_schema_name | trim }}
  {%- endif -%}
{%- endmacro %}
```

**Tradeoff to know cold:** this removes per-developer schema isolation.
Fine solo; wrong on a team, where the default concatenation exists
specifically so multiple developers don't collide in one database.

### CI secret handling — the `trap` bug

First version of the key-fetch step used a `trap` to delete the temp
Snowflake key on exit:

```bash
trap 'rm -f /tmp/sf_key.p8' EXIT
```

**Failure:** the trap fires when the *step's* shell exits — before dbt
ever runs in the *next* step. The key was deleted immediately after being
written, so dbt failed with `No such file or directory`.

**Fix:** no trap on the fetch step. A separate `if: always()` cleanup step
at the end of the job instead.

```yaml
- name: Remove Snowflake key
  if: always()
  run: rm -f /tmp/sf_key.p8
```

### Grants needed before dbt could even connect

```sql
GRANT CREATE SCHEMA ON DATABASE RETAIL_DEV  TO ROLE RETAIL_TRANSFORMER_DEV;
GRANT CREATE SCHEMA ON DATABASE RETAIL_PROD TO ROLE RETAIL_TRANSFORMER_PROD;
```

**Why:** dbt creates schemas as part of a run rather than assuming they
exist. The original grants covered operating on schemas that already
existed — not creating new ones. Different permission entirely.

### World Bank integration — storage integration had to be widened

The Snowflake storage integration only allowed the **staged** bucket.
World Bank data lands in **raw**. Both Snowflake's side and AWS's IAM side
needed separate widening — order matters, do Terraform first:

```sql
ALTER STORAGE INTEGRATION RETAIL_DEV_S3_INTEGRATION SET
  STORAGE_ALLOWED_LOCATIONS = (
    's3://sd-retail-dev-staged-.../orders/',
    's3://sd-retail-dev-staged-.../_audit/',
    's3://sd-retail-dev-raw-.../worldbank/'      -- new
  );
```

**Trap to remember:** `ALTER ... SET STORAGE_ALLOWED_LOCATIONS` *replaces*
the whole list. Omit the existing staged prefixes and every current stage
silently breaks.

On the IAM side, the grant was scoped to `worldbank/*` only — **not** the
whole raw bucket:

**Why the narrow scope matters:** granting all of raw would let Snowflake
read `orders/` NDJSON directly, bypassing Glue's conversion and its
reconciliation entirely. The scoping protects the pipeline's *shape*, not
just the data.

```sql
CREATE STAGE IF NOT EXISTS RAW.STG_WORLDBANK
  STORAGE_INTEGRATION = RETAIL_DEV_S3_INTEGRATION
  URL = 's3://sd-retail-dev-raw-.../worldbank/'
  FILE_FORMAT = (TYPE = JSON);
```

### The World Bank aggregates trap

The API returns ~50 rows that are **aggregates**, not countries —
`'World'`, `'Euro area'`, regional groupings. Identifiable by
`region_id = 'NA'` — a literal two-character string, not a null.

```sql
where region_id is not null
  and region_id <> 'NA'
```

**Design call:** filtered in the dbt staging model, not at ingest. Raw
takes what the source returns (ADR 0005); filtering downstream means you
can recover the aggregates later without re-fetching.

### Tier-1 hardening — the Snowflake resource monitor

```sql
CREATE RESOURCE MONITOR RETAIL_MONITOR
  WITH CREDIT_QUOTA = 10 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50  PERCENT DO NOTIFY
    ON 75  PERCENT DO NOTIFY
    ON 90  PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE RETAIL_WH SET RESOURCE_MONITOR = RETAIL_MONITOR;
ALTER WAREHOUSE RETAIL_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;
```

**Why SUSPEND before SUSPEND_IMMEDIATE:** gives a chance to intervene
before queries get killed mid-write. Two independent limits — the monitor
caps total spend, the statement timeout caps any single runaway query.

Also created `RETAIL_READER` — documented in an earlier ADR as existing,
but never actually created. **Lesson:** a documented role that doesn't
exist is worse than not documenting it, because the doc is what gets
reviewed.

### The duplicate-rate finding — real data, not a bug

`assert_duplicate_rate_stable` failed at a flat 5% threshold. Investigated
rather than loosened blindly:

```sql
SELECT period, COUNT(*) total_rows,
       COUNT_IF(duplicate_occurrence > 1) duplicate_rows,
       ROUND(COUNT_IF(duplicate_occurrence > 1) / COUNT(*), 4) duplicate_rate
FROM STAGING.STG_ORDERS GROUP BY 1 ORDER BY 1;
```

Result: **2010-12 = 35.4%, 2011-01 = 0.70%, 2011-11 = 1.55%.** Not a flat
rate at all — December 2010 (the dataset's first month) is a genuine
outlier. Confirmed as real duplication (identical invoice, stock code,
quantity, timestamp to the millisecond, price) — not a pipeline artifact.

**Test rewritten** to treat Dec 2010 as a documented exception rather than
widen the threshold to hide it:

```sql
where
    (period = '2010-12' and duplicate_rate > 0.45)
    or (period <> '2010-12' and duplicate_rate > 0.05)
```

**The real lesson, worth stating in an interview:** row-count
reconciliation cannot catch this. Glue counts duplicate rows as rows, so
source lines, S3 writes, and Snowflake loads all agree regardless of
duplication. Recon proves nothing was lost in transit — it says nothing
about whether what arrived matches expectation. That's a distinct kind of
control, and this test exists for exactly that gap.

**Decision for marts (not yet built):** keep duplicates in staging (raw
audit trail, ADR 0005), filter `WHERE duplicate_occurrence = 1` when
building the deduplicated business view in marts.

---

## Day 2 — Airflow: hosting decision and first bootstrap attempts

### The hosting decision (ADR 0014)

Three options considered:

| Option | Verdict | Why |
|---|---|---|
| Local Docker, both envs | Rejected | CI cannot deploy to a laptop — breaks the dev-proves-itself-before-prod pattern used everywhere else |
| One shared instance, two DAGs | Rejected | Co-locates dev and prod Snowflake keys on one box, contradicting ADR 0010; single scheduler failure takes down both envs |
| Two small EC2 instances | **Chosen** | Only version where CI can genuinely exercise dev-then-prod promotion |

**Cost tradeoff explicitly accepted:** ~£9-10 for two t3.small instances
over a ~10-day working window, on top of the original £10 cap. Stated
plainly in the ADR rather than quietly absorbed.

**SequentialExecutor + SQLite, not LocalExecutor + Postgres:** the DAG is
one linear chain with no need for concurrent task execution. Paying for
parallelism in memory on a t3.small that's never used is the wrong trade.

**Instance lifecycle — stop, never destroy:**

```hcl
resource "null_resource" "airflow_power_state" {
  triggers = { desired_state = var.airflow_instance_state }
  provisioner "local-exec" {
    command = var.airflow_instance_state == "running" ?
      "aws ec2 start-instances --instance-ids ..." :
      "aws ec2 stop-instances --instance-ids ..."
  }
}
```

```hcl
lifecycle {
  prevent_destroy = true   # deliberate destroy needs this removed first
}
```

**Why:** the instance is created once, ever. Every other `terraform apply`
for unrelated changes leaves it untouched. Flipping the variable toggles
power state without losing installed software or DAG files on the EBS
volume.

### Failure — root volume smaller than the AMI snapshot

```
InvalidBlockDeviceMapping: Volume of size 20GB is smaller than
snapshot ..., expect size >= 30GB
```

**Fix:** bump `root_block_device.volume_size` to 30. AL2023's current AMI
snapshot needs at least that; AWS won't shrink a volume to fit.

### Failure — the `tee` logging bug (the one that hid everything else)

```bash
exec > >(tee /var/log/airflow-bootstrap.log) 2>&1
```

**Symptom:** `cloud-init status --long` reported `done` in seconds, log
file nearly empty, no systemd units, nothing installed.

**Cause:** `tee` in a process-substitution subshell has its completion not
reliably waited on when cloud-init runs the script as `user_data` — as
opposed to an interactive shell, where this idiom is completely normal
and safe. Cloud-init considered the script finished the instant the
subshell launched.

**Fix — the plain, boring version:**

```bash
exec > /var/log/airflow-bootstrap.log 2>&1
```

**Why this mattered beyond itself:** every subsequent failure was
invisible until this was fixed. A logging bug that hides failures is
worse than no logging — it manufactures false confidence.

### Failure — no route to PyPI (expected, from ADR 0003)

```
Failed to establish a new connection: [Errno 101] Network is unreachable
```

Private subnets, no NAT, no IGW. `dnf` worked because AL2023's repos sit
behind AWS-provided VPC endpoints; PyPI does not.

**Fix concept (ADR 0015):** pre-download every package on a machine with
internet, upload to S3, install with `--no-index --find-links`, over the
existing free S3 gateway endpoint.

### Failure — cross-platform pip resolution can't find old pinned wheels

```
ERROR: Cannot install apache-airflow==2.10.5 because these package
versions have conflicting dependencies... dill>=0.2.2 vs dill==0.3.1.1
```

Using `--platform manylinux2014_x86_64 --python-version 3.11` to
cross-resolve from a different OS repeatedly failed on this old,
narrowly-pinned transitive dependency — no matter how the install command
was split (core alone, core+providers, providers separate from dbt).

**Real fix, not a workaround:** stop cross-resolving. Build the
wheelhouse **natively**, on a throwaway EC2 instance running the actual
target OS and Python version. Same pattern AWS recommends for building
Lambda layers targeting a different platform than the dev machine.

```bash
aws ec2 run-instances --image-id <same-ami> --instance-type t3.small ...
aws ssm start-session --target <throwaway-id> --profile retail-dev
sudo dnf install -y python3.11 python3.11-pip
```

---

## Day 3 — version drift, the constraints-file network gap, config that didn't exist

### Failure — silent Airflow 3.x install (the important one)

Providers downloaded **without** Airflow explicitly on the same command
line:

```bash
python3.11 -m pip download --dest /tmp/wheelhouse \
  apache-airflow-providers-amazon apache-airflow-providers-smtp
```

**Result:** pip treated Airflow as a free transitive dependency of the
provider (`apache-airflow>=2.9.0`) and picked the newest satisfying
version — **3.3.1**, a different major architecture, with zero errors
anywhere in the log.

**First fix attempt, still incomplete:** reapplying `--constraint` to the
providers pass stopped the jump to 3.x, but landed on **2.11.0** — a
different 2.x minor, still not the target. The constraints file pins
Airflow's *dependencies*; it doesn't itself force Airflow's *own* version
when Airflow is present only transitively.

**Actual fix — state the exact version explicitly, everywhere:**

```bash
python3.11 -m pip download --dest /tmp/wheelhouse \
  "apache-airflow==2.10.5" \
  apache-airflow-providers-amazon apache-airflow-providers-smtp \
  --constraint /tmp/wheelhouse/constraints.txt
```

**The distinction that matters for an interview:** "I applied the
constraints file" and "I pinned the version" are not the same claim. A
constraints file limits what a resolver *may* pick from candidates
already in play — it doesn't put a specific version *in play* if nothing
on that command line explicitly requested it.

**Mechanical check added, not trusted to memory:**

```bash
INSTALLED_VERSION=$(/opt/airflow/venv/bin/airflow version)
if [ "$INSTALLED_VERSION" != "2.10.5" ]; then
  echo "FATAL: expected 2.10.5, got $INSTALLED_VERSION" >&2
  exit 1
fi
```

Drifted silently twice before this check existed. It exists so a third
drift becomes structurally impossible, not just "unlikely."

### Failure — `--constraint <url>` is a separate network fetch from `--no-index`

```
Failed to establish a new connection ... raw.githubusercontent.com
```

**Cause:** `--no-index`/`--find-links` govern where pip looks for
*packages*. `--constraint <url>` is a distinct HTTP fetch pip makes to
*read* the pin list — not covered by `--no-index` at all. Same network
boundary as the PyPI failure, hit a second time via a URL that didn't
look like a package source.

**Fix:** download the constraints file once during the wheelhouse build,
ship it as a local file, reference the local path everywhere:

```bash
curl -fL -o /tmp/wheelhouse/constraints.txt "$CONSTRAINT_URL"
# ...
pip install --no-index --find-links "$WHEELHOUSE_DIR" \
  "apache-airflow==2.10.5" --constraint "$WHEELHOUSE_DIR/constraints.txt"
```

### Failure — dbt-core's build backend fetches a wheel from GitHub

```
RuntimeError: failed to download https://github.com/dbt-labs/dbt-core/
releases/download/v2.0.0-beta.2/dbt_core_experimental_parser-...whl:
<urlopen error timed out>
```

**Cause:** `dbt-core-experimental-parser` ships as source only. Its
custom build backend fetches a companion binary directly from a GitHub
release URL **at build time**, not download time. `pip download` on an
internet-connected machine succeeds because downloading the source
package is all that happens then — the actual build (and its network
call) is deferred to `pip install`, which on the instance means offline.

**Fix — surgical, not architectural:** fetch that one exact wheel
manually, drop it in the wheelhouse, so pip finds a pre-built wheel and
never triggers the build step:

```bash
curl -fL -o /tmp/wheelhouse/dbt_core_experimental_parser-2.0.0b2-py3-none-manylinux_2_28_x86_64.whl \
  "https://github.com/dbt-labs/dbt-core/releases/download/v2.0.0-beta.2/dbt_core_experimental_parser-2.0.0b2-py3-none-manylinux_2_28_x86_64.whl"
```

### Failure — a config mechanism that never existed

```
tee: /opt/airflow/airflow.cfg.d/executor.cfg: Permission denied
```

**Cause:** the script assumed Airflow scans a directory of config
fragments, the way nginx's `conf.d` or systemd's `.d` overrides do.
Airflow has no such mechanism at all. The permission error (directory
created root-owned, written to as a different user) was the *lucky*
failure mode — had ownership happened to line up, the executor and
database settings would simply never have applied, with no error
anywhere.

**Fix — Airflow's actual override mechanism, environment variables on the
systemd units:**

```ini
Environment=AIRFLOW__CORE__EXECUTOR=SequentialExecutor
Environment=AIRFLOW__CORE__LOAD_EXAMPLES=False
Environment=AIRFLOW__CORE__DAGS_FOLDER=/opt/airflow/dags
Environment=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
```

### The IAM permission chain — five separate gaps, found one at a time

Each of these produced a distinct `AccessDenied`/`UnauthorizedOperation`,
found only by actually running the deploy workflow — not by review.

1. **S3 write to `_airflow-dags/`** — the CI deploy role had read access to
   the wheelhouse prefix but no write access to the DAG-deploy prefix at
   all. Two different prefixes, two different grants.

2. **`ssm:SendCommand`** — needed to push the synced DAG file onto the
   instance. Required **two** resource ARNs together — the target
   instance *and* the document (`AWS-RunShellScript`) — omitting either
   produces the same generic `AccessDeniedException`.

3. **The tag-condition trap** — combining the instance and the document in
   *one* statement with a `ssm:resourceTag/Environment` condition failed,
   because the condition applies to *every* resource in that statement,
   and `AWS-RunShellScript` is an AWS-owned document with no tags at all —
   it can never satisfy a tag condition. **Fix: split into two
   statements** — the tag condition on the instance only, an unconditional
   allow on the document.

```hcl
{
  Sid = "SendCommandToAirflowDevInstance"
  Action = ["ssm:SendCommand"]
  Resource = ["arn:aws:ec2:${var.region}:${var.account_id}:instance/*"]
  Condition = { StringEquals = { "ssm:resourceTag/Environment" = "dev" } }
},
{
  Sid = "SendCommandToAirflowDevDocument"
  Action = ["ssm:SendCommand"]
  Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
}
```

4. **`ssm:GetCommandInvocation`/`ListCommandInvocations`** — required to
   poll the async command's result. These two actions **do not support
   resource-level restriction** in IAM at all — `Resource = "*"` is the
   correct, most-scoped form available, not an oversight.

5. **`ec2:DescribeInstances`** — needed to resolve the running instance's
   ID by tag before sending the command. Present on dev "for free" via
   the broader `ReadOnlyAccess` managed-policy attachment; **absent on
   prod**, which deliberately doesn't have that attachment, so this gap
   only surfaced on the prod side. Fixed with a narrowly scoped statement
   rather than attaching the broad policy to prod too.

**Interview-ready framing for this whole chain:** SSM's permission model
requires stacking several distinct actions and resource types — control
plane (`SendCommand`), result retrieval (`GetCommandInvocation`), and
discovery (`DescribeInstances`) — each with its own resource-ARN rules,
some of which don't support scoping at all. A single "SSM access" grant
doesn't exist; each capability has to be reasoned about and granted
separately.

### The SSM interface endpoint gap

Discovered that `ssm start-session`/`send-command` need **network path**,
not just IAM permission, when the target is in a NAT-less private subnet:

```bash
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=..."
# empty result = agent can't register, likely no network path
```

**Fix:** three VPC interface endpoints — `ssm`, `ssmmessages`,
`ec2messages` — none of which existed. IAM permission without network
path produces the same symptom as no IAM permission at all, which makes
this class of bug slower to diagnose than a pure permissions issue.

**Cost-conscious toggle, different pattern from the EC2 instances:**
interface endpoints hold no state, so destroy/recreate (not stop/start)
is the correct toggle — a simple boolean controlling `count`/`for_each`:

```hcl
variable "enable_ssm_endpoints" {
  type    = bool
  default = false   # off by default; real cost while running (~£1/day)
}
```

---

## Key decisions, summarised

| Decision | Why | Cost/tradeoff accepted |
|---|---|---|
| Two EC2 instances for Airflow, not shared or local | Only version preserving the dev-proves-before-prod CI pattern | ~£9-10 over the working window |
| SequentialExecutor + SQLite | Matches a single linear DAG's actual concurrency needs | Not production-grade at scale — stated plainly |
| Wheelhouse built natively, not cross-resolved | `pip download --platform` unreliable for old pinned transitive deps | Extra throwaway-instance step |
| Explicit version pin on every install command | Constraints file alone doesn't anchor a transitively-pulled package | More verbose commands, deliberately |
| Dec 2010 duplicate rate as a named exception, not a wider threshold | A threshold wide enough to cover 35% would hide a real anomaly anywhere else | Test is less "clean" but actually protective |
| SSM endpoints toggled off by default | Real, larger-than-expected cost (~£1/day) if left running | Must remember to enable before debugging sessions |

## Commands worth having memorised, not just in a file

```bash
# SSM session into an instance
aws ssm start-session --target <id> --profile retail-dev

# Port-forward to reach the Airflow UI (no public IP exists)
aws ssm start-session --target <id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}' \
  --profile retail-dev

# Check if SSM can even see an instance (network-path diagnosis)
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=<id>"

# Force-replace an instance without destroying anything else
terraform plan -replace='aws_instance.airflow["dev"]' -out=tfplan

# Confirm the wheelhouse before it ever reaches an instance
ls /tmp/wheelhouse | grep -i "^apache_airflow-"
```

---

## Terraform mechanics worth knowing cold

### CI's `terraform plan` runner is stateless — and that's correct, not a gap

Every `pr-checks.yml` run starts on a **fresh GitHub-hosted runner** — no
disk persists between runs, no `.terraform/` directory carries over, no
memory of any previous plan. And yet `terraform plan` on that fresh
runner correctly detects drift, computes an accurate diff, and knows
exactly what already exists in AWS. That only works because of one
specific design decision, and it's worth being able to explain precisely.

**Where state actually lives:** the S3 backend, not the runner.

```hcl
# backend config (providers.tf or similar)
backend "s3" {
  bucket       = "sd-retail-tfstate-009073574996-eu-west-2-an"
  key          = "platform/terraform.tfstate"
  region       = "eu-west-2"
  use_lockfile = true
}
```

**What actually happens on every single run, local or CI, identically:**

1. `terraform init` downloads providers **and** fetches the current
   `terraform.tfstate` object from S3 — this is the step that makes a
   stateless runner behave as if it "remembers" everything. It doesn't
   remember anything; it re-reads the single source of truth every time.
2. `terraform plan` reads that fetched state, then calls the AWS API to
   describe every resource the state says should exist — this is the
   *real* drift detection, not a diff against memory. If a resource
   exists in state but AWS says it's gone, or exists in AWS but differs
   from what's recorded, that's what shows up in the plan.
3. On `apply`, Terraform **locks** the state object before writing
   (`.tflock`, via `use_lockfile = true`) so two concurrent applies —
   say, a manual apply and a CI apply firing at the same moment — can't
   corrupt each other. The lock is itself just another S3 object, not
   anything runner-local.
4. After apply, the **updated** state gets written back to that same S3
   key. The runner is destroyed. Nothing about this run persists
   anywhere except that one S3 object.

**Why this is the correct design, not an accident:** it means local
`terraform plan` (your laptop) and CI's `terraform plan` (a fresh
GitHub runner) are **guaranteed to see the same reality**, because both
are reading and writing the exact same S3 object — there's no
"CI's version of state" versus "my local version of state" to
accidentally diverge. If they ever showed different plans for the same
commit, that would mean the S3 fetch itself failed or hit a lock
conflict — not that CI and local disagree about the world.

**The IAM grant that makes this work — and only this, deliberately narrow:**

```hcl
{
  Sid      = "TerraformState"
  Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
  Resource = [
    "arn:aws:s3:::${local.tfstate_bucket}/${local.tfstate_key}",
    "arn:aws:s3:::${local.tfstate_bucket}/${local.tfstate_key}.tflock",
  ]
}
```

Scoped to exactly those two object keys — the state file and its lock
file — not the whole bucket. The CI deploy role can read/write *its own*
state, and nothing else in that bucket, even if other state files existed
there for other projects.

**What "statelessness" does NOT mean here, worth being precise about in
an interview:** the *runner* is stateless (fresh disk every run); the
*infrastructure's state* is absolutely not stateless — it's a single,
durable, S3-backed source of truth that every run, local or CI, converges
on. Conflating "the compute is ephemeral" with "there's no state" is the
mistake to avoid saying out loud.

**How this differs from a plain local backend (no S3), for contrast:**
without a remote backend, `terraform.tfstate` would live as a file on
whichever machine ran `apply` last. CI, running on a fresh disk every
time, would have **no state at all** to read — every CI plan would think
nothing exists yet and try to create everything from scratch. The S3
backend isn't an optional nicety here; it's what makes running Terraform
from a stateless CI runner possible at all.

**Quick way to demonstrate you understand this, if asked:** run
`terraform plan` locally, then immediately run it again from a
completely different machine (or just `rm -rf .terraform && terraform
init` to simulate a fresh runner) without changing any `.tf` file.

```bash
rm -rf .terraform .terraform.lock.hcl
terraform init
terraform plan
```

Expect: **identical plan output**, typically `No changes.` — proving the
state came from S3, not from anything that was sitting on disk.

---

## Terraform setup and validation — in full, what/why/when

### The backend — what, why, when

**What:** an S3 bucket holding a single `terraform.tfstate` object, with
native S3 locking (`use_lockfile = true`) rather than a separate DynamoDB
lock table.

```hcl
terraform {
  backend "s3" {
    bucket       = "sd-retail-tfstate-009073574996-eu-west-2-an"
    key          = "platform/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
  }
  required_providers {
    aws  = { source = "hashicorp/aws",  version = "~> 5.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
  required_version = ">= 1.10"
}
```

**Why `use_lockfile` over DynamoDB:** this is a genuinely newer Terraform
feature (native S3 conditional-write locking) that removes a second piece
of infrastructure to provision, IAM-grant, and pay for, purely to hold a
lock. One bucket does both jobs. The tradeoff worth naming if asked: the
DynamoDB approach is more battle-tested and has been the standard advice
for years; native S3 locking is newer and less universally documented,
which is exactly why the *why* needs stating rather than assumed.

**Why `required_version >= 1.10`:** that's the minimum version that
actually supports `use_lockfile`. Pinning it means CI fails clearly at
`terraform init` if someone's local Terraform is too old, rather than
failing confusingly later at `apply` with a locking error.

**When state gets read/written:** every `init` reads it; every `plan`
reads it (to compute the diff against real AWS state); every successful
`apply` writes it back; the `.tflock` object exists only for the duration
of an in-progress `apply`.

### `terraform fmt` — what, why, when, and the exit code that isn't what you'd guess

**What:** rewrites `.tf` files to Terraform's canonical style — spacing,
alignment, indentation. No functional change, ever.

```bash
terraform fmt              # rewrites files in place
terraform fmt -check       # reports only, changes nothing
terraform fmt -check -diff # reports AND shows what would change
```

**Why it matters as a CI gate, not just a nicety:** consistent formatting
means diffs in PRs show only real changes, not noise from someone's
editor re-indenting a block. On a solo project this feels optional; on
any team it's the difference between a reviewable diff and a wall of
whitespace changes hiding the real one-line edit.

**The exit code trap, hit for real in this project:** `terraform fmt
-check` returns **exit code 3** when files need formatting — not 0
(success) and not the more commonly assumed 1 (generic error). CI
reported "Terraform exited with code 3" with a file list, which initially
looked like a `plan` failure. It was `fmt -check` failing at an earlier
step in the same job. **The lesson:** don't diagnose a Terraform CI
failure from the exit code alone — find the actual command and its
`Error:` text, because different Terraform subcommands use different exit
code conventions for different meanings.

**When to run it:** habitually, before every commit that touches `.tf`
files — not just when CI catches it. Cheaper to catch locally.

### `terraform validate` — what, why, when

**What:** checks syntax and internal consistency (references to
undeclared resources, type mismatches, malformed blocks) **without**
contacting AWS at all — no credentials needed, no state read.

```bash
terraform validate
```

**Why it's a separate step from `plan`, not skipped:** it's near-instant
and catches a whole class of errors (typos in resource attributes, wrong
variable types) before spending time on a full AWS-backed plan. In this
project it was the fast confirmation that a large hand-edited file (like
the `iam.tf` rewrite) was at least structurally sound before the slower
`plan` step.

**When it won't catch something:** anything that's syntactically valid
but semantically wrong for AWS — a wrong ARN format that's still a valid
string, a permission scoped to the wrong resource, a tag condition that
can never be satisfied (the SSM document tag-condition bug from Day 3).
`validate` passing is necessary, never sufficient.

### `terraform plan` — what, why, when, and its exit codes

**What:** computes a diff between current state (read from S3) and the
desired configuration, without changing anything.

```bash
terraform plan                          # human-readable, exits 0 or 1
terraform plan -out=tfplan              # saves the plan for a guaranteed-matching apply
terraform plan -detailed-exitcode       # 0=no changes, 1=error, 2=changes present
terraform plan -replace='aws_instance.airflow["dev"]'   # force one resource to destroy+recreate
```

**Why `-out=tfplan` before `apply`, not `apply` directly:** a saved plan
file guarantees `terraform apply tfplan` performs *exactly* what was
reviewed — no risk of the underlying AWS state shifting between review
and execution, and no risk of `apply`'s own interactive prompt approving
something different from what was actually read. This project always
used the two-step form for anything non-trivial.

**Note the different exit-code scheme from `fmt -check`:** `plan
-detailed-exitcode`'s `2` means "changes present," a completely different
meaning from `fmt -check`'s `3`. Conflating these two schemes is exactly
the kind of mistake that made the fmt failure look like a plan failure
initially.

**Why `-replace` rather than `taint` (deprecated) or manual state
surgery:** `-replace` is the current, explicit way to force a specific
resource through destroy-then-create without touching anything else in
the plan. Used repeatedly to relaunch the Airflow instances after
bootstrap-script fixes, without disturbing IAM, S3, or any other
resource.

**When CI runs `plan`:** on every PR, posted as a PR comment (so a
reviewer sees the infrastructure impact without checking out the branch)
— never followed by an automatic `apply`. Applying is always a manual,
deliberate step in this project, run locally.

### `terraform apply` — what, why, when

**What:** executes a plan — either freshly computed, or a saved
`-out=tfplan` file.

```bash
terraform apply tfplan     # preferred: guaranteed to match the reviewed plan
terraform apply            # computes a fresh plan and prompts to confirm
```

**Why the saved-plan form is preferred here:** matches the review you
actually looked at. The interactive form re-computes at apply time, which
is a second opportunity for something to have changed underneath you
between review and execution.

**When it's blocked deliberately:** `lifecycle { prevent_destroy = true
}` on the Airflow instances makes `apply` (or `destroy`) refuse to remove
them, throwing a clear error rather than silently terminating a resource
meant to persist across a stop/start cycle. Removing that guard is itself
a deliberate, visible act — not something that happens by accident.

### Import and brownfield adoption — what, why, when

**What:** two mechanisms used to bring already-existing, console-created
AWS resources under Terraform management without recreating them —
`import` blocks (declarative, committed) and
`terraform plan -generate-config-out` (one-time scaffolding of matching
`.tf` from real AWS state).

```hcl
import {
  to = aws_iam_role.dev_pipeline_exec
  id = "retail-dev-pipeline-exec-role"
}
```

```bash
terraform plan -generate-config-out=generated.tf
```

**Why this was needed at all:** the account had resources created by hand
before Terraform existed for this project (ADR 0001). Recreating them
from scratch would mean real downtime and risk; import brings them under
management with zero infrastructure change.

**When `-generate-config-out` output needs cleanup, not blind trust:** it
produces verbose, provider-default-heavy `.tf` that technically matches
reality but is far noisier than hand-written config. Every generated file
in this project was manually tidied — defaults removed, comments added —
before being trusted as the source of truth going forward.

### Variables and tfvars — what, why, when, and the file that's committed on purpose

**What:** three tiers of variable input used differently.

```
terraform.tfvars           # gitignored — local, can contain anything
terraform.auto.tfvars      # COMMITTED — auto-loaded, non-secret identifiers only
terraform.tfvars.example   # committed — documents what a fresh clone needs
```

**Why `terraform.auto.tfvars` is committed, breaking the usual
convention:** CI has no access to a local-only file. The values in it
(Snowflake external IDs, an IAM user ARN, alert email addresses) are
identifiers, not credentials — the external ID is meaningless without the
paired IAM role, itself scoped to two S3 prefixes. Treating them as
secrets by convention, without them actually being secret, would have
meant either duplicating them into GitHub Secrets (a second store to keep
in sync, contradicting the SSM-is-the-source-of-truth principle from ADR
0010) or blocking CI entirely.

**When something in this tier genuinely is sensitive:** it goes through
SSM instead — the Snowflake private key never appears in any `.tfvars`
file, committed or not; it's fetched at runtime by both local `dbt` runs
and CI.

### The `null_resource` power-state toggle — what, why, when

**What:** `null_resource` with a `local-exec` provisioner calling
`aws ec2 start-instances`/`stop-instances`, triggered by a
`triggers` map keyed to a variable.

```hcl
resource "null_resource" "airflow_power_state" {
  triggers = {
    desired_state = var.airflow_instance_state
    instance_id   = aws_instance.airflow[each.key].id
  }
  provisioner "local-exec" {
    command = var.airflow_instance_state == "running" ? "..." : "..."
  }
}
```

**Why a `null_resource` rather than an EC2-native "desired state"
attribute:** Terraform's AWS provider has no first-class "stopped vs
running" resource attribute that maps to `start-instances`/
`stop-instances` API calls — those are imperative actions, not
declarative state Terraform's resource model directly supports. A
`null_resource` with a trigger is the standard workaround for "run an
imperative AWS CLI action when a specific value changes."

**Why the resource "must be replaced" on every toggle (seen in a real
plan last night):** `null_resource` has no actual AWS state to update in
place — a changed trigger doesn't "update" it, it destroys and recreates
the `null_resource` itself (not the EC2 instance) so the provisioner
re-runs. This looked alarming in the plan output the first time
(`-/+ must be replaced`) but only ever affects the tracking resource, not
the instance, which is why it's paired with `prevent_destroy` on the
*instance* resource specifically, not on this one.

### CI's Terraform validation pipeline, end to end — what, why, when

**What actually runs in `pr-checks.yml`, in order, on every PR:**

```yaml
- terraform fmt -check
- terraform init
- terraform validate
- terraform plan -out=tfplan
- (custom step) block destructive changes — parses plan output,
  fails if any "will be destroyed" / "must be replaced" appears without
  explicit override
- post the plan as a PR comment
```

**Why in that specific order:** cheapest, fastest checks first. `fmt` and
`validate` cost nothing (no AWS calls) and catch the most common mistakes
before spending time on a real `plan`. Failing fast on formatting is
cheap; failing fast on a real AWS-backed plan is not.

**Why destroys are blocked by default, not just flagged:** a destroy or
replace is the one class of Terraform action that's genuinely hard to
undo (data loss, downtime). Requiring an explicit, visible override to
let one through means it's never accidental — someone has to consciously
decide "yes, this specific destroy is intended" rather than approve a PR
without noticing a resource listed for deletion in a long diff.

**When this pipeline does NOT run `apply`:** never, automatically. Every
apply in this project's history was a deliberate local action, even after
CI-verified plans. That's a conscious choice, not an oversight — full
CI/CD auto-apply was considered out of scope given the manual verification
this project's incidents (the state-loss postmortem, the several Airflow
IAM gaps) repeatedly showed was still necessary.

---

## Git workflow and validation — in full, what/why/when

### The workflow itself — what, why, when it changed

**What, from partway through the project onward:** every change goes on
a branch, reaches `main` only via PR, no direct pushes to `main`.

```bash
git checkout main && git pull
git checkout -b feat/some-change
# ... work, commit ...
git push -u origin feat/some-change
# open PR, let checks run, merge via GitHub
```

**Why this wasn't the pattern from the very start:** early work (initial
infra, first Snowflake setup) was committed directly to `main` — a
reasonable early-project shortcut when the "team" is one person and
there's no CI yet to gate against. **When it changed:** once CI checks
(`pr-checks.yml`, later `dbt-ci.yml`) existed and were meaningful, direct
pushes stopped making sense — a check that only runs on PRs is worthless
if nothing ever goes through a PR. The switch was explicit and
deliberate, not automatic.

**Why branch protection enforces this rather than relying on habit:**
"Require a pull request before merging" + "Require status checks to
pass" on `main`, set in repo settings. Discipline alone is one missed
`git push` away from bypassing the whole CI investment; the setting makes
a direct push to `main` fail outright.

### PR checks and what triggers them — what, why, when

**What triggers `dbt-ci.yml`'s two jobs differently:**

```yaml
on:
  pull_request:
    branches: [main]
    paths: ['dbt/**', '.github/workflows/dbt-ci.yml']
  push:
    branches: [main]
    paths: ['dbt/**', '.github/workflows/dbt-ci.yml']
```

```yaml
jobs:
  compile:
    if: github.event_name == 'pull_request'
  build:
    if: github.event_name != 'pull_request'
```

**Why path filters, not "run on every PR regardless of files changed":**
a PR touching only `docs/` shouldn't spend CI minutes on a dbt compile
that can't possibly be affected. Scoped triggers keep CI meaningful and
fast — a green check should mean "this specific area was verified," not
"something, somewhere, ran."

**Why `compile` (read-only) on PRs but `build` (writes to dev, runs
tests) only on merge:** a PR is by definition not-yet-trusted code;
running real writes against the dev warehouse for every draft PR would
mean dev's data could be churned by unmerged, possibly-abandoned branches.
`build` only running post-merge means dev only ever reflects what's
actually landed on `main`.

**When a workflow file itself needs to already be on `main` to fire:**
`pull_request`-triggered workflows are evaluated using the workflow
definition **on the base branch**, not the PR branch. A new workflow file
added only on a feature branch will not run as a PR check for that same
PR — it has to reach `main` first (via an earlier merge, or by being
present before the PR is opened) before GitHub will execute it as a
required check. Hit directly in this project: a new `dbt-ci.yml` had to
land on `main` before the PR meant to exercise it would actually show the
check running.

### OIDC and the subject claim — what, why, when it silently changes

**What:** GitHub Actions authenticates to AWS via short-lived
federated tokens (OIDC), not static access keys — no long-lived
credential exists anywhere in this project for CI to leak.

```hcl
principal = { Federated = aws_iam_openid_connect_provider.github.arn }
condition {
  StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
  StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:OWNER@ID/REPO@ID:*" }
}
```

**Why the ID-qualified subject form (`OWNER@OWNER_ID/REPO@REPO_ID`)
rather than the plainer `OWNER/REPO` form:** this repo has "include
enterprise/organization and repository IDs in the OIDC token subject"
enabled. IDs are immutable; a repo rename or an ownership transfer to a
different account that happens to reuse the same name cannot silently
inherit trust that was meant for the original repo.

**Why the `sub` claim's *shape* changes based on how a job is
triggered — and why this bit hardest on prod specifically:**

| Trigger | Subject claim suffix |
|---|---|
| Pull request | `:pull_request` |
| Push to a branch | `:ref:refs/heads/main` |
| Job declaring `environment: NAME` | `:environment:NAME` |

The dev deploy role matched with a wildcard (`:*`), so it kept working
regardless of which form showed up. The **prod** role was written to
match only the ref-based form and failed with a generic "not authorized"
the moment the prod job started declaring `environment: prod` — because
declaring an environment **changes the claim's shape entirely**, it
doesn't add to the ref-based one. **When this needs re-checking:** any
time a workflow job's trigger type or `environment:` declaration changes,
the corresponding trust policy's `sub` match needs re-verifying, not
assumed to still apply.

**Why prod's policy deliberately uses `StringEquals` +
`environment:prod`, not a wildcard:** this is a second real gate beyond
the trust policy — the GitHub *environment* itself carries "restricted to
`main` branch" and "required reviewer" rules, evaluated by GitHub
**before** it even mints a token. So prod deploys pass two independent
gates (branch restriction, human approval) where a ref-based policy alone
only ever enforced one.

### Merge conflicts encountered — what, why, when

**What happened:** a new file (`dbt-ci.yml`) was pushed both directly to
`main` and separately on a feature branch, with no common ancestor for
git to diff against — git's merge produced ten conflicting regions
inside what was, in each version, otherwise-identical intent (one had a
bug fix the other didn't).

```bash
git checkout ci/verify-dbt
git fetch origin
git merge origin/main
# conflict reported
git checkout --ours .github/workflows/dbt-ci.yml   # keep the branch's version
git add .github/workflows/dbt-ci.yml
git commit --no-edit
```

**Why `--ours` was correct here specifically, not generally:** because
the branch's version was verified to contain the more-correct fix (the
`trap`-timing bug fix). `--ours`/`--theirs` should never be reached for
without first knowing *which* side is actually right — it's a resolution
mechanism, not a default.

**When this class of conflict is avoidable entirely:** new files should
be added on a branch and reach `main` only through the merge — never
pushed to both places independently. That's the actual lesson, not "how
to resolve the conflict" but "how the conflict was caused" — worth
stating both if asked.

### `git pull` after a PR merge — what, why, when it's a no-op vs a real fetch

**What a clean post-merge pull looks like:**

```bash
git checkout main
git pull
# Fast-forward
#  .github/workflows/dbt-ci.yml | 54 +++++++++++++++++++++++++------------------
```

**Why "Fast-forward" specifically, and why that's the good case:** it
means local `main` had no commits of its own beyond what origin already
had — git just moves the local branch pointer forward to match origin,
no merge commit needed, no possibility of conflict. **When it would
instead require a real merge:** if local `main` had any commits origin
didn't have (e.g., an accidental direct commit before the branch-workflow
habit was fully adopted), git would need an actual three-way merge or
rebase instead of a simple fast-forward — and that's exactly the
situation the branch-only-workflow is designed to prevent from ever
happening on `main`.

### `.gitignore` precision — what, why, when a negation pattern is needed

**What:**

```
*.tfvars
!terraform.auto.tfvars
!terraform.tfvars.example
```

**Why the broad pattern plus explicit negations, rather than just
listing the one real secret file to ignore:** `*.tfvars` is the safe
default — anyone creating a new `.tfvars` file for local experimentation
gets it ignored automatically, without needing to remember to add it to
`.gitignore` themselves. The negations are the deliberate, visible
exceptions — a reviewer scanning `.gitignore` sees explicitly which
`.tfvars` files are meant to be public, rather than that being implicit
or accidental.

**When a file needs force-adding despite a broad ignore pattern:**

```bash
git add -f infra/terraform/terraform.auto.tfvars
```

Needed the first time such a file is created, since even a `!negation`
pattern in `.gitignore` doesn't retroactively un-ignore a file that
`git status` already isn't tracking — worth knowing this one-time
`-f` step rather than being surprised the negation "isn't working."
