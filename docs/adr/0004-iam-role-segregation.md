# ADR 0004 — Segregate IAM roles by function; no long-lived keys for CI/CD

- **Status:** Accepted
- **Date:** 2026-08-23
- **Deciders:** Platform owner (solo)

## Context

A solo project has an obvious path of least resistance: one identity with
broad permissions, used for everything — local development, deployments, and
whatever the pipeline itself needs at runtime. It works, and nothing about a
one-person project forces anything better.

It is also precisely the arrangement that makes an incident unbounded. A
leaked credential, a mistake in a deploy script, or a compromised CI runner
all reach the same blast radius, because there is only one radius.

The platform therefore adopts role segregation as if it had a team, and the
reasoning below is the argument for why that is not theatre.

## Decision

Five roles, split by function rather than by person:

| Role | Assumed by | Purpose |
|---|---|---|
| `retail-dev-pipeline-exec-role` | Glue (dev) | Runtime execution against dev buckets |
| `retail-prod-pipeline-exec-role` | Glue (prod) | Runtime execution against prod buckets |
| `retail-dev-cicd-deploy-role` | GitHub Actions | Deploy to dev, any branch |
| `retail-cicd-deploy-role` | GitHub Actions | Deploy to prod, `main` only |
| `retail-human-admin-role` | Human operator | Break-glass and manual inspection |

CI/CD authenticates through a **GitHub OIDC identity provider**. No AWS
access keys exist in GitHub secrets. The production deploy role's trust
policy additionally constrains the `sub` claim to the `main` branch.

Pipeline execution roles carry a scoped inline policy plus the AWS-managed
`AWSGlueServiceRole`.

Separately, a `retail-dev-admin` IAM **user** exists for local CLI and
Terraform work. It is broad but not unlimited, and permissions are attached
when a specific operation demands them rather than granted up front.

## Rationale

**Three distinct trust boundaries, therefore three kinds of role.** Runtime
compute, automated deployment, and human operation fail in different ways and
should not share an identity. A Glue job does not need to create IAM roles; a
deploy pipeline does not need to read customer data; a human does not need
either on a normal day.

**Environment separation is enforced here, not in the network.** Per ADR
0002, dev and prod share a VPC. The boundary that actually protects prod data
is the execution role's policy scoping it to `sd-retail-prod-*` buckets. That
makes IAM the load-bearing control, which is the reason for taking it
seriously rather than treating it as paperwork.

**OIDC removes the credential that would otherwise leak.** Static access keys
in CI are the most commonly exfiltrated AWS credential in practice. Federated
short-lived tokens have no equivalent artefact to steal, rotate, or forget
about. Constraining the prod role's trust to `main` means a pull request from
a fork cannot obtain production credentials, which is the specific attack this
guards against.

**Permissions on demand produces a more honest least-privilege story than
scoping up front.** The builder identity started with S3, Glue, Lambda,
Kinesis, IAM, EventBridge and CloudWatch Logs. Terraform then failed on
`ec2:CreateTags` when adopting the VPC, and `AmazonVPCFullAccess` was added
in response — chosen over `AmazonEC2FullAccess` because the platform manages
network resources but never launches instances. Each addition is traceable to
a specific operation that needed it.

## Consequences

**The builder identity is the weak point, and it is a knowing one.** For the
duration of the build the human operator effectively holds administrative
capability, including `IAMFullAccess`. In a team this would be split — a
platform engineer who can create roles, an analyst who cannot — and elevated
capability would be assumed temporarily rather than held permanently. It is
not split here because there is one person, and over-restricting the sole
builder produces a month of permission errors and no security benefit. The
discipline is applied where it demonstrates something: the service roles.

**`AWSGlueServiceRole` is broader than the inline policies beside it.** It
grants access to any bucket named `aws-glue-*` plus wide Glue and CloudWatch
permissions. It is AWS's recommended baseline for Glue service roles and is
retained for now. Once the Glue job runs successfully, revisit whether the
scoped inline policy alone is sufficient — an honest answer either way, but
it should be a decision rather than a default.

