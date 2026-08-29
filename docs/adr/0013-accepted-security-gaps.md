# ADR 0013 — Controls deliberately not implemented, and what would trigger revisiting each

- **Status:** Accepted
- **Date:** 2026-08-28

## Context

A senior-engineer-style review of the platform (2026-08-25) surfaced a
list of controls a production system would normally have, that this one
does not: permission boundaries, MFA enforcement, access-key rotation,
S3 bucket policies, KMS encryption, Snowflake network policies,
snapshots/SCD2, local-conversion checksums, and — separately — the
category of `tfsec` findings this project's Terraform will legitimately
trigger once static analysis runs in CI.

The instinct after a review like that is to build everything flagged.
That's the wrong instinct here. Some of these gaps are real risk on a
platform with actual users and actual data; on this platform — a solo
project, public research data, a personal AWS account, sessions measured
in hours rather than an always-on production service — building them
would mean demonstrating controls that solve a threat model this project
doesn't have, at the cost of hours better spent on marts, streaming, and
the parts of the system that produce output.

This ADR is the deliberate alternative: a stated decision per gap, not a
default of building everything a checklist suggests. "I looked at this,
decided it wasn't worth it here, and here's exactly why" is a stronger
answer under questioning than either silence about the gap or having
built a control nobody needed.

## Decision

Each gap below is either **accepted as-is** (with a stated trigger for
revisiting) or **deferred with a cost estimate** (worth doing, not worth
doing now). None are silently ignored — each has a reason and a
condition under which the reason stops applying.

---

### IAM — permission boundaries

**Accepted.** A permission boundary caps the maximum privilege an IAM
principal can ever be granted, even by a future policy change — the
standard use case is preventing a team member from accidentally or
deliberately escalating their own access. This platform has one operator
and no team; there is no second party whose privilege needs capping.

**Revisit when:** a second person gets IAM access to this account, for
any reason — a collaborator, a reviewer with hands-on access, anything
beyond read-only sharing.

### IAM — MFA enforcement

**Accepted, with a caveat.** The console/root-level protections for
`soumyadeep007` (the human admin identity) are a personal security
practice, not something this repository's IaC can enforce or verify —
Terraform has no visibility into whether MFA is actually enabled on a
console login. Documented here as a known gap in what the *codebase*
proves, not a claim that MFA is absent in practice.

**Revisit when:** never fully closed by code alone — this is inherently
a console-side setting. Worth adding an `aws iam get-account-summary`
check to a periodic manual audit if this project runs long enough to
warrant one.

### IAM — access-key rotation

**Accepted.** No long-lived AWS access keys exist for CI at all — GitHub
Actions authenticates via OIDC (ADR 0008), and the local builder identity
(`retail-dev-admin`) is the only key-based credential, used interactively
and briefly. Rotation policy matters most for keys embedded in automated
systems that would otherwise run unattended for months; that's not this
project's shape.

**Revisit when:** any static credential is added anywhere in the CI path
— it shouldn't be, per the existing OIDC design, but if it ever is, that
addition should come with a rotation policy attached at the same time,
not after.

### S3 — bucket policies (beyond IAM)

**Accepted.** IAM already scopes exactly which roles can touch which
prefixes in which buckets (ADR 0004, ADR 0005). A bucket policy would be
a second, largely redundant enforcement layer for the same rules,
appropriate when multiple AWS accounts or unknown principals might
interact with a bucket — neither is true here; every principal touching
these buckets is a role this project itself defined and reviewed.

**Revisit when:** any bucket needs to be reachable by a principal outside
this AWS account (cross-account access, a public read use case, a
third-party integration).

### S3 — KMS encryption (vs SSE-S3 default)

**Accepted.** Data at rest is SSE-S3 encrypted by default; no
customer-managed KMS key exists for the buckets. The dataset is a public
research dataset (Online Retail II) — there is no confidentiality
requirement SSE-S3 fails to meet. A CMK's value is auditable key usage
and the ability to revoke access by disabling the key — meaningful for
regulated or genuinely sensitive data, not for data anyone can already
download from Kaggle.

**Revisit when:** any dataset containing real PII or regulated data is
ever loaded into this platform — at that point CMK, plus the SSM
`kms:Decrypt` grants already in place (ADR 0010) becoming genuinely
load-bearing rather than incidental, both need re-evaluating together.

### Snowflake — network policies

