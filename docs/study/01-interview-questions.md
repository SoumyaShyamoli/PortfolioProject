# Interview Study Guide — Part 1: Questions and Model Answers

Covers every decision made in the platform so far. Read the question, try to
answer it out loud before reading on. Recognition is not recall; the gap
between "that sounds right" and being able to produce it cold is the whole
point of this document.

Questions marked **[hard]** are the ones a senior interviewer would use to
separate candidates. Questions marked **[trap]** have a tempting wrong
answer.

---

## 1. Storage design

### Q1.1 — Why six buckets rather than one bucket with prefixes?

Bucket-level IAM policies are simpler to write and easier to audit than
prefix-scoped ones, and prefix conditions are easy to get subtly wrong — a
missing trailing slash or a wildcard in the wrong place silently widens
access. Lifecycle rules and versioning also apply per bucket, so different
retention for raw versus curated falls out naturally rather than needing
per-prefix filters.

The cost is six resources to manage instead of one, which Terraform makes
irrelevant.

### Q1.2 — Walk me through what lives in each layer

- **raw** — NDJSON, partitioned `event_date=YYYY-MM-DD`, exactly as it
  arrived. Cancellations, negative quantities, null customer IDs and
  duplicates all intact. Written once, never modified.
- **staged** — Parquet, Snappy-compressed, partitioned `year=/month=`.
  Same rows, columnar. Format conversion only, no cleaning. Also holds
  `_audit/recon/` run records.
- **curated** — currently empty. Reserved for the Databricks lakehouse
  variant. In the Snowflake path, curated marts live inside the warehouse,
  not in S3.

### Q1.3 **[hard]** — You have a curated bucket with nothing in it. Isn't that a design smell?

It's a hybrid, and worth being explicit about. The medallion pattern assumes
all three layers are files in a lakehouse. This platform's warehouse is
Snowflake, so the cleaned and modelled data lives in `RETAIL_DEV.MARTS`
rather than in S3.

Rather than delete the bucket or invent a use for it, it's provisioned for
the planned Databricks re-platforming, where Delta tables genuinely will land
there. That's documented in the README's known-gaps section, because an
unexplained empty bucket reads as carelessness while a documented one reads
as a decision.

### Q1.4 — Why is raw immutable, and how is that enforced?

Raw is the replay point. Every downstream correction — a bug in the cleaning
logic, a changed business rule about what counts as a cancellation — is
recoverable by reprocessing from raw. If raw were cleaned on ingest, the
original would be gone and the mistake permanent.

Enforced through IAM: the Glue pipeline execution role has only `GetObject`
and `ListBucket` on the raw buckets. No `PutObject`, no `DeleteObject`. It is
structurally incapable of modifying its own input.

### Q1.5 **[trap]** — Your pipeline role has `s3:DeleteObject` on staged. Isn't that dangerous?

It's required, and it's safe for a specific reason.

Required because dynamic partition overwrite works by deleting the existing
files in a partition before writing new ones. Without delete permission,
every re-run fails — which would defeat the idempotency the whole design
rests on.

Safe because staged is fully reproducible from raw. A compromised or buggy
job can destroy staged data, and the recovery is to re-run the conversion.
That is precisely why raw has no delete grant: the layer that cannot be
regenerated is the one that is protected.

### Q1.6 — Why does versioning differ across your buckets?

It's inherited drift, deliberately frozen rather than silently normalised.
Versioning was enabled by hand on `prod-raw` and `prod-staged` and not on the
other four. The Terraform import surfaced that.

Two options: normalise everything, or adopt what exists and make it explicit.
The second was chosen, with versioning scoped through an explicit
`versioned_bucket_keys` list, because adopting reality first and changing it
deliberately afterwards is the safer pattern — especially on buckets that
will hold data.

The consequence is documented: the four unversioned buckets have no
versioning resource at all, so Terraform will not correct drift on them.
That's an accepted gap with a stated trigger for revisiting — if the raw
layer starts holding data that cannot be regenerated.

### Q1.7 — What's your retention policy and what does it cost you?

Raw transitions to Standard-IA after 30 days; non-current versions expire
after 90 days.

