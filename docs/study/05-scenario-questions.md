# Study Guide — Part 5: Scenario Questions (Terraform & CI/CD)

Scenario questions test judgment under pressure rather than recall. The
interviewer wants to hear how you reason, what you check first, and whether
you know what *not* to do.

**A pattern that works for most of these:** state what you'd check before
acting, name the risk of the obvious move, then give your answer.

Try answering aloud before reading on

---

## Terraform: state

### S1 — "You run `terraform plan` and it wants to create 40 resources you know already exist. What happened and what do you do?"

**What happened:** Terraform has no state, or is pointing at the wrong state.
Most likely a backend was added and initialised with `terraform init` rather
than `terraform init -migrate-state`, creating an empty remote state.

**Do NOT apply.** With empty state, apply attempts to create everything.
Uniquely-named resources (S3 buckets, IAM roles) fail with 409 and are safe;
resources without name uniqueness (VPCs, subnets, security groups) get
duplicated silently.

**What I'd check, in order:**
1. `terraform state list` — is it empty?
2. `cat .terraform/terraform.tfstate` — which backend is configured?
3. Does a local `terraform.tfstate` still exist with the real resources?
4. Does the state bucket have object versions?

**Recovery:** restore from the local file or a previous S3 version, then
`terraform state push`. If neither exists, rebuild by importing every
resource.

**I've actually had this happen** — it produced ten duplicate network
resources, all free, so no cost impact. The postmortem is in the repo.

---

### S2 — "Two engineers run `terraform apply` at the same time. What happens?"

Without locking: both read state, both compute a plan from the same starting
point, both write. The second write clobbers the first, so state no longer
matches reality — resources exist that state doesn't know about, or vice
versa.

With `use_lockfile = true` on an S3 backend, the second acquires nothing and
errors with a lock message naming who holds it.

**Follow-up you should expect: "the lock is stuck, what now?"** Someone's
apply was killed mid-run. `terraform force-unlock <LOCK_ID>` releases it —
but only after confirming the other run is genuinely dead, because
force-unlocking a live apply causes exactly the corruption the lock prevents.

---

### S3 — "Your state file is corrupted. Walk me through recovery."

**First: stop everyone from applying.**

Then, in order of preference:

1. **S3 object versions** — the reason versioning on the state bucket is
   non-negotiable. Restore the last known-good version.
2. **A local backup.** Terraform writes `terraform.tfstate.backup` before
   each write.
3. **Rebuild by importing.** Slow but always available, since the resources
   still exist in AWS.

**Prevention:** versioning on the state bucket, and never delete backups
until the new state is verified with `terraform state list` and a clean plan.

---

### S4 — "Someone changed a resource in the console. What does Terraform do?"

The next plan shows drift — Terraform compares its cached state against
reality and proposes to revert the change.

**The question behind the question is what you'd do about it.** Three
options:

- **Revert it** if the console change was a mistake.
- **Codify it** — update the `.tf` to match, if the change was correct.
- **Stop managing that attribute** if it's legitimately changed outside
  Terraform.

**What I wouldn't do is blindly apply.** The console change might have been
someone fixing an incident at 3am.

---

## Terraform: import and brownfield

### S5 — "You inherit an account with 200 hand-built resources. How do you bring it under Terraform?"

**Not all at once.** In batches, by resource type, starting with the least
risky.

For each batch: write import blocks → `terraform plan
-generate-config-out` for anything whose config you don't know → review the
generated HCL → plan → verify **zero destroys** → apply → confirm "No
changes" → commit.

**Rejected alternatives:**
- *Destroy and recreate* — impossible with real data, and it hides drift.
- *Terraformer* — generates the whole account at once, but produces sprawling
  unidiomatic HCL that takes longer to clean than to write.

**What import surfaces that recreation hides:** drift. In this project it
revealed inconsistent versioning across buckets and a lifecycle rule that had
never actually saved. Neither would have been noticed otherwise.

---

### S6 — "Your import plan shows 1 to destroy. What do you do?"

**Stop.** A destroy during import means the config doesn't match reality —
usually an immutable field.

`terraform show tfplan | grep -B5 "will be destroyed"` to identify it, then
find which attribute forces replacement. Common culprits: a security group
`description`, an IAM role `name`, a resource name that differs from what's
in AWS.

**Fix the config to match reality first.** Adopt what exists, then change it
deliberately in a separate commit. Never let an import silently replace
something.

---

## Terraform: design

### S7 — "How do you handle dev and prod?"

Several approaches, and the right one depends on scale:

| Approach | Pros | Cons |
|---|---|---|
| Separate AWS accounts | Hard boundary, clean billing | Setup overhead, cross-account IAM |
| Terraform workspaces | Cheap, one config | Shared state file; easy to apply to the wrong one |
| Separate state + tfvars | Clear separation, explicit | Duplication |
| `for_each` over environments | Single source of truth | One state file; a mistake affects both |

**This platform uses `for_each` over an environments map** — six buckets, two
Glue jobs, two Lambdas, all from one config.

**The honest downside:** one state file means a mistake can affect both
environments simultaneously, and there's no way to roll a change out to dev
first and observe it. Acceptable for a solo project where prod isn't serving
anyone; wrong for anything real. The production-grade answer is separate
accounts under an Organization.

**Being able to name the downside is the point of the question.**

---

### S8 — "When would you use `count` instead of `for_each`?"

Rarely. Only when you genuinely need N identical copies with no meaningful
identity — three NAT gateways, one per AZ, say.

**Why `for_each` by default:** `count` uses numeric indices. Remove the
middle element of a list and every subsequent resource shifts index, so
Terraform sees them as changed and may destroy and recreate them.
`for_each` uses stable string keys, so removing one affects only that one.

`count` is also useful as a conditional: `count = var.enabled ? 1 : 0`.

---

### S9 — "Modules — when and why?"

**When there's genuine repetition across configurations** — the same VPC
shape in three accounts, a standard service scaffold used by ten teams.

**This platform deliberately doesn't use them.** With one team and one
configuration, `for_each` over a locals map achieves the same reuse without
the indirection. Premature modularisation makes code harder to read for no
benefit.

**The trap in this question** is claiming modules are always good practice.
The right answer is that they solve a problem you should have first.

---

## CI/CD: OIDC

### S10 — "Why OIDC instead of access keys in GitHub secrets?"

Static keys are the most commonly exfiltrated AWS credential in practice.
They must be rotated, audited, and hoped not to leak — and a leaked key works
until someone notices.

OIDC issues a short-lived token per workflow run. There's no long-lived
artefact to steal.

**The mechanics:** GitHub mints a signed JWT with claims about the run — repo,
branch, event type. AWS validates the signature against the registered OIDC
provider, then checks the claims against the role's trust policy.

**Scoping matters more than the mechanism.** The prod role's trust requires
`ref:refs/heads/main`, so a pull request from a fork cannot obtain production
credentials.

---

### S11 — "Your OIDC role assumption fails with 'Not authorized to perform sts:AssumeRoleWithWebIdentity'. How do you debug it?"

**This one I've actually debugged**, and the answer is: stop guessing, look
at the claim.

Check in order:

1. **`permissions: id-token: write`** in the workflow. Missing this means no
   token is minted, and the error looks like an authorization failure rather
   than a missing token. Most common cause.
2. **The OIDC provider exists** with `sts.amazonaws.com` in its client ID
   list.
3. **The trust policy's `sub` condition** matches the actual claim.

For step 3, decode the token in CI:

```yaml
- uses: actions/github-script@v7
  with:
    script: |
      const token = await core.getIDToken('sts.amazonaws.com');
      const payload = JSON.parse(
        Buffer.from(token.split('.')[1], 'base64').toString()
      );
      core.info('sub: ' + payload.sub);
```

**What that revealed here:** the repository had "include enterprise and
repository IDs in the OIDC subject" enabled, so the claim was
`repo:OWNER@123456/REPO@789012:pull_request` rather than the familiar
`repo:OWNER/REPO:...`. Every guide shows the latter form.

**The fix, and why it's the better one:** pin the trust to the ID-qualified
subject. Owner and repo IDs are immutable, so trust survives a rename, and a
repository that later took over this name couldn't assume the role.

---

### S12 — "What does the `sub` claim look like for different events?"

| Event | `sub` |
|---|---|
| Push to a branch | `repo:OWNER/REPO:ref:refs/heads/main` |
| Pull request | `repo:OWNER/REPO:pull_request` |
| Tag | `repo:OWNER/REPO:ref:refs/tags/v1.0` |
| Environment deploy | `repo:OWNER/REPO:environment:prod` |

**A consequence worth stating:** a role trusting `ref:refs/heads/main` is not
assumable from a pull request, because a PR's claim ends in `:pull_request`.

That's not a bug — it's the desired behaviour. Production deploys happen on
merge, not on proposal.

---

## CI/CD: pipeline design

### S13 — "Should CI be able to run `terraform apply`?"

**There's a real tension here and I'd say so.** A CI role that can apply
across a whole platform needs permission to manage every resource type in it
— close to administrative. That sits badly with least privilege.

Two defensible answers:

**Narrow CI** — CI runs `terraform plan` read-only on PRs and deploys
application artifacts on merge; infrastructure `apply` is run by a human.
Common in regulated environments. This is what this platform does.

**Broad CI** — the deploy role can apply. Standard in most teams, justified
by branch-scoped trust and code review.

**What I'd avoid is giving CI admin without noticing the tension.** Either
choice is fine if it's a decision.

---

### S14 — "Walk me through your promotion path."

```
feature branch → PR
  ↓ dev role via OIDC: lint, terraform plan, posted as PR comment
  ↓ plan containing destroy or replace FAILS the check
merge to main
  ↓ dev role: upload script to dev, run the Glue job as a smoke test
  ↓ prod role (main-only trust): upload the SAME file to prod
  ↓ environment protection rule pauses for approval
```

**The property that makes it meaningful:** the artifact promoted to prod is
the identical file that was tested in dev — uploaded, not rebuilt.

**The smoke test is what makes the dev stage more than a file copy.** It
actually runs the Glue job and waits for success. That only works because the
job is idempotent, so re-running the same month is safe.

**Prod deliberately doesn't run the job.** An automatic prod run on every
merge would process data on a schedule nobody chose.

---

### S15 — "Your PR plan shows a destroy. Should the pipeline block it?"

Yes, and this pipeline does:

```yaml
- name: Block destructive changes
  run: |
    if grep -qE "will be destroyed|must be replaced" plan.txt; then
      echo "::error::Plan contains destroy or replace operations."
      exit 1
    fi
```

A destroy in a PR plan is almost always unintended — a renamed resource, a
changed immutable field. Better caught at review than discovered at apply.

**The obvious follow-up: "what if the destroy is intentional?"** Then it
needs an explicit override — a label on the PR, or a `workflow_dispatch` with
a confirmation input. The point isn't to make destroys impossible; it's to
make them deliberate.

---

### S16 — "How do you handle secrets in CI?"

**In this platform, there are none to handle.** OIDC replaced the AWS
credentials, which were the only long-lived secret.

Where secrets are genuinely needed — a Snowflake password, say — the options
in order of preference:

1. **AWS Secrets Manager**, fetched at runtime by the assumed role. The
   secret never enters GitHub.
2. **GitHub encrypted secrets** for things that must exist before AWS
   credentials do.
3. **Never** in `.tfvars`, `.env`, or anything committed. `*.tfvars` is
   gitignored for exactly this reason, with a `terraform.tfvars.example`
   showing the expected shape.

**Also worth mentioning:** Terraform state can contain secrets in plaintext,
so the state bucket is encrypted and access-scoped to the specific state key.

---

### S17 — "A deployment fails halfway. What's your rollback?"

**Depends what failed, and I'd want to know before acting.**

- **Terraform apply partially failed** — state reflects what succeeded.
  Re-running apply is usually correct and safe, since Terraform is
  declarative. Investigate why first; the failure may be a symptom.
- **A bad Glue script deployed** — revert the commit and re-run the deploy.
  The script is a single S3 object, so rollback is a redeploy of the previous
  version.
- **Bad data written** — this is the interesting case. Because the job is
  idempotent and raw is immutable, the fix is to correct the code and
  reprocess the affected months. The output partition is replaced, not
  appended to.

**The general principle: design so rollback is redeployment rather than
undo.** That's why raw is immutable and the job is idempotent.

---

### S18 — "How do you know a deployment actually worked?"

Three levels, and I'd want all three:

1. **The deploy succeeded** — the workflow is green.
2. **The smoke test passed** — the Glue job ran against a known month and
   succeeded.
3. **The data reconciles** — the job's own three-point recon (source lines,
   parsed vs corrupt, read back from S3) balanced, and the audit record says
   `balanced: true`.

**The third is the one that matters.** A green pipeline tells you the code
deployed. Only the reconciliation tells you the data is right — and a silent
shortfall passes every check that isn't specifically looking for it.

---

## Judgment

### S19 — "What's the biggest risk in your Terraform setup?"

**State.** It's the most fragile part and the least protected. Infrastructure
survives most mistakes; the record of it doesn't.

Mitigations here: versioning on the state bucket, native S3 locking,
verification steps in a runbook, and a postmortem documenting exactly how it
went wrong once.

**Second biggest:** one state file covering both environments, so a mistake
can affect both simultaneously. Documented, with separate accounts named as
the correct answer at scale.

---

### S20 — "How would you improve this pipeline with more time?"

- **Policy-as-code** — `tflint`, `tfsec` or Checkov in the PR checks, so
  security regressions fail review rather than relying on someone noticing.
- **Cost estimation** — Infracost on the PR, showing the monthly delta of a
  change before it merges.
- **Separate accounts per environment**, removing the shared-state risk.
- **Drift detection** — a scheduled plan that alerts when reality diverges
  from configuration.
- **An approval gate on prod** beyond a branch check — currently merging to
  `main` grants deploy capability with no second pair of eyes.

**Naming what's missing is usually a better answer than describing what's
there.**