**Accepted.** The service users (`RETAIL_DEV_USER`, `RETAIL_PROD_USER`)
can authenticate from any IP, restricted only by key-pair auth and
role-scoped grants. A network policy restricting to GitHub Actions' and
the Airflow instances' IP ranges is the tighter setup, and a real gap —
key-pair auth alone means a leaked private key is usable from anywhere.

**Deferred, not accepted outright** — this is the one item on this list
closest to worth doing now. Estimated at 1-2h: GitHub Actions publishes
its IP ranges via a documented API endpoint, refreshed periodically; the
Airflow instances' IPs are static as long as they're stopped/started
rather than destroyed/recreated (ADR 0014). The friction is that GitHub's
published ranges are broad (shared across all GitHub Actions customers,
not scoped to this repo) and change over time, so the policy would need
either periodic maintenance or acceptance of a wide range that's only
marginally tighter than no policy at all.

**Revisit when:** before this project is shown as a template for
production use, or if it graduates from portfolio to anything handling
real credentials that would matter if leaked.

### dbt — snapshots / SCD2

**Accepted.** Nothing in this platform currently needs point-in-time
history of a changing dimension (a customer's address changing over
time, a product's category being reclassified). Online Retail II is a
closed historical dataset — there is no "current state that changes,"
only transaction history that's already immutable once loaded.

**Revisit when:** the streaming path (still unbuilt) introduces genuinely
live, mutable dimension data — at that point, whether a dimension needs
SCD2 becomes a real per-table design question, not a blanket gap.

### Local conversion — checksums

**Accepted.** `convert_ndjson.py` runs locally with no checksum
verification that what's uploaded to S3 matches what was produced
locally. The gap is real: a corrupted upload would be silently invisible
to the pipeline until row counts happened to look wrong downstream.

**Deferred**, estimated at under 1h: an `md5sum`/`aws s3 cp` with
built-in integrity check (S3 already does content-MD5 validation on
upload by default via the SDK, which meaningfully narrows this gap more
than it first appears) plus a local pre/post row-count print would close
most of the practical risk cheaply. Not done yet simply because nothing
has surfaced a real corrupted-upload incident to prioritize it against
marts and streaming.

**Revisit when:** any load produces row counts that don't match what
`convert_ndjson.py`'s own logging said it produced — that specific
symptom is exactly what this gap would fail to catch early.

---

### `tfsec` findings — accepted as a category, not itemized here

`pr-checks.yml` runs `tfsec` with `soft_fail: true` (tier-1 hardening).
Findings appear as PR comments rather than blocking merges. This ADR is
where "accepted" findings should be individually listed once `tfsec` has
actually run against the current Terraform and produced real output —
that list does not exist yet, because the workflow was added but a full
run's findings have not yet been reviewed and triaged one by one.

**Follow-up, not yet done:** run `tfsec` deliberately against the current
`infra/terraform/`, and for every finding, either fix it (if cheap and
real) or add a one-line entry to this section naming the finding and why
it's accepted — the same treatment every other gap above got. An
unreviewed soft-fail category is not the same as a reviewed, accepted
one, and this ADR should not claim otherwise until that review happens.

## Consequences

**This ADR is a living document, not a one-time write.** Each "revisit
when" condition is a real trigger — if any of them fires, the honest
move is to update this ADR (either building the control or restating why
it's still accepted despite the trigger), not to let the document go
stale while the actual risk profile has changed underneath it.

**The absence of a control here is not the same as an oversight.**
Anyone reviewing this platform — a hiring manager, an interviewer, a
future collaborator — should read this file before assuming a gap was
missed rather than decided. That's the entire purpose of writing it down.

## Alternatives considered

**Build everything the review flagged.** Rejected as the default
instinct precisely because it was the default instinct — matching a
checklist rather than reasoning about this specific platform's actual
threat model wastes the hours this project doesn't have to spare, and
produces controls that don't map to any real risk here.

**Say nothing, leave the gaps undocumented.** Rejected — an undocumented
gap looks identical to an unnoticed one from the outside, and the
distinction is the entire value of doing this exercise at all.

## Follow-ups

- Run `tfsec` for real and populate its findings section above.
- Revisit Snowflake network policies if this project is ever positioned
  as more than a portfolio piece.
- Add the cheap local-conversion integrity check (row-count + checksum
  logging) opportunistically, next time `convert_ndjson.py` is touched
  for any other reason.
