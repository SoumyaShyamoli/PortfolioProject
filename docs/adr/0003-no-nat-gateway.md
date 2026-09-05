# ADR 0003 — No NAT gateway; reach S3 through a gateway VPC endpoint

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

The platform's compute runs in two private subnets with no internet gateway.
Glue jobs in those subnets need to read NDJSON from the raw S3 buckets and
write Parquet to the staged buckets.

The conventional way to give private subnets outbound access is a NAT
gateway. It is also, for a project with a hard sub-£10 total cloud budget,
the single most expensive thing that could be added: roughly £30 per month
per gateway in `eu-west-2`, billed hourly whether or not a byte moves, plus a
per-GB data processing charge. Two AZs done properly means two NAT gateways.
That is the entire project budget several times over, spent on idle
infrastructure.

## Decision

No NAT gateway and no internet gateway. Neither private subnet has a
`0.0.0.0/0` route — only the implicit local route for `10.0.0.0/16`.

S3 is reached through a **gateway** VPC endpoint
(`com.amazonaws.eu-west-2.s3`), associated with both private route tables.

Interface endpoints, including the Glue API endpoint, are created only if and
when a job actually fails without one — not pre-emptively.

## Rationale

**Gateway endpoints are free.** No hourly charge, no data processing charge.
This is the key asymmetry, and it is easy to get wrong: *interface* endpoints
bill approximately £0.01 per hour per AZ plus per-GB processing, while
*gateway* endpoints — available only for S3 and DynamoDB — cost nothing.

**The endpoint is better than NAT on security, not merely cheaper.** Traffic
to S3 through a gateway endpoint stays on the AWS network and never traverses
the public internet. With NAT, the same traffic would leave the VPC, hit a
public S3 endpoint, and come back. This is the rare case where the cheap
option is also the more defensible one, which is what makes it worth writing
down rather than filing under "budget compromise".

**Nothing in the pipeline needs the general internet.** The Glue job talks to
S3 and to the Glue service. The World Bank API pull, which does need outbound
internet, runs in Lambda outside the VPC — a deliberate placement, not an
oversight.

## Consequences

**The endpoint is load-bearing, not an optimisation.** With no NAT and no
IGW, removing the S3 gateway endpoint leaves Glue with no route to S3 at all.
Jobs would fail on connectivity. This is worth stating plainly because a
free, invisible resource is exactly the kind of thing someone deletes during
a tidy-up.

**Anything needing public internet must be placed deliberately.** Downloading
a PyPI package at job runtime, calling a third-party API from Glue, or
pulling a container image will fail. Options when that arises, in order of
preference: run it outside the VPC (as the World Bank pull does), add the
specific interface endpoint needed, or vendor the dependency into the job's
`--extra-py-files`. Adding NAT should be the last resort, not the first
reflex.

**A Glue interface endpoint may still be required.** Glue jobs that call the
Glue API from within the VPC — catalog operations, job bookmarks — may need
`com.amazonaws.eu-west-2.glue`. That one does bill hourly per AZ. The
decision here is to defer it until a job actually fails, then add it,
document the cost, and tear it down after testing rather than leaving it
running.

**Debugging is harder.** No internet means no `pip install` mid-job, no
curl-based troubleshooting from inside the subnet. Failures surface as opaque
connectivity errors rather than clear "no route to host" messages.

## Note on how this was discovered

The gateway endpoint was created during the original console build but was
not visible in the first round of infrastructure discovery, because the
`describe-vpc-endpoints` query used a placeholder VPC id and returned
nothing. It was only surfaced when Terraform tried to create a second one and
AWS rejected it with `RouteAlreadyExists` against prefix list `pl-7ca54015` —
the S3 prefix list, which is what a gateway endpoint installs into a route
table.

Two things worth keeping from that. First, a failed discovery query returning
empty looks identical to a resource genuinely not existing; the plan was
built on that false negative and only the apply caught it. Second, the
resulting error message named a prefix list rather than an endpoint, which is
not obvious unless you know that a gateway endpoint's route entry is a
prefix-list route. The endpoint was subsequently imported rather than
recreated.

