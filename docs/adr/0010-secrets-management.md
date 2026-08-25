# ADR 0010 — Secrets in SSM Parameter Store; local files are dev-only

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

Up to this point the platform had no secrets. That was not discipline, it was
luck — OIDC removed the AWS credentials, and nothing else needed one.

Snowflake changes that. dbt has to authenticate, which means a credential
that exists somewhere. Snowflake is deprecating password auth for
programmatic access, so the credential is an RSA private key.

## Decision

**Key-pair auth, not password.** Generated locally, public half registered on
the Snowflake user with `ALTER USER ... SET RSA_PUBLIC_KEY`.

**SSM Parameter Store is the source of truth for every secret**, stored as
SecureString at `/retail/{env}/...`. Anything that needs a credential fetches
it from there.

**Production never reads a credential from disk.** Prod dbt runs — whether
triggered from CI or from Airflow — fetch the prod key from SSM at runtime,
write it to a temp file scoped to the process, and delete it on exit. There
is no prod key sitting in a home directory, on any machine, ever.

**Development may use a local file**, at `~/.snowflake/rsa_key_dev.p8`,
outside the repo and gitignored. This is a stated exception, not the pattern.

| | Source of truth | How it is read |
|---|---|---|
| prod (CI) | SSM `/retail/prod/snowflake/private_key` | fetched via OIDC role at runtime |
| prod (Airflow) | SSM `/retail/prod/snowflake/private_key` | fetched via boto3 at task start |
| dev (CI) | SSM `/retail/dev/snowflake/private_key` | fetched via OIDC role at runtime |
| dev (local) | SSM, mirrored to `~/.snowflake/rsa_key_dev.p8` | local file |

## Rationale

**Why SSM is the source of truth even for dev.** The dev key is written to
SSM first and mirrored locally, not the other way round. That means there is
one place to rotate from, and the local copy is a cache rather than an
original. If the two diverge, SSM wins by definition.

**Why prod tolerates no local copy.** A key on a laptop is exposed to
everything that laptop is exposed to — backups, sync clients, other
processes, whoever picks it up. For a dev key against a database holding a
public research dataset, that is an acceptable trade for the convenience. For
prod it is not, and the asymmetry is the whole point of separating them. If
prod ever needs a human to run something against it, that human assumes a
role and fetches the key; they do not keep one.

**Parameter Store over Secrets Manager: cost.** Standard parameters are free.
Secrets Manager is about £0.30 per secret per month plus API charges. Against
a £10 total budget that is real, and the thing it buys — automatic rotation —
is not something a single-user project needs. If rotation were a requirement,
the answer would flip.

**Parameter Store over GitHub secrets: one credential store, not two.** A
GitHub secret is a long-lived credential in a second system, which is the
thing OIDC was adopted to avoid. Fetching with the role already assumed keeps
everything in one place with one access model.

**Key-pair over password** because Snowflake is removing the choice, and
because a key can be rotated by registering a new public key without a
password change propagating anywhere.

## Consequences

**Separate keys per environment, not one key used twice.** Two key pairs, two
Snowflake users, two SSM parameters. Slightly more setup; means a compromised
dev key grants nothing in prod, and means the "prod is never on disk" rule is
enforceable rather than aspirational.

**The dev local copy can drift from SSM.** Mitigated by writing to SSM first
and treating the local file as a cache. The rotation runbook makes SSM the
first step.

**Every runtime needs SSM read permission**, scoped per environment:
`ssm:GetParameter` and `kms:Decrypt` on `/retail/{env}/*`. The dev CI role
cannot read prod's path and vice versa. This mirrors the S3 bucket scoping
already in place.

**`ReadOnlyAccess` does not grant this.** SSM `GetParameter` on a SecureString
requires decrypt permission explicitly — read-only policies deliberately
exclude it. Needs adding as a separate statement on the CI roles.

**SecureStrings use the AWS-managed KMS key by default.** Free, but it means
anyone with broad KMS and SSM permissions in the account can decrypt. A
customer-managed key with its own policy would be tighter at about £1/month.
Not worth it for this data; worth it on a platform with real credentials, and
worth knowing the difference.

**A fetch-and-delete pattern is not perfect.** The key exists as a temp file
for the duration of the run, and a crashed process may leave it behind.
Mitigated with a trap on exit. The alternative — passing it through an
environment variable — is worse, since environment variables are readable
from `/proc` and leak into logs more easily.

## Alternatives considered

**HashiCorp Vault.** The answer at organisational scale. Rejected: self-hosting
needs an instance, which is £15+/month before it does anything useful.
Managed Vault is more.

**GitHub encrypted secrets.** Simplest to set up. Rejected — see above.

**Password auth with a GitHub secret.** What most tutorials show. Rejected on
both counts: deprecated by Snowflake, and the wrong secret store.

**Environment variables in a shell profile.** Works locally, invisible in CI,
and tends to end up committed by accident when someone adds a `.env` for
convenience.

**One key for both environments.** Half the setup. Rejected — it makes the
prod-never-on-disk rule unenforceable, since the same key would be sitting in
`~/.snowflake/` for dev convenience.

## Follow-ups

- Add `ssm:GetParameter` and `kms:Decrypt` scoped to `/retail/{env}/*` on both
  CI deploy roles, and on whatever identity Airflow runs as.
- Write the rotation procedure into the runbooks: generate, register the new
  public key in Snowflake, write to SSM, refresh the local dev cache, verify,
  then unset the old key.
- Add a `trap` to the CI credential fetch so the temp file is removed even on
  failure.
- Revisit the local dev exception if a second person ever gets access.



## Amendment — 2026-08-24: a third credential, deliberately not in SSM

Setting up the Snowflake storage integration required a third credential:
an RSA key for `soumyadeep007`, the human admin login, because creating a
storage integration needs ACCOUNTADMIN and neither service user holds it.

**This key is not in SSM, and that is the decision.**

The rule in the original ADR is that SSM holds credentials a *runtime*
needs. Nothing automated uses this one. It authenticates a human performing
occasional privileged operations — creating integrations, granting roles,
anything the transformer roles are deliberately not allowed to do.

Putting it in SSM would mean anything with SSM read access could obtain
ACCOUNTADMIN. That inverts the point of the parameter store: it exists so
pipelines can get their own credentials without a human handing them over,
not so that a human's elevated credential becomes machine-reachable.

So the store now holds three credentials with three different treatments:

| Credential | Where | Why |
|---|---|---|
| prod service key | SSM only, never on disk | runtime needs it; highest blast radius |
| dev service key | SSM, cached locally | runtime needs it; low blast radius, local copy is convenience |
| admin key | local only, never in SSM | no runtime needs it; SSM would widen who can reach ACCOUNTADMIN |

**The alternative I considered** was granting ACCOUNTADMIN temporarily to
`retail_dev_user`, which would have avoided a third credential entirely.
Rejected because a service account holding ACCOUNTADMIN even briefly is
exactly what the role separation exists to prevent, and "temporarily" has a
way of persisting.

**Consequence.** Privileged Snowflake operations cannot be automated. That is
intentional — creating a storage integration or granting a role should
involve a human — but it means those steps are not reproducible from CI, only
from committed SQL run by hand. Documented in `snowflake/setup/README.md`.