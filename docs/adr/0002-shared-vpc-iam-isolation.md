# ADR 0002 — Share one VPC across dev and prod, isolate at the IAM layer

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

The platform runs two environments, dev and prod, each with its own S3
buckets (`sd-retail-{env}-{raw,staged,curated}-…`) and its own pipeline
execution role. Compute — currently AWS Glue, later Lambda — needs to run
inside a VPC.

The textbook arrangement is one VPC per environment, or better, one AWS
account per environment under an Organization. Both draw a hard network
boundary between environments: a misconfigured dev job cannot reach prod
resources because there is no path.

This platform is a solo build with a hard total cloud budget of under £10.
That budget is the binding constraint on almost every infrastructure decision
here, and it rules out several arrangements that would otherwise be default.

## Decision

Run a single VPC (`retail-platform-vpc`, 10.0.0.0/16) with two private
subnets across `eu-west-2a` and `eu-west-2b`, shared by both environments.

Environment isolation is enforced entirely through IAM: the dev pipeline
execution role can read and write only `sd-retail-dev-*` buckets, the prod
role only `sd-retail-prod-*`. Neither can assume the other. The CI/CD deploy
roles are similarly split, with the production role's trust policy scoped to
the `main` branch of the repository via GitHub OIDC.

## Rationale

**Per-environment VPCs would not have added isolation that IAM is not already
providing.** The resources being protected are S3 buckets, which are not in
the VPC at all — they are reached through a gateway endpoint. A separate dev
VPC would still reach prod buckets over the same S3 service endpoint. The
boundary that actually matters for this platform's data is the IAM policy on
the execution role, not the subnet the compute happens to sit in.

**Duplicating the VPC duplicates its costs.** VPCs and subnets are free, but
anything attached to them is not — interface endpoints in particular bill per
AZ per hour. Doubling the network means doubling that bill for no security
gain, given the point above.

**The compute is ephemeral.** Glue jobs provision, run, and terminate. There
are no long-lived instances in these subnets holding state that a neighbour
could reach.

## Consequences

**This does not generalise.** The moment the platform runs something with a
network-reachable surface inside the VPC — an RDS instance, a Redis cache, an
internal API, a self-hosted Superset — the security group becomes the only
thing separating dev compute from prod data stores, and security groups are
easy to widen by accident. At that point this decision should be revisited,
and the honest answer becomes separate accounts rather than separate VPCs.

**Blast radius is wider than it looks.** A change to a shared route table or
to the S3 gateway endpoint affects both environments simultaneously. There is
no way to roll a network change out to dev first and observe it before prod
sees it. Accepted here because network changes on this platform are rare and
the environments are not serving anyone.

**Interview framing.** The defensible version of this is the reasoning above,
not the conclusion. Stated as "dev and prod share a VPC" it sounds like a
shortcut; stated as "the isolation boundary for S3-backed data is IAM, so a
second VPC would have cost money without moving the boundary" it is a
judgment call. Both are true, and the second is the one worth being able to
defend.

## Alternatives considered

**Separate AWS accounts per environment, under an Organization.** The correct
answer at any real scale — a hard boundary that no IAM misconfiguration can
cross, plus clean per-environment billing. Rejected on setup overhead and
cross-account role complexity for a solo project, not on merit. Documented in
the README as the production-grade arrangement this platform approximates.

**Separate VPCs in one account.** Rejected as the worst of both: real cost
duplication for endpoints, real added complexity, and no meaningful isolation
improvement for the S3-backed workload described above.

**Separate subnets per environment within the shared VPC.** Considered.
Rejected because subnet boundaries are not security boundaries without
security group or NACL rules to back them, and adding those rules would be
enforcing at a second layer what IAM already enforces at the first.

## Follow-ups

- Revisit if any VPC-resident, network-reachable service is introduced.
- Tag network resources with the environments they serve, so the sharing is
  visible in the console rather than only in this document.




---

## Amendment (2026-08-28)

This ADR's own follow-up condition has fired: "revisit if any
VPC-resident, network-reachable service is introduced." The Airflow
instances (ADR 0014) are exactly that — two EC2 instances living in the
shared VPC's private subnets, reachable via SSM Session Manager.

**The original reasoning still holds, and here's why explicitly, rather
than leaving the trigger silently unaddressed.** The shared-VPC decision
rested on IAM being the real isolation boundary between dev and prod,
not network segmentation. Airflow doesn't weaken that: each instance has
its own IAM role (`retail-dev-airflow-role` / `retail-prod-airflow-role`),
each scoped to its own environment's Snowflake key, its own environment's
S3 prefixes, and nothing else — the same pattern already used for Glue's
pipeline execution roles. The instances sit in the same VPC, but nothing
about being in the same VPC gives one environment's instance any reach
into the other's resources; that boundary is still enforced entirely by
IAM, exactly as this ADR originally decided.

**What's genuinely new, and worth naming:** this is the first time two
long-running, addressable compute resources (not a transient Glue job)
have shared this VPC. A future service with a *network-level* trust
model — something that authenticates by source IP or VPC membership
rather than IAM role — would be the actual case this ADR's original
follow-up was warning about. Nothing built so far does that; SSM
Session Manager and the S3 gateway endpoint are both IAM-authenticated,
not network-trust-based.

**Conclusion:** no change to the shared-VPC decision. The follow-up is
closed, not because the trigger didn't fire, but because firing it and
checking confirmed the original reasoning was sound.