## Alternatives considered

**NAT gateway in one AZ only.** Halves the cost and is a common real-world
compromise, at the price of a single-AZ failure mode. Still roughly £30 per
month — three times the entire project budget — so rejected on cost alone
before the availability question mattered.

**Public subnets with security groups restricting egress.** Cheaper than NAT
and would work. Rejected because it puts compute on a subnet with a route to
the internet, making the security group the only barrier. The private-subnet
arrangement fails closed; this one fails open.

**VPC endpoints for every service pre-emptively.** Rejected. Interface
endpoints bill hourly whether used or not, and creating them speculatively is
how a sub-£10 budget quietly becomes a £40 bill. Create on demonstrated need.

## Follow-ups

- If the Glue job fails on Glue API connectivity, add
  `com.amazonaws.eu-west-2.glue` as an interface endpoint, record the actual
  cost incurred, and delete it after the test window.
**Resolved:** the first Glue run succeeded from the private subnet without a Glue interface endpoint, so the deferral was correct and no hourly cost was incurred. Revisit only if a future job needs Glue API calls the current one does not make.

- Confirm the imported gateway endpoint is associated with **both** private
  route tables, not just one. Terraform will add the second association if it
  is missing.
- Add a billing alarm distinct from the budget alert, since budget alerts are
  reactive and can lag a day behind the spend that triggered them.




---

## Amendment (2026-08-28)

Two real consequences of the no-NAT, no-IGW decision surfaced since this
ADR was written, both worth recording against the decision that caused
them rather than only in the documents that had to work around them.

**1. The predicted pattern happened — for a different service than
expected.** This ADR's original follow-up anticipated possibly needing
a Glue interface endpoint; that never materialised (Glue ran fine
without one). What DID need an interface endpoint was **SSM** — three of
them (`ssm`, `ssmmessages`, `ec2messages`) — once the Airflow instances
(ADR 0014) needed to be reachable at all. Same underlying mechanism this
ADR already established (add an interface endpoint only when a specific,
real need appears, not preemptively), just a different service than
originally guessed. See `ssm_endpoints.tf` — toggled by a boolean rather
than the stop/start pattern used for the instances themselves, since
endpoints hold no state worth preserving between uses.

**2. No NAT meant no PyPI, which is the direct root cause of ADR 0015.**
This is worth stating explicitly rather than leaving ADR 0015 to read as
an isolated wheelhouse design with no clear origin. The chain is: no NAT
(this ADR, cost-driven) → no route to `pypi.org` from the Airflow
instances → `pip install` fails at bootstrap → the wheelhouse
workaround. ADR 0015 is not an independent decision; it is a direct,
traceable consequence of this one. Anyone asking "why does this project
need a whole separate package-mirroring system" should be pointed here
first, then to ADR 0015 for the mechanism.

**Cost picture, updated:** the SSM endpoints add a real, non-trivial
line — roughly £1/day while switched on, larger than the Airflow
instances' own compute cost. This ADR's original "no NAT saves ~£30/month"
framing undercounted what enabling *any* AWS-side network access from
these subnets would eventually cost in aggregate (interface endpoints
are not free, only cheaper and more scoped than a NAT gateway). Still
the right call — £1/day only while actively debugging, versus a
NAT gateway running continuously — but the original comparison was
incomplete.

**No change to the core decision.** No NAT gateway remains correct for
this project's cost profile. The amendment is purely to make both
downstream consequences traceable back to their origin.



---

## Amendment (2026-09-05) — the third network gap, and the one that doesn't have a cheap fix

Getting Airflow to actually orchestrate the pipeline end to end surfaced
**three separate instances of the same underlying category of gap**: code
running inside the private, NAT-less subnet reaching out to something that
isn't reachable without an explicit route. Worth recording as a pattern,
not three unrelated incidents.

**1. SSM** — needed before Airflow could even be reached at all. Fixed
with three interface endpoints (`ssm`, `ssmmessages`, `ec2messages`).
Already amended above.