The second one has a real consequence worth naming: a version older than 90
days is gone, which caps how far back a replay can reach. For a dataset
that's a static historical file this is theoretical, but on a live pipeline
it would be the answer to "how far back can you reprocess?"

---

## 2. Networking

### Q2.1 — Why no NAT gateway?

Cost, primarily — roughly £30/month per gateway in eu-west-2, billed hourly
whether or not a byte moves, against a £10 total project budget. Two AZs done
properly means two of them.

But the replacement is better, not merely cheaper. S3 is reached through a
gateway VPC endpoint, and that traffic stays on the AWS network rather than
leaving the VPC, hitting a public S3 endpoint and coming back. Cost and
security align, which is rare enough to be worth stating.

### Q2.2 **[hard]** — What's the difference between a gateway and an interface VPC endpoint?

**Gateway endpoints** exist only for S3 and DynamoDB. They work by adding a
prefix-list route to your route tables, so traffic to those services is
routed within the AWS network. They are **free** — no hourly charge, no data
processing charge.

**Interface endpoints** are ENIs in your subnets, backed by PrivateLink. They
work for most AWS services. They bill roughly $0.01/hour **per AZ** plus a
per-GB processing charge — so about $15/month for a two-AZ deployment,
whether or not you use them.

Getting this backwards is a common and expensive mistake. An interface
endpoint was created during exploration on this project and deleted once the
distinction was understood.

### Q2.3 — Your Glue job runs in a private subnet with no internet. How does it reach the Glue API?

It turned out not to need to. The first run succeeded without a Glue
interface endpoint, so the deferral was correct.

The design position was to defer creating it until a job actually failed
without it, rather than provisioning speculatively — because interface
endpoints bill hourly whether used or not. If a future job needs Glue API
calls this one doesn't make (catalog operations, job bookmarks), the endpoint
gets added, the cost gets documented, and it gets torn down after testing.

### Q2.4 **[hard]** — dev and prod share a VPC. Defend that.

The resources being protected are S3 buckets, which aren't in the VPC at all
— they're reached through a service endpoint. A separate dev VPC would still
reach prod buckets over that same endpoint. So the boundary that actually
protects the data is the IAM policy on the execution role, not the subnet the
compute sits in.

Given that, a second VPC would have duplicated the cost of anything attached
to it without moving the boundary.

**Where this stops holding:** the moment something network-reachable lives
inside the VPC — an RDS instance, a cache, an internal API, a self-hosted
Superset — the security group becomes the only separation between dev compute
and prod data stores. At that point the honest answer becomes separate AWS
accounts, not separate VPCs.

The framing matters. "Dev and prod share a VPC" sounds like a shortcut. "The
isolation boundary for S3-backed data is IAM, so a second VPC would have cost
money without moving the boundary" is a judgment call.

### Q2.5 — What would you do differently with a real budget?

Separate AWS accounts per environment under an Organization. A hard boundary
that no IAM misconfiguration can cross, plus clean per-environment billing.
That's the correct answer at any real scale, and it's documented in the
README as the arrangement this platform approximates rather than achieves.

### Q2.6 **[trap]** — Why does your Glue security group have a self-referencing rule?

Glue provisions multiple workers in the subnet and they must reach each other
on arbitrary ports. Without a self-referencing rule, jobs fail at startup
with an opaque connectivity error that doesn't point at the security group.

The console-created SG had **no inbound rules at all** — this was caught
during the Terraform adoption, before the first job run rather than after a
confusing debugging session.

---

## 3. IAM

### Q3.1 — Walk me through your role structure.

Five roles split by function, not by person:

| Role | Assumed by | Purpose |
|---|---|---|
| `retail-dev-pipeline-exec-role` | Glue (dev) | Runtime, dev buckets only |
| `retail-prod-pipeline-exec-role` | Glue (prod) | Runtime, prod buckets only |
| `retail-dev-cicd-deploy-role` | GitHub Actions | Deploy to dev, any branch |
| `retail-cicd-deploy-role` | GitHub Actions | Deploy to prod, `main` only |
| `retail-human-admin-role` | Human | Break-glass, inspection |

Plus a separate Lambda execution role for the World Bank ingestion, because
that one **writes** to raw — which the Glue role deliberately cannot do.