**Role names are asymmetric.** `retail-cicd-deploy-role` is the production
role while its counterpart is `retail-dev-cicd-deploy-role`, and inline
policy names are inconsistently suffixed. Renaming an IAM role means
destroy-and-recreate, so this is deferred to a dedicated change rather than
folded into the Terraform adoption.

**Prod deploys are gated on a branch, not on a human.** Merging to `main`
grants production deploy capability with no second approval. Adequate for a
solo project; a real team would add a GitHub environment protection rule
requiring review. Worth naming as the gap it is.

## Alternatives considered

**A single admin role for everything.** Rejected on blast radius, as above.

**Access keys in GitHub secrets.** Simpler to set up and still common in the
wild. Rejected: it creates a long-lived credential that must be rotated,
audited, and hoped-not-to-leak, in exchange for avoiding a one-time OIDC
provider setup.

**Separate AWS accounts per environment.** The stronger control, and the
correct answer at scale. Rejected on overhead for a solo project — see ADR
0002. Role-level separation is the approximation, and it is an approximation,
not an equivalent.

**Permission boundaries on the builder identity.** Considered as a way to cap
what `retail-dev-admin` can do even with `IAMFullAccess`. Rejected as
disproportionate for a single-operator project, but it is the correct next
control if anyone else ever gets credentials.

## Follow-ups

- Re-evaluate `AWSGlueServiceRole` once the Glue job runs successfully.
- Normalise role and inline policy naming in a dedicated change.
- Add a GitHub environment protection rule on production deploys if the
  project ever takes a second contributor.
- Verify the pipeline execution roles carry the EC2 network permissions Glue
  needs to run inside a VPC (`CreateNetworkInterface`, `DescribeSubnets` and
  related) before the first VPC-attached job run.


## Amendment — 2026-08-24: the incremental-permissions story stopped being true

The original decision recorded that the builder identity
(`retail-dev-admin`) started narrow and gained permissions on demand, with
each addition traceable to a specific failed operation. That was accurate at
the time and I stand by the reasoning, but it is no longer what the account
looks like.

**What happened.** Nine service-specific managed policies accumulated one
failure at a time — S3, Glue, Lambda, Kinesis Firehose, CloudWatch Logs,
EventBridge, VPC, SNS, CloudWatch — alongside `IAMFullAccess`. Attaching a
tenth for SSM hit IAM's hard quota of 10 managed policies per user.

**What I did.** Detached the nine and attached `PowerUserAccess`, which covers
every service except IAM and Organizations. The identity now holds
`PowerUserAccess` + `IAMFullAccess`.

**Why I am not treating this as a regression.** The incremental grants were
never a real constraint. An identity holding `IAMFullAccess` can grant itself
anything at any time — the narrow policies documented what the platform
needed, they did not limit what the operator could do. Hitting the quota
forced the pretence to stop rather than removing a control.

The honest framing is that this is a single-operator project and the operator
is effectively an administrator. The least-privilege work that demonstrates
something real is on the **service roles** — Glue execution, Lambda
execution, CI/CD deploy — which remain scoped to specific buckets, specific
prefixes and specific actions. Those are the roles a compromise would
actually flow through, and they are unchanged.

**What a real platform would do instead.** Split the human identity by
function: a platform engineer who can create roles, an analyst who cannot,
elevated capability assumed temporarily via `sts:AssumeRole` rather than held
permanently. A permission boundary on the builder identity would cap what it
can grant itself even with `IAMFullAccess`. Neither is worth the friction for
one person; both are the correct answer the moment there are two.

**Why the builder identity is not in Terraform.** It is the identity that
runs Terraform. Managing it from the configuration it applies is the same
chicken-and-egg as the state bucket — a bad apply could revoke access
mid-run, leaving no way to fix it except the root account. It stays created
by hand and outside state, deliberately. No Terraform change was needed for
this amendment.

**Consequence.** The account no longer has a meaningful record of which
permissions the platform actually requires, because that record was the list
of attached policies. If that matters later, the way to reconstruct it is
CloudTrail or IAM Access Analyzer rather than the policy list.