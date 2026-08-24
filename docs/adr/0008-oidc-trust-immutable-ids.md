# ADR 0008 — Pin GitHub OIDC trust to immutable owner and repository IDs

- **Status:** Accepted
- **Date:** 2026-08-24
- **Deciders:** Platform owner (solo)

## Context

CI/CD authenticates to AWS through GitHub's OIDC provider rather than static
access keys (ADR 0004). AWS validates the token's signature against the
registered provider, then evaluates the token's claims against the role's
trust policy. The `sub` claim is what identifies *which* repository and
*which* ref is asking.

Every guide, including AWS's own, shows the `sub` claim in this form:

```
repo:OWNER/REPO:ref:refs/heads/main
```

The trust policies were written against that form. Role assumption failed
with:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

The error is unhelpfully generic — it is the same message for a missing
`id-token: write` permission, a misconfigured provider, an `aud` mismatch,
and a `sub` mismatch. The OIDC provider was verified correct, the workflow
permissions were verified correct, and the trust policy matched the
documented claim format, which left no obvious candidate.

## Investigation

Rather than continue guessing, a temporary workflow step decoded the token
payload directly:

```yaml
- name: Debug OIDC claims
  uses: actions/github-script@v7
  with:
    script: |
      const token = await core.getIDToken('sts.amazonaws.com');
      const payload = JSON.parse(
        Buffer.from(token.split('.')[1], 'base64').toString()
      );
      core.info('sub: ' + payload.sub);
      core.info('aud: ' + payload.aud);
```

This only base64-decodes the payload; it does not verify the signature and
prints nothing that AWS does not already receive.

The actual claim was:

```
repo:SoumyaShyamoli@127630731/PortfolioProject@1338715381:pull_request
```

The repository has GitHub's **"Include enterprise/organization and repository
IDs in the OIDC token subject"** setting enabled, which injects immutable
numeric IDs after the owner and repository names. Nothing else was
misconfigured.

## Decision

Pin the trust policies to the ID-qualified subject rather than disabling the
setting.

```hcl
locals {
  github_owner    = "SoumyaShyamoli"
  github_owner_id = "127630731"
  github_repo     = "PortfolioProject"
  github_repo_id  = "1338715381"

  github_sub_prefix = "repo:${local.github_owner}@${local.github_owner_id}/${local.github_repo}@${local.github_repo_id}"
}
```

- dev role: `"${local.github_sub_prefix}:*"` — any ref in this repository
- prod role: `"${local.github_sub_prefix}:ref:refs/heads/main"` — main only

The components are declared as separate locals so the numeric IDs are
labelled rather than appearing as unexplained digits in a string.

## Rationale

**ID-based trust is strictly stronger than name-based trust.** Repository and
owner names are mutable and reusable: rename a repository and the old name
returns to the pool, where anyone can claim it. A trust policy matching
`repo:OWNER/REPO:*` would then accept tokens from a repository that merely
inherited the name. Numeric IDs are permanent and never reissued, so the
trust cannot be inherited by a successor.

**Disabling the setting would have been a downgrade.** The straightforward
alternative — turn off ID inclusion so the documented format applies — trades
a security property for the convenience of matching a tutorial. Reverting a
hardening setting to make copy-pasted configuration work is the wrong
direction.

**Trust survives a rename.** With names in the policy, renaming the
repository silently breaks CI at the next run. With IDs, it keeps working.

## Consequences

**The trust policy no longer resembles published examples.** Anyone
maintaining this will compare it against a guide and conclude it is wrong.
The comment block in `iam.tf` explains the format and points here.

**The IDs must be looked up if the repository is recreated.** Deleting and
recreating a repository issues a new ID, and the trust policy would need
updating. This is a genuine operational cost, though a rare event — and
arguably a feature, since a recreated repository is not the same repository.

**Production is not assumable from a pull request.** The prod role requires
`:ref:refs/heads/main`, and a pull request's claim ends in `:pull_request`.
This is intended: production deploys happen on merge, not on proposal. It
does mean the prod path cannot be smoke-tested from a PR — only the dev path
is exercised before merge.

**The debug technique is worth keeping.** The step was removed after
diagnosis, but the pattern is recorded here and in the runbook. Any future
OIDC failure should start by decoding the claim rather than inspecting policy
documents, because the claim is ground truth and the policy is only a guess
about it.

## Alternatives considered

**Disable ID inclusion in repository settings.** Would have made the existing
policies work with no code change. Rejected: it weakens the trust boundary to
match documentation.

**Match on `repository` and `repository_owner_id` claims instead of `sub`.**
GitHub's token carries these as separate claims, and a trust policy can
condition on them individually. A legitimate alternative and arguably
cleaner. Rejected only because `sub` also encodes the ref, which the prod
role needs to distinguish main from other branches — using both would mean
two conditions where one suffices.

**Wildcard the IDs, e.g. `repo:OWNER@*/REPO@*:*`.** Rejected outright: it
reintroduces name-based matching while pretending to be ID-based.

## Follow-ups

- If the repository is ever transferred or recreated, update
  `github_owner_id` / `github_repo_id` and apply before the next CI run.
- Consider adding a second condition on the `repository_id` claim as
  defence in depth, if AWS trust policy complexity is ever revisited.