Three distinct trust boundaries: runtime compute, automated deployment, human
operation. They fail in different ways and shouldn't share an identity.

### Q3.2 — Why OIDC instead of access keys in GitHub secrets?

Static access keys in CI are the most commonly exfiltrated AWS credential in
practice. They must be rotated, audited, and hoped not to leak. Federated
short-lived tokens have no equivalent artefact to steal.

The production role's trust additionally constrains the `sub` claim to
`repo:OWNER/REPO:ref:refs/heads/main`, so a pull request from a fork cannot
obtain production credentials. That's the specific attack it guards against.

### Q3.3 **[hard]** — Your builder identity has `IAMFullAccess`. How is that least privilege?

It isn't, and pretending otherwise would be worse than admitting it.

For the duration of the build, the human operator effectively holds
administrative capability. In a team this would be split — a platform
engineer who can create roles, an analyst who cannot — with elevated
capability assumed temporarily rather than held permanently. It isn't split
here because there is one person, and over-restricting the sole builder
produces a month of permission errors and no security benefit.

The discipline is applied where it demonstrates something: the service roles,
which are scoped to specific buckets, specific prefixes, and specific
actions.

What's defensible about the builder identity is that permissions were added
**on demand** rather than granted up front. Terraform failed on
`ec2:CreateTags` when adopting the VPC, and `AmazonVPCFullAccess` was added
in response — chosen over `AmazonEC2FullAccess` because the platform manages
network resources but never launches instances. Each addition traces to a
specific operation.

### Q3.4 — Why does the CI/CD role need `iam:PassRole`?

A deploy role that creates Glue jobs must be able to hand the execution role
to Glue. Without `PassRole`, job creation fails.

It's scoped tightly: to that one role ARN, with a condition requiring
`iam:PassedToService = glue.amazonaws.com`. So it cannot pass a more
privileged role, and it cannot pass that role to a different service.

Unscoped `iam:PassRole` is a well-known privilege escalation path — it lets a
low-privilege principal hand a high-privilege role to a service it controls.

### Q3.5 — You keep `AWSGlueServiceRole` attached alongside your scoped inline policy. Why?

It's AWS's recommended baseline for Glue service roles, and it provides the
EC2 network permissions (`CreateNetworkInterface`, `DescribeSubnets`) that a
VPC-attached job needs.

It's also broader than the inline policy — it grants access to any bucket
named `aws-glue-*` plus wide Glue and CloudWatch permissions. The open
question is whether the scoped inline policy alone would suffice now that the
job runs successfully. That's a documented follow-up rather than a settled
answer, and either resolution is defensible as long as it's a decision rather
than a default.

---

## 4. Infrastructure as code

### Q4.1 — You built everything in the console first. Why?

Deliberate, for a first pass: console work gives faster feedback while
learning an unfamiliar service, and it's easier to understand what a resource
does before expressing it as code.

The cost is that it leaves working infrastructure with no source of truth —
nothing reviewable, nothing reproducible, and the only record of why a
setting was chosen is in the person who clicked it. Which is why the next
step was bringing it under Terraform.

### Q4.2 **[hard]** — Why import rather than destroy and recreate?

Three reasons.

**Adoption preserves the audit trail.** Recreating produces identical-looking
resources with new creation timestamps, and for the OIDC provider it would
have briefly broken CI/CD trust.

**Import surfaces drift; recreation hides it.** The import revealed that
versioning was inconsistent across buckets and that a lifecycle rule believed
to exist on `prod-raw` had never actually saved — the import failed with
"Cannot import non-existent remote object". Neither would have been noticed
otherwise, and both are the kind of gap that only shows up during an
incident.

**Brownfield adoption is the common case.** Greenfield IaC is the tutorial
scenario. Most teams inherit click-ops and have to bring it under management
without downtime. Destroy-and-recreate is a workflow that stops working the
moment there's data in the bucket.

### Q4.3 — What went wrong during the import?

Three things, all instructive.

**Import blocks were deleted before `apply`, not after.** A successful `plan`
made it look done. Terraform then saw configuration with no matching state
and tried to create everything, failing with `EntityAlreadyExists` on all
five roles. Nothing was created and nothing was half-applied, because IAM
rejected each call outright. The rule: import blocks are consumed at apply
time, and are removed only once `plan` reports no changes against the
post-apply state.

**Generated configuration wasn't valid.** `-generate-config-out` emitted the
OIDC provider's URL without its scheme, which the AWS provider's own
validator then rejected. Generated config reflects the API response, not
necessarily valid HCL.

**A false-negative discovery query.** An early `describe-vpc-endpoints` used
a placeholder VPC ID and returned nothing, which looks identical to the
resource not existing. The plan was built on that assumption, and only the
apply caught it — with a `RouteAlreadyExists` error naming a prefix list
rather than an endpoint, which is only obvious if you know a gateway
endpoint's route entry *is* a prefix-list route.

### Q4.4 — What's the difference between the S3 resource model in provider v3 and v4+?

In v4 and later, a bucket's versioning, encryption, lifecycle and public
access settings are each a **separate resource** rather than inline blocks on
`aws_s3_bucket`. Six buckets became roughly twenty resources, each needing
its own import block.

Guides written before that change are actively misleading, and it's a common
source of confusion when following older tutorials.

### Q4.5 **[trap]** — Why did you use inline `ingress`/`egress` blocks on the security group when HashiCorp recommends separate rule resources?

Because of an import gotcha. An `aws_security_group` declared with **no**
inline blocks doesn't leave existing rules alone — it treats them as an empty
set and revokes them on first apply.

Separate `aws_vpc_security_group_ingress_rule` resources are the modern
recommendation and are better for greenfield. For adopting an existing SG,
inline is the safer path. Worth knowing both and why the choice differs by
situation.

### Q4.6 — Where's your Terraform state and why does it matter?

Currently local, which is the honest answer and also a gap. The
portfolio-correct arrangement is an S3 backend with `use_lockfile = true` —
native S3 locking, no DynamoDB table needed, which most guides still tell you
to create.

State matters because it can contain resource attributes in plaintext,
sometimes including secrets. `*.tfstate` and `*.tfvars` are gitignored for
that reason. Committing state to a public repo is a genuine security
incident and it happens constantly.

---

## 5. The Glue job

### Q5.1 — Why Glue and not EMR?

Idle cost, for a bursty workload. EMR bills for the cluster's existence; Glue
bills per DPU-second of execution. For a job that runs a few minutes per
month and does nothing in between, that's the difference between a few pounds
and the whole budget.

The transferable skill is nearly identical — Glue jobs are PySpark, same
DataFrame API, same partitioning strategy, same debugging. What EMR adds is
cluster lifecycle management, which a 1M-row workload doesn't exercise
anyway.

**The honest framing:** "chose serverless to avoid idle cost on a bursty job"
is a cost-versus-control judgment. "I ran EMR" is not a judgment at all.

### Q5.2 **[hard]** — 1M rows doesn't need Spark. Why is it there?

It doesn't, and claiming otherwise wouldn't survive a follow-up.

The defensible version: Spark is used for the format conversion and
partitioning, at a scale where the tool choice was about operational cost
rather than needing horizontal scale. The alternative — pandas in a Lambda —
was genuinely viable and cheaper.

It's in the platform because the partitioned columnar conversion is what
makes the storage design meaningful, and because a data platform with no
distributed processing component doesn't exercise a skill the project is
meant to demonstrate. That's partly a portfolio consideration rather than a
purely technical one, and saying so is better than being caught out.

### Q5.3 — Why monthly partitions and not daily?

Three reasons.

**Small files.** At ~1,400 rows/day, daily Parquet files would be ~30KB and
there'd be 730 of them. Object listing dominates read time at that shape.
Monthly gives ~40,000 rows and 1-2MB across 25 partitions.

**Cost.** Glue has a one-minute minimum billing increment, so a run costs
~2-3p regardless of how little work it does. 730 daily runs is £15-20 against
a £10 budget; 25 monthly runs is under £1. The minimum increment, not the
compute, is what makes fine-grained runs expensive.

**Yearly was rejected** — three partitions demonstrate nothing about pruning,
and three increments isn't an incremental loading story.

### Q5.4 — Raw is daily but staged is monthly. Why the mismatch?