**2. Glue** — the first time anything *inside* this subnet called
`glue:StartJobRun` via boto3 directly, rather than from a laptop or a
GitHub Actions runner (both outside the VPC, both with full internet
access). Hung on `sock.connect()` for over three minutes before being
killed — a genuine TCP-level timeout, not a permissions error. Fixed with
a `com.amazonaws.eu-west-2.glue` interface endpoint, same toggle and
security group as SSM's.

**3. Snowflake — found, and NOT fixable the same way.** Snowflake is not
an AWS service, so no `com.amazonaws.*` interface endpoint exists for it.
The only AWS-native option is **AWS PrivateLink via a VPC Endpoint
Service** Snowflake operates — `SYSTEM$GET_PRIVATELINK_CONFIG()` confirms
this account's Snowflake *edition* supports it, but attempting to create
the endpoint failed with `InvalidServiceName`, and
`SHOW PARAMETERS LIKE 'ENABLE_INTERNAL_STAGES_PRIVATELINK'` confirmed why:
**`false`** — PrivateLink is not actually provisioned for this account.
Enabling it requires a Snowflake support case, is not self-service, and
its turnaround is outside this project's control.

## Decision

**Not fixed tonight. Two real paths forward, neither of them free:**

**A — open a Snowflake support case requesting PrivateLink activation**,
providing this AWS account ID and region. Cost: $0 (PrivateLink itself
has no separate Snowflake-side charge on most editions once enabled;
the AWS-side VPC endpoint costs the same ~$0.01/hr/AZ as the SSM/Glue
endpoints already accepted). Downside: turnaround time is unknown and
not controllable from this side.

**B — revisit the no-NAT-gateway decision from the original ADR 0003.**
A NAT gateway gives the subnet a real route to the public internet,
making Snowflake (and anything else non-AWS) reachable the ordinary way,
at the ~£30/month cost this ADR explicitly chose to avoid. This would be
the first time that specific tradeoff gets reopened rather than held.

**Neither implemented as of this amendment.** Airflow's `load_snowflake_raw`,
`recon_gate`, and `send_status_email` tasks — everything that opens a
Snowflake connection from inside the instance — will continue failing
with a connection timeout until one of these paths is taken.

## What this means for "Airflow verification"

The orchestration layer itself is now proven correct up to this exact
boundary: `fetch_snowflake_key` (SSM), `trigger_glue`/`wait_for_glue`
(Glue, post-fix) all genuinely work. The DAG's logic, the recon gate's
design, the reconciliation queries — none of that is in question. What's
blocked is specifically the network path from this EC2 instance to
Snowflake's control plane, a decision (no NAT gateway) made before
Airflow existed, that has now met its first real cost.

## Consequences

**This is not a code or Terraform bug to keep iterating on** — the fix,
whichever path is taken, is either an external approval (Snowflake
support) or a deliberate, already-well-understood cost tradeoff
(NAT gateway). No further debugging session finds a cheaper third option
here; PrivateLink and NAT-with-real-internet-access are the only two
ways to give a NAT-less private subnet a route to a non-AWS public
endpoint.

**Worth naming honestly in any writeup of this project:** the no-NAT
decision was right for everything that stayed AWS-native (S3, Glue,
SSM — all fixable with free or cheap interface/gateway endpoints). It
was always going to eventually meet something that wasn't AWS-native.
Snowflake was that something. This isn't a flaw in the original
decision; it's the boundary that decision was always going to have.

## Follow-ups

- Open the Snowflake support case for PrivateLink (path A), since it has
  no cost and no downside beyond waiting — worth doing regardless of
  whether path B is also pursued in parallel.
- If PrivateLink approval doesn't materialize in a reasonable window,
  revisit the NAT gateway decision explicitly, with this amendment as
  the record of why the original £30/month avoidance stopped being
  sufficient.
- Once either path resolves, `dag_retail_pipeline.py`'s three
  `snowflake.connector.connect()` call sites need the `host=` parameter
  (PrivateLink) — or, if NAT is chosen instead, no DAG change is needed
  at all, since the public hostname would simply become reachable.