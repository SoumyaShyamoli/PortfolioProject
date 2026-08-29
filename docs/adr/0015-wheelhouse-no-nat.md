# ADR 0015 — Python packages from an S3 wheelhouse, not PyPI

- **Status:** Accepted
- **Date:** 2026-08-26

## Context

The Airflow bootstrap script installs several Python packages via `pip`.
The Airflow instances sit in the private subnets established in ADR 0003 —
no NAT gateway, no internet gateway. `dnf` (Amazon Linux's own package
manager) worked fine during bootstrap, which was initially reassuring and
briefly misleading: AL2023's repos are backed by AWS-provided endpoints
reachable from inside the VPC. PyPI is a third-party site with no such
endpoint. `pip install` failed with `Network is unreachable` — there is no
route out of these subnets to the public internet at all, by design.

This was found only after a separate, unrelated debugging session: the
bootstrap script's logging idiom (`exec > >(tee file) 2>&1`) was silently
swallowing all output under cloud-init, making the script look like it
completed in seconds when in fact almost nothing had run. Fixing the
logging surfaced this as the real, distinct problem underneath.

## Decision

Python packages are downloaded once, from a machine with internet access,
into a "wheelhouse" — a flat directory of `.whl` files — and uploaded to
each environment's staged S3 bucket under `_wheelhouse/`. The bootstrap
script installs with `pip install --no-index --find-links`, pointed at a
local copy synced from that S3 prefix, and never contacts PyPI.

`scripts/build_wheelhouse.sh` does the download and upload; it is run by
hand, from a laptop, whenever the dependency list changes.

## Rationale

**A NAT gateway was the obvious fix and the wrong one.** ADR 0003 rejected
NAT at ~£30/month against a project-wide budget where that figure is three
times the entire original cap. Adding it now, for the sole purpose of
`pip install` during a one-time bootstrap, would reopen a decision already
made for a good reason and apply it inconsistently — everything else on
this platform goes to real lengths to avoid exactly this cost.

**The S3 route reuses infrastructure that already exists and is free.** The
gateway endpoint from ADR 0003 already gives these subnets a route to S3
with no per-request or hourly charge. Landing the wheelhouse there costs
nothing beyond the storage of a few tens of megabytes of wheel files.

**`--no-index` is deliberate, not incidental.** Without it, `pip` would
still consult PyPI as a fallback and the install would simply fail again
with the same unreachable-network error — the flag is what makes "packages
come from S3, full stop" an enforced property of the script rather than an
intention that could silently regress.

**Pre-built wheels, not building from source on the instance.** `pip
download --only-binary=:all:` refuses anything without a published wheel
for the target platform. The alternative — compiling on the instance —
would need a build toolchain (gcc, headers) this box does not otherwise
need, adding both bootstrap time and permanent installed footprint for a
capability used exactly once.

## Consequences

**A manual step exists outside the automated bootstrap.** Someone with
internet access must run `build_wheelhouse.sh` before an instance can be
(re)provisioned. This is a real point of friction and a real deviation from
"everything is reproducible from `terraform apply`" — flagged rather than
hidden. A CI job could run this instead of a human, since GitHub-hosted
runners have unrestricted internet access; not built yet, listed below.

**The wheelhouse can drift from the bootstrap script's dependency list.**
The package names and versions are declared in two places —
`build_wheelhouse.sh` and `airflow_bootstrap.sh.tpl` — kept manually in
sync rather than generated from one source. A dependency added to one and
not the other fails at bootstrap time with a clear "package not found"
error rather than silently, which is an acceptable failure mode for now but
not a good one long-term.

**This is specific to Python packages.** `dnf`/OS-level packages continue
to work via AWS's own endpoints and needed no change. Any future dependency
delivered as anything other than a pip-installable wheel (a binary tool
downloaded via `curl`, for instance) would need the same treatment applied
separately.

**Found the hard way, in production-shaped conditions.** This was not
caught by planning or by review — it surfaced only once a real instance
tried to bootstrap for real, and only after an unrelated logging bug had
been fixed enough to reveal it. Worth stating plainly: a no-NAT, no-IGW
network design has a real, non-obvious cost in exactly this kind of
friction, and this project has now paid it twice (once conceptually in ADR
0003, once concretely here).

## Alternatives considered

**NAT gateway.** Rejected on cost, consistent with ADR 0003. See Rationale.

**AWS CodeArtifact as a private PyPI proxy.** A more "correct" long-term
answer — it can proxy and cache PyPI transparently, so `pip install` would
work unmodified. Rejected for now on setup cost relative to benefit: a
domain, a repository, and IAM auth configuration for a one-time bootstrap of
two instances is disproportionate. Worth revisiting if package updates
become frequent enough that manual wheelhouse rebuilds become a real
burden.

**Bake packages into a custom AMI instead of installing at boot.** Would
remove the runtime dependency on S3 entirely. Rejected because it trades a
one-time install-time cost for an ongoing AMI-maintenance cost, and this
platform's instances are meant to be simple and rarely rebuilt — an AMI
pipeline is more machinery than the problem warrants here.

## Follow-ups

- A GitHub Actions job that runs `build_wheelhouse.sh` and uploads to S3 on
  a dependency-list change, removing the manual step — the runner has
  internet access the instance never will.
- A single source of truth for the dependency list (a `requirements.txt`
  read by both the build script and rendered into the bootstrap template)
  rather than the two hand-maintained lists that exist now.
- Consider CodeArtifact if package churn increases.




---


---

## Amendment (2026-08-27)

The original decision — pre-download packages, install with `--no-index`
— was correct. Getting it working exposed two further problems, both
worth recording because neither was obvious in advance and both produced
*successful-looking* failures rather than loud ones.

### Problem 1: partial constraints don't pin what you think they pin

The wheelhouse build initially split into three passes — Airflow core
(constrained), providers (unconstrained), dbt/Snowflake/boto3
(unconstrained) — on the theory that "core is already pinned, so pip
won't move it when resolving providers afterward."

That's wrong, and it's wrong in a way that matters: **each `pip download`
invocation resolves independently.** It has no memory of what a previous,
separate invocation decided. Installing providers with no explicit
`apache-airflow==` on that command line meant Airflow was present only as
a *transitive* dependency of `apache-airflow-providers-amazon
(>=2.9.0)`. With nothing anchoring it to an exact version, pip picked the
newest release satisfying that minimum — Airflow **3.3.1**, an
architecturally different major version, installed silently, with no
error at any point.

The first fix — reapplying the constraints file to the providers pass —
was still incomplete. It stopped the jump to 3.x, but landed on Airflow
**2.11.0**, not 2.10.5, because the constraints file pins Airflow's
*dependencies* against a target release; it does not itself force
Airflow's *own* version when nothing on that command line explicitly
requests it. The constraints file limits what a resolver may pick from
among candidates already in play — it doesn't put a specific version in
play on its own.

**The actual fix:** state the exact target version explicitly, on every
command that touches that dependency graph — not once, in one place, and
trust it to hold everywhere downstream.

```bash
python3 -m pip download --dest "$BUILD_DIR" \
  "apache-airflow==2.10.5" \
  apache-airflow-providers-amazon apache-airflow-providers-smtp \
  --constraint "$CONSTRAINT_FILE"
```

`build_wheelhouse.sh` now also refuses to upload if anything other than
exactly `apache_airflow-2.10.5-*.whl` is present in the built wheelhouse,
and `airflow_bootstrap.sh.tpl` runs `airflow version` after install and
fails loudly if it doesn't match. Two silent drifts happened before this
check existed; it exists so a third one can't.

### Problem 2: `--no-index` does not cover `--constraint <URL>`

Separately, once packages were installing correctly offline,
`pip install --constraint <url>` still failed with a network error. The
reason: `--no-index` / `--find-links` control where pip looks for
*packages*. The constraints file itself is a different kind of resource —
pip fetches it over HTTP to read the pins, and that fetch happens
regardless of `--no-index`. The instance has no route to
`raw.githubusercontent.com` any more than it has one to `pypi.org`
(ADR 0003) — this was the same underlying network boundary, hit a second
time via a URL that didn't look like a package source

**Fix:** the constraints file is downloaded once, during the wheelhouse
build (where there is internet), saved as `constraints.txt`, and shipped
in the wheelhouse alongside the packages. Every `--constraint` reference,
in both the build script and the bootstrap script, points at that local
file — never a URL — from that point on.

### Problem 3: a config mechanism that doesn't exist

The original bootstrap script wrote Airflow's executor and database
settings to `/opt/airflow/airflow.cfg.d/executor.cfg`, on the assumption
Airflow reads a directory of config fragments the way nginx or systemd
do. It does not — there is no such mechanism. This surfaced as a
permission error (the directory was created root-owned, then written to
as the `airflow` user) rather than a silent no-op, which is the only
reason it was caught at all; had the permissions happened to line up, the
executor and database settings would simply never have applied and the
gap might not have surfaced until much later.

**Fix:** Airflow's actual override mechanism — `AIRFLOW__SECTION__KEY`
environment variables — set directly in both systemd unit files, the same
way `AIRFLOW_HOME` and `RETAIL_ENVIRONMENT` already were.

### What this changes about how the wheelhouse is built and verified

- Every `pip download`/`pip install` command that touches Airflow states
  the exact version explicitly, even when it looks redundant with an
  earlier command.
- The constraints file is a local artifact shipped in the wheelhouse, not
  a URL fetched at install time.
- `build_wheelhouse.sh` verifies the wheelhouse's contents before
  uploading anything.
- `airflow_bootstrap.sh.tpl` verifies the installed version before
  proceeding to configuration.
- Airflow configuration is set via environment variables on the systemd
  units, not a file-based mechanism that doesn't exist.

None of these were visible from reading the original design. All three
surfaced only once real instances tried to bootstrap for real — which is
itself worth remembering the next time an offline-install design looks
complete on paper.