Deliberate. Raw optimises for fidelity and replay — daily is the honest
representation of how event data arrives, and it lets a single bad day be
re-dropped without touching its neighbours. Staged optimises for query.

### Q5.5 **[hard]** — Explain how your job achieves idempotency.

`spark.sql.sources.partitionOverwriteMode = dynamic` combined with
`mode("overwrite")`. That replaces only the partitions present in the current
write, leaving every other partition untouched. Without the dynamic setting,
`overwrite` would wipe the entire output path.

Three things make it actually hold:

1. **One run owns one partition.** The job takes `--year` and `--month`
   rather than a file key, so a caller can't point it at a single day. If a
   run processed one day while partitioning by month, that write would
   replace the entire month with one day's rows.

2. **A stray-row guard.** Partition keys are derived from `invoice_date` in
   the data, not from the arguments — so a misfiled object lands where it
   belongs. But that creates a risk: a November-dated row inside a December
   file would create a `year=2010/month=11` partition containing only that
   row, overwriting November's real data. The job counts rows outside the
   target month and fails before writing if any exist.

3. **`max_concurrent_runs = 1`.** Two concurrent runs on the same month would
   both overwrite the same partition and the loser's rows vanish.

4. **`s3:DeleteObject`** on the pipeline role, without which the overwrite
   fails entirely.

### Q5.6 — Why did you disable job bookmarks?

The job is already idempotent by design. Bookmarks would add hidden state
that makes reprocessing a month harder rather than easier — reprocessing
should be as simple as running it again with the same arguments.

### Q5.7 — Why `timeout = 15` on the Glue job?

Glue's default is 2880 minutes — 48 hours. A hung job at that timeout would
cost more than the entire project budget. It's the single most important line
in the Terraform for cost safety.

### Q5.8 — Why `coalesce(1)` before writing?

Without it, Spark writes one output file per input partition — 30 tiny
Parquet files per month. Coalescing to a single file per partition avoids the
small-file problem at this scale.

At larger scale this would be wrong: coalescing to one file forces all data
through a single writer and creates a bottleneck. The right answer there is
target file size, typically 128MB-1GB.

---

## 6. Reconciliation and data quality

### Q6.1 — Walk me through your reconciliation.

Three independent counts, which must balance:

```
source_lines = corrupt_rows + undated_rows + rows_written_back
```

1. **`source_lines`** — the raw files read as plain text via
   `spark.read.text()` and counted. NDJSON is one record per line, so this is
   ground truth for "how many records arrived", entirely independent of
   whether Spark can parse them.

2. **`corrupt_rows`** — captured via a `_corrupt_record` column in PERMISSIVE
   mode.

3. **`rows_written_back`** — the written Parquet partition read back from S3.

Plus `undated_rows`, which are excluded from the write because they have no
partition key.

### Q6.2 **[hard]** — Why fail the job rather than log a warning?

Because a silent shortfall is indistinguishable from success.

If a run drops 5% of a month's rows, every downstream check still passes —
dbt tests run against what loaded, dashboards render, nothing errors. The
only way to notice is to have known the expected count beforehand, which is
exactly what the recon computes. Logging it means the number exists but
nobody looks — and the failure mode being guarded against is precisely the
one where nobody looks.

There's an escape hatch (`--fail_on_recon_mismatch false`) for pushing a
known-bad day through deliberately. The default is to fail.

**The trade-off to acknowledge:** a genuine data anomaly stops processing
until a human looks. That's right for a platform where correctness matters
more than availability, and wrong for one where it doesn't. Worth stating
which assumption you're making.

### Q6.3 **[trap]** — Why read the data back from S3? You already have the count in the DataFrame.

An in-memory count confirms Spark's intent, not S3's state. The read-back is
the only step that confirms what's actually in the bucket — which is what
downstream consumers will read.

### Q6.4 — What does `_corrupt_record` do and why does it matter?

In PERMISSIVE mode with an explicit schema, Spark turns unparseable JSON
lines into all-null rows by default. They pass through into your data
silently.

Adding `_corrupt_record` to the schema and setting
`columnNameOfCorruptRecord` captures those lines as text in that column, so
they become countable rather than invisible. The job filters them out before
writing and accounts for them in the recon.

### Q6.5 — What happens to rows with an unparseable date?

They have no `year`/`month` value, so they'd land in Hive's
`__HIVE_DEFAULT_PARTITION__`. They're excluded from the write and subtracted
explicitly in the recon equation, rather than absorbed into a tolerance — so
a non-zero count is visible rather than hidden.

The documented follow-up is to route them to a quarantine prefix instead of
discarding them.

### Q6.6 **[hard]** — How does the audit record become useful rather than just being written?

It accumulates into a queryable dataset — via Athena over the `_audit`
prefix, and loaded into Snowflake as an operations table.

That enables an end-to-end chain where every hop has a number:

```
local profiling counts
  → Glue recon (source → parsed → written to S3)
  → Snowflake load count
  → dbt staging row count
```

A dbt test comparing staging row counts against the sum of
`rows_written_back` for the same periods is a real control. It catches a
partial COPY, a silently skipped file, or a partition that never loaded.

The quality metrics also become test thresholds: staging drops cancellations
and null customer IDs, and the audit record says how many there should have
been. If staging drops 400 rows but the audit recorded 380 cancellations,
the cleaning logic is wrong.

Most portfolios claim data quality. This produces numbers that either tie out
or don't.

### Q6.7 — Why does the job not clean the data?

Cleaning belongs in dbt staging, with raw as the replay point. If the Glue
job dropped rows, they'd be gone from staged and only recoverable by
reprocessing.

The job's role is format conversion. Quality problems are **counted and
logged**, not fixed. The first draft of the job did drop null `invoice_no`
rows — that was removed because it contradicted the storage design.

---

## 7. The World Bank Lambda

### Q7.1 — Why does this Lambda run outside the VPC?

It calls a public API. The private subnets have no NAT and no internet
gateway, so anything needing the public internet is placed outside
deliberately — rather than paying ~£30/month for NAT to reach one free API.

This is the specific case ADR 0003 anticipated.

### Q7.2 — Why no `requests` library?

Lambda's Python runtime doesn't bundle it, so using it means a layer or a
vendored zip to manage. `urllib.request` from the standard library does the
job, so the deployment package stays a zip of one file with no dependency
management at all.

### Q7.3 — You only need one page. Why paginate?

The country count isn't fixed, and a silent truncation at page 1 would be
invisible — the job would succeed with partial data. Reading `pages` from
the response metadata and looping costs almost nothing and removes a failure
mode that would be very hard to notice later.

### Q7.4 — Why retry only on 5xx?

Retrying a 4xx is pointless — a malformed query or a bad path will fail
identically every time. Retrying blindly turns a fast, clear failure into a
slow, confusing one. 5xx and network errors are transient and worth retrying;
client errors are raised immediately.

### Q7.5 **[hard]** — You overwrite the same S3 keys on every run. Doesn't that violate raw immutability?

It's a deliberate exception, and it's recorded as one in the audit record's
`write_mode` field.

Reference data is current-state, not an event stream. The indicator values
are pinned to a fixed year, so there's no history worth accumulating — a
snapshot per run would produce near-identical files forever.

The tension is real, though. If a World Bank revision changed a GDP figure,
the previous value would be lost on the unversioned dev bucket. If that
mattered, the answer would be date-prefixed keys — the same pattern the
orders data already uses.

### Q7.6 — Aggregates like "World" and "Euro area" come back from the API. Why not filter them?

Raw takes what the source returns. Filtering at ingest is a cleaning
operation, and cleaning belongs downstream — the same principle that keeps
cancellations and nulls in the orders raw layer.

They're identifiable downstream by `region_id == "NA"`, and the count of them
is recorded in the audit record so the number is known rather than
discovered.

---

## 8. The country join

### Q8.1 — Tell me about a data quality problem you hit.

The retail dataset's `country` field doesn't align with World Bank country
names. Of 43 distinct values:

- **34 match exactly** — Germany, France, Japan and so on
- **6 need aliases** — EIRE→Ireland, USA→United States, RSA→South Africa,
  Hong Kong→Hong Kong SAR China, Czech Republic→Czechia, Korea→Korea Rep.
- **3 are unmappable** — "Unspecified" (756 rows), "European Community" (61),
  "West Indies" (54)

Channel Islands was a surprise — it turns out the World Bank carries it as a
distinct entity with its own code.

### Q8.2 — How do you handle the unmappable ones?

Keep them with a null `country_id` rather than dropping them. 871 rows is
0.08% of the dataset, but dropping them means revenue totals stop tying out
against the source — and a total that doesn't reconcile is worse than a
country dimension with a null.

The mapping lives in a dbt seed with a `mapping_type` column distinguishing
`exact`, `alias`, `assumed` and `unmappable`, so the reason for each row is
visible.

### Q8.3 **[hard]** — "Korea" is in your source data. Which Korea?

Unknowable from the data. It's mapped to South Korea (KOR) on commercial
plausibility — a UK gift-ware retailer shipping to North Korea in 2010 is
implausible — but it's marked `assumed` in the mapping table rather than
`alias`.

That distinction is the point. A mapping table that separates "this is a
known alias" from "this is my judgment call" tells the next person which
rows to question.

### Q8.4 — How would you catch it if a new unmapped country appeared?

A dbt test asserting that every `country` value in staging has a
corresponding row in the mapping seed. It fails on an unmapped value, which
forces a deliberate decision rather than a silent null.

---

## 9. Cost

### Q9.1 — How are you keeping this under £10?

By eliminating everything that bills for existence rather than use:

- **No EC2** — Airflow runs locally in Docker
- **No NAT gateway** — ~£30/month avoided; gateway endpoint is free
- **No MWAA** — ~£250/month avoided
- **No idle clusters** — Glue is serverless
- **No interface endpoints** — deferred until proven necessary; never was
- **Glue `timeout = 15`** — caps the worst case per run
- **Monthly rather than daily partitions** — 25 runs instead of 730
- **Lambda log retention capped at 14 days** — log groups default to never
  expire

Plus an AWS Budget alert at £5, set before any resource was created.

### Q9.2 **[trap]** — Budget alerts protect you, right?

They're reactive, not preventive. They email you; they don't stop spend, and
they can lag a day behind the spend that triggered them.

Which is why the architecture avoids anything with an hourly idle cost in the
first place. The alert is a backstop, not a control.

### Q9.3 — What's your actual biggest cost line?

Glue, at roughly £5-8 across the whole build. Everything else sits in free
tier or costs pennies. The one-minute minimum billing increment is what
drives it, not the compute.

---

## 10. Judgment and framing

### Q10.1 **[hard]** — What's the weakest part of this design?

Two candidates, and being able to name them is better than being caught out.

**The shared VPC.** It's defensible for the current workload but doesn't
generalise, and the moment anything network-reachable lives in the VPC it
becomes wrong. Documented in ADR 0002 with an explicit trigger for
revisiting.

**The streaming path.** The source is a static historical file, so
"streaming" means replaying it through Firehose. Honest if framed as
simulated order events; dishonest if presented as live ingestion.

### Q10.2 — What would you do differently starting over?

Terraform from the beginning rather than console-first. The brownfield
adoption was instructive and produced a genuinely useful ADR, but it cost
time and surfaced drift that wouldn't have existed if the infrastructure had
been coded from the start.

Though there's a counter-argument: understanding what a resource does before
codifying it is easier than the reverse, especially when learning both the
service and Terraform at once.

### Q10.3 — How do you decide what warrants an ADR?

A decision warrants one when a reasonable engineer could have chosen
differently and the reasoning isn't obvious from the code. "Why Glue over
EMR" qualifies; "why we named the bucket this" doesn't.

The test that keeps them useful: an ADR that records only clean decisions
reads as fiction. Including what went wrong — the deleted import blocks, the
lifecycle rule that never saved, the invalid generated config — is what makes
them evidence rather than marketing.

### Q10.4 **[hard]** — Did you use AI to build this?

Yes, extensively — particularly for Terraform, which I was learning. The
architecture decisions are documented in the ADRs and I can walk through any
of them, including the ones I pushed back on and changed.

The honest position is that this is how the work gets done now. What matters
is whether I can defend what's in the repo, and the ADRs exist precisely
because reasoning that lives only in a chat history isn't defensible.